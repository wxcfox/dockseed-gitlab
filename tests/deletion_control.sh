#!/usr/bin/env bash
# Offline deletion-control tests: standard-library unittest against a local stub GitLab.
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd -P)
command -v python3 >/dev/null 2>&1 || { printf 'FAIL: python3 (3.9+) is required\n' >&2; exit 1; }

python3 -I - "$repo/ops/deletion-control/deletion_control.py" "$repo/ops/deletion-control/gitlab.rb.example" <<'PY'
import contextlib
import copy
import hashlib
import http.client
import importlib.util
import io
import json
import os
import re
import socket
import sys
import tempfile
import threading
import unittest
import urllib.parse
from email.message import Message
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("deletion_control", sys.argv[1])
dc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dc)


def headers(**values):
    message = Message()
    for name, value in values.items():
        message[name.replace("_", "-")] = value
    return message


def multipart(boundary, *parts):
    body = b""
    for head, value in parts:
        body += b"--" + boundary + b"\r\n" + head + b"\r\n\r\n" + value + b"\r\n"
    return body + b"--" + boundary + b"--\r\n"


class Candidates(unittest.TestCase):
    def check(self, path, expected):
        self.assertEqual(dc.deletion_candidates(path), expected, path)

    def test_project_and_group_destroy_routes(self):
        self.check("/example-group/team/app", [("any", "example-group/team/app")])
        self.check("/example-group/app?permanently_delete=true", [("any", "example-group/app")])
        self.check("/groups/example-group/team", [("group", "example-group/team")])
        self.check("/example-group", [("group", "example-group")])
        self.check("/alice/project", [("any", "alice/project")])

    def test_admin_area_routes(self):
        self.check("/admin/projects/example-group/team/app", [("project", "example-group/team/app")])
        self.check("/admin/groups/example-group", [("group", "example-group")])
        self.check("/admin/projects/app", [])

    def test_api_routes_take_one_raw_segment(self):
        self.check("/api/v4/projects/123", [("project", "123")])
        self.check("/api/v4/projects/example-group%2Fapp", [("project", "example-group/app")])
        self.check("/api/v4/groups/example-group%2Fteam/", [("group", "example-group/team")])
        self.check("/api/v4/projects/123.json", [("project", "123.json"), ("project", "123")])
        self.check("/api/v4/projects/123.x~", [("project", "123.x~"), ("project", "123")])
        self.check("/API/V4/Projects/7", [("project", "7")])
        self.check("/api/v4/projects/1/x/../../2", [("project", "2")])
        for path in ("/api/v4/projects/123/members/5", "/api/v4/projects", "/api/v4/projects/a/b", "/api/graphql"):
            self.check(path, [])

    def test_format_suffix_and_dotted_paths(self):
        self.check("/example-group/app.json", [("any", "example-group/app.json"), ("any", "example-group/app")])
        self.check("/example-group/app.atom!", [("any", "example-group/app.atom!"), ("any", "example-group/app")])
        self.check("/example-group/a.b.c", [("any", "example-group/a.b.c"), ("any", "example-group/a"), ("any", "example-group/a.b")])
        self.check("/example-group/my.project", [("any", "example-group/my.project"), ("any", "example-group/my")])

    def test_paths_are_normalized_like_gitlab(self):
        self.check("//example-group//team/app", [("any", "example-group/team/app")])
        self.check("/%65xample-group/app", [("any", "example-group/app")])
        self.check("/example-group%2Fapp", [("any", "example-group/app")])
        self.check("/alice/../example-group/app", [("any", "example-group/app")])
        self.check("/example-group/app/-/..", [("any", "example-group/app")])
        self.check("http://gitlab.example.com/example-group/app", [("any", "example-group/app")])
        self.check("/o/default/example-group/app", [("any", "o/default/example-group/app"), ("any", "example-group/app")])

    def test_import_endpoints(self):
        for path in ("/api/v4/projects/import", "/api/v4/projects/remote-import?x=1", "/api/v4/projects/Remote-Import-S3"):
            self.assertTrue(dc.import_endpoint(path), path)
        for path in ("/api/v4/projects/importer", "/api/v4/groups/import", "/import/gitlab_project"):
            self.assertFalse(dc.import_endpoint(path), path)

    def test_dash_scoped_paths_are_not_candidates(self):
        for path in ("/example-group/app/-/issues/3", "/groups/example-group/-/group_members/3", "/-/profile", "/"):
            self.check(path, [])


class DeleteDetection(unittest.TestCase):
    def deletes(self, method, body=b"", **header_values):
        return dc.requests_delete(method, headers(**header_values), body)

    def test_delete_method_and_override_header(self):
        self.assertTrue(self.deletes("DELETE"))
        self.assertTrue(self.deletes("POST", X_HTTP_Method_Override="delete"))
        self.assertTrue(self.deletes("POST", X_HTTP_Method_Override=" DELETE "))

    def test_urlencoded_method_override(self):
        form = "application/x-www-form-urlencoded"
        for body in (b"_method=delete&authenticity_token=x", b"authenticity_token=x&_method=DELETE",
                     b"%5Fmethod=delete", b"a=1;_method=delete", b"a=1& _method=delete", b"_method=delete+"):
            self.assertTrue(self.deletes("POST", body, Content_Type=form), body)
        self.assertTrue(self.deletes("POST", b"_method=delete", Content_Type=form + "; charset=UTF-8"))

    def test_missing_content_type_is_parsed_as_form(self):
        self.assertTrue(self.deletes("POST", b"_method=delete"))

    def test_multipart_method_override(self):
        boundary = b"----boundary7"
        variants = [
            multipart(boundary, (b'Content-Disposition: form-data; name="_method"', b"delete")),
            multipart(boundary, (b'Content-Disposition: form-data; name="project[name]"', b"x"),
                      (b'Content-Disposition: form-data; name="_method"\r\nContent-Type: text/plain', b"delete")),
            multipart(boundary, (b"content-disposition: form-data; name=_method", b"DELETE")),
        ]
        for body in variants:
            self.assertTrue(self.deletes("POST", body, Content_Type='multipart/form-data; boundary="----boundary7"'), body)
            self.assertTrue(self.deletes("POST", body, Content_Type="multipart/form-data; boundary=----boundary7"), body)
        # Without a boundary Rack falls back to parsing the body as urlencoded.
        self.assertTrue(self.deletes("POST", b"_method=delete", Content_Type="multipart/form-data"))

    def test_rack_parsing_quirks(self):
        # Rack ends the media type at ";" or ",".
        self.assertTrue(self.deletes("POST", b"_method=delete", Content_Type="application/x-www-form-urlencoded,x"))
        # Rack's greedy boundary match picks the last boundary=.
        body = multipart(b"b", (b'Content-Disposition: form-data; name="_method"', b"delete"))
        self.assertTrue(self.deletes("POST", body, Content_Type="multipart/form-data; boundary=aboundary=b"))
        # Rack also names a part after its Content-ID.
        body = multipart(b"b0", (b"Content-ID: _method", b"delete"))
        self.assertTrue(self.deletes("POST", body, Content_Type="multipart/form-data; boundary=b0"))
        # The media type does not matter for small bodies: reading more only refuses more.
        self.assertTrue(self.deletes("POST", b"_method=delete", Content_Type="text/plain"))

    def test_import_overwrite_detection(self):
        form = headers(Content_Type="application/x-www-form-urlencoded")
        self.assertTrue(dc.import_overwrites("/api/v4/projects/import?overwrite=true", headers(), b""))
        self.assertTrue(dc.import_overwrites("/api/v4/projects/import", form, b"path=x&overwrite=1"))
        self.assertTrue(dc.import_overwrites("/api/v4/projects/remote-import", headers(Content_Type="application/json"),
                                             b'{"url": "https://x", "path": "x", "Overwrite": true}'))
        body = multipart(b"b0", (b'Content-Disposition: form-data; name="overwrite"', b"yes"))
        self.assertTrue(dc.import_overwrites("/api/v4/projects/import", headers(Content_Type="multipart/form-data; boundary=b0"), body))
        for target, body in (("/api/v4/projects/import?overwrite=false", b""), ("/api/v4/projects/import", b"overwrite=0"),
                             ("/api/v4/projects/import", b'{"overwrite": false}'), ("/api/v4/projects/import", b"path=x")):
            self.assertFalse(dc.import_overwrites(target, form, body), (target, body))

    def test_normal_posts_are_not_deletions(self):
        boundary = b"b0"
        settings = multipart(boundary, (b'Content-Disposition: form-data; name="_method"', b"patch"),
                             (b'Content-Disposition: form-data; name="project[description]"', b"delete old files"),
                             (b'Content-Disposition: form-data; name="project[avatar]"; filename="avatar.png"', b"delete"))
        self.assertFalse(self.deletes("POST", settings, Content_Type="multipart/form-data; boundary=b0"))
        # Deliberate over-match: any part header mentioning _method counts, even a file name.
        odd = multipart(boundary, (b'Content-Disposition: form-data; name="file"; filename="_method"', b"delete"))
        self.assertTrue(self.deletes("POST", odd, Content_Type="multipart/form-data; boundary=b0"))
        self.assertFalse(self.deletes("POST", b"_method=patch&description=delete", Content_Type="application/x-www-form-urlencoded"))
        self.assertFalse(self.deletes("POST", b'{"_method":"delete"}', Content_Type="application/json"))
        self.assertFalse(self.deletes("PUT", b"_method=delete", Content_Type="application/x-www-form-urlencoded"))


class LargeUploadScan(unittest.TestCase):
    def feed(self, body, boundary=b"b0", size=7):
        watch = dc.MultipartWatch({boundary})
        return any(watch.suspicious(body[i:i + size]) for i in range(0, len(body), size))

    def test_file_contents_never_trigger(self):
        text = b"def helper_method_name; end\n" + b'<input name="_method" value="delete">\n' + b"--b0x"
        body = multipart(b"b0", (b'Content-Disposition: form-data; name="file"; filename="notes.txt"', text * 50))
        self.assertFalse(self.feed(body))

    def test_method_part_is_found_across_chunk_edges(self):
        body = multipart(b"b0", (b'Content-Disposition: form-data; name="file"; filename="a"', b"x" * 100),
                         (b'Content-Disposition: form-data; name="_method"', b"delete"))
        for size in (1, 3, 7, 64, len(body)):
            self.assertTrue(self.feed(body, size=size), size)

    def test_endless_part_header_is_refused(self):
        self.assertTrue(self.feed(b"--b0\r\nX-Pad: " + b"a" * (dc.MAX_PART_HEADER + 10), size=4096))

    def test_watched_fields_follow_the_endpoint(self):
        body = multipart(b"b0", (b'Content-Disposition: form-data; name="overwrite"', b"true"))
        self.assertFalse(self.feed(body))
        watch = dc.MultipartWatch({b"b0"}, ("_method", "overwrite"))
        self.assertTrue(any(watch.suspicious(body[i:i + 5]) for i in range(0, len(body), 5)))


class NginxRouting(unittest.TestCase):
    """Emulates the map in gitlab.rb.example: decoded, normalized $uri decides
    whether a request goes to deletion-control."""

    @classmethod
    def setUpClass(cls):
        text = open(sys.argv[2], encoding="utf-8").read()
        block = re.search(r'map "\$deletion_control_override:\$request_method:\$uri" \$deletion_control_route \{(.*?)\n  \}', text, re.S).group(1)
        cls.rules = [(re.compile(regex), value) for regex, value in re.findall(r'^\s*"~([^"]+)" ([01]);', block, re.M)]
        assert len(cls.rules) == 7, cls.rules
        assert "rewrite ^ /.deletion-control-route last;" in text and "listen 8932;" in text
        assert 'if ($http_x_deletion_control_key != "REPLACE_WITH_UPSTREAM_KEY")' in text
        assert 'proxy_set_header X-Deletion-Control-Key "";' in text and "8933" not in text

    @staticmethod
    def normalized(raw):
        segments = []
        for segment in urllib.parse.unquote(raw.split("?", 1)[0]).split("/"):
            if segment == "..":
                segments = segments[:-1]
            elif segment not in ("", "."):
                segments.append(segment)
        uri = "/" + "/".join(segments)
        return uri + "/" if raw.split("?", 1)[0].endswith("/") and uri != "/" else uri

    def routed(self, method, raw, override=""):
        key = f"{1 if override else 0}:{method}:{self.normalized(raw)}"
        return next((value == "1" for pattern, value in self.rules if pattern.search(key)), False)

    def test_every_deletion_shape_reaches_deletion_control(self):
        for method, raw in (("POST", "/example-group/app"), ("DELETE", "/example-group/app"),
                            ("POST", "/groups/example-group/team"), ("POST", "/example-group"),
                            ("POST", "/admin/projects/example-group/app"), ("POST", "/admin/groups/example-group"),
                            ("DELETE", "/api/v4/projects/123"), ("DELETE", "/api/v4/projects/example-group%2Fapp"),
                            ("DELETE", "/api%2Fv4/projects/a%2Fb"), ("DELETE", "/api/v4/%70rojects/123"),
                            ("DELETE", "//api/v4//groups//7/"), ("POST", "/api/v4/groups/7"),
                            ("DELETE", "/-/../api/v4/projects/123"), ("DELETE", "/users/../example-group/app"),
                            ("DELETE", "/example-group/app.git"), ("DELETE", "/example-group/app.git/"),
                            ("DELETE", "/example-group/app/-/"), ("POST", "/o/default/example-group/app"),
                            ("DELETE", "/API/v4/projects/1"), ("POST", "/.deletion-control")):
            self.assertTrue(self.routed(method, raw), (method, raw))
        self.assertTrue(self.routed("PUT", "/example-group/app", override="DELETE"))
        self.assertTrue(self.routed("GET", "/anything", override="delete"))

    def test_busy_paths_go_straight_to_gitlab(self):
        for method, raw in (("POST", "/example-group/app.git/git-receive-pack"), ("POST", "/example-group/app/-/issues"),
                            ("POST", "/users/sign_in"), ("POST", "/api/graphql"), ("POST", "/api/v4/jobs/request"),
                            ("POST", "/uploads/user"), ("POST", "/admin/application_settings"), ("POST", "/-/autocomplete"),
                            ("GET", "/example-group/app"), ("PUT", "/api/v4/projects/1"), ("POST", "/oauth/token")):
            self.assertFalse(self.routed(method, raw), (method, raw))


class Configuration(unittest.TestCase):
    def test_defaults(self):
        config = dc.load_config({})
        self.assertEqual((config.required_admins, config.token_file, config.key_file, config.upstream),
                         (0, "/run/secrets/deletion-control/token", "/run/secrets/deletion-control/upstream-key", ("gitlab", 8932)))

    def test_requests_project_is_required_when_enabled(self):
        self.assertEqual(dc.load_config({"DELETION_REQUIRED_ADMINS": "2", "DELETION_REQUESTS_PROJECT": "a/b"}).required_admins, 2)
        for env in ({"DELETION_REQUIRED_ADMINS": "1"}, {"DELETION_REQUIRED_ADMINS": "1", "DELETION_REQUESTS_PROJECT": "19"},
                    {"DELETION_REQUIRED_ADMINS": "-1"}, {"DELETION_REQUIRED_ADMINS": "x"},
                    {"DELETION_GITLAB_URL": "https://gitlab"}, {"DELETION_GITLAB_URL": "http://gitlab/api"}):
            with self.assertRaises(dc.ConfigError, msg=env):
                dc.load_config(env)


KEY = "k" * 40
BASE_STATE = {
    "users": {
        1: {"id": 1, "username": "root", "is_admin": True, "state": "active", "bot": False},
        2: {"id": 2, "username": "alice", "is_admin": True, "state": "active", "bot": False},
        3: {"id": 3, "username": "bob", "is_admin": True, "state": "active", "bot": False},
        4: {"id": 4, "username": "carol", "is_admin": False, "state": "active", "bot": False},
        5: {"id": 5, "username": "dave", "is_admin": True, "state": "blocked", "bot": False},
        90: {"id": 90, "username": "deletion-bot", "is_admin": True, "state": "active", "bot": False},
        92: {"id": 92, "username": "admin-without-mode", "is_admin": True, "state": "active", "bot": False},
    },
    # credential -> (user id, personal access token scopes or None for OAuth/session)
    "credentials": {"PRIVATE-TOKEN=svc-token": (90, ["api"]), "PRIVATE-TOKEN=alice-pat": (2, ["api"]),
                    "PRIVATE-TOKEN=admin-mode-token": (92, ["api"]),
                    "PRIVATE-TOKEN=carol-pat": (4, ["api"]), "PRIVATE-TOKEN=carol-read": (4, ["read_api"]),
                    "private_token=bob-pat": (3, ["api"]), "Authorization=Bearer bob-oauth": (3, None),
                    "Authorization=Bearer carol-oauth-read": (4, None),
                    "Cookie=_gitlab_session=carol": (4, None), "Cookie=_gitlab_session=alice": (2, None)},
    "oauth_scopes": {"bob-oauth": ["api"], "carol-oauth-read": ["read_user"]},
    "projects": {
        10: {"id": 10, "path_with_namespace": "example-group/app", "namespace": {"kind": "group"}},
        11: {"id": 11, "path_with_namespace": "example-group/team/lib", "namespace": {"kind": "group"}},
        12: {"id": 12, "path_with_namespace": "carol/sandbox", "namespace": {"kind": "user"}, "owner": {"id": 4}},
        13: {"id": 13, "path_with_namespace": "example-group/old", "namespace": {"kind": "group"}, "marked_for_deletion_on": "2026-12-01"},
        30: {"id": 30, "path_with_namespace": "example-group/deletion-requests", "namespace": {"kind": "group"}, "default_branch": "main"},
    },
    "groups": {20: {"id": 20, "full_path": "example-group"}, 21: {"id": 21, "full_path": "example-group/team"}},
    "members": {("project", 10, 4): 50, ("project", 11, 4): 30, ("group", 21, 4): 50},
    "branches": {"main"},
    "commits": [],
    "mrs": {},
    "approvals": {},
    "notes": [],
    "deleted": [],
    "forwarded": [],
    "delete_status": 202,
    "reject_assignee": False,
    "fail_notes": False,
    "fail_close": False,
    "close_on_count": False,
    "statistics_denied": False,
    "demote_after_check": False,
    "service_demoted": False,
    "fail_branch_delete": False,
    "drop_delete_response": False,
    "delete_calls": 0,
}


class StubGitLab(BaseHTTPRequestHandler):
    """GitLab behind the internal port: every request needs the upstream key."""
    protocol_version = "HTTP/1.1"
    state = None

    def log_message(self, *args):
        pass

    def reply(self, status, payload=None, extra=(), raw=None):
        body = raw if raw is not None else (b"" if payload is None else json.dumps(payload).encode())
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in extra:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def caller(self, query):
        """(user id, PAT scopes) for the request's credential; session writes need the CSRF token."""
        for name in ("PRIVATE-TOKEN", "Authorization", "Cookie"):
            if self.headers.get(name):
                return self.state["credentials"].get(f"{name}={self.headers[name]}")
        if query.get("private_token"):
            return self.state["credentials"].get(f"private_token={query['private_token'][0]}")
        return None

    def _handle(self):
        state = self.state
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        if len(body) != length:
            return  # Cut off mid-body: GitLab never sees a complete request.
        if self.headers.get_all("X-Deletion-Control-Key") != [KEY]:
            return self.reply(403, raw=b"deletion-control upstream key mismatch\n")
        split = urllib.parse.urlsplit(self.path)
        query = urllib.parse.parse_qs(split.query)
        if split.path == "/oauth/token/info":
            token = (self.headers.get("Authorization") or "")[len("Bearer "):]
            scopes = state["oauth_scopes"].get(token)
            return self.reply(200, {"scope": scopes}) if scopes else self.reply(401, {"error": "invalid_token"})
        if not split.path.startswith("/api/v4/"):
            state["forwarded"].append((self.command, self.path, self.headers.items(), body))
            if self.path == "/redirect":
                return self.reply(302, extra=[("Location", "/elsewhere")])
            payload = b"upstream:" + hashlib.sha256(body).hexdigest().encode()
            self.send_response(201, "Created")
            self.send_header("Set-Cookie", "a=1")
            self.send_header("Set-Cookie", "b=2")
            self.send_header("Keep-Alive", "timeout=5")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            return self.wfile.write(payload)
        parts = [urllib.parse.unquote(part) for part in split.path[len("/api/v4/"):].split("/")]
        if parts[:2] in (["projects", "import"], ["projects", "remote-import"]):
            state["forwarded"].append((self.command, self.path, self.headers.items(), body))
            return self.reply(201, {"id": 77})
        data = json.loads(body) if body.strip()[:1] == b"{" else {}
        found_caller = self.caller(query)
        if found_caller is None:
            return self.reply(401, {"message": "401 Unauthorized"})
        caller, scopes = found_caller
        method = self.command
        if parts == ["user"]:
            return self.reply(200, state["users"][caller])
        if parts == ["personal_access_tokens", "self"]:
            return self.reply(200, {"scopes": scopes, "active": True, "revoked": False}) if scopes else self.reply(403, {"message": "403 Forbidden"})
        if parts == ["application", "statistics"]:
            # Admin-only; an admin token without the admin_mode scope under Admin Mode gets 403.
            allowed = caller == 90 and not self.state["statistics_denied"] and not self.state["service_demoted"]
            if allowed and self.state["demote_after_check"]:
                self.state["service_demoted"] = True  # loses administrator access right after this check
            return self.reply(200, {"projects": "5"}) if allowed else self.reply(403, {"message": "403 Forbidden"})
        if parts == ["user", "preferences"] and method == "PUT":
            username = state["users"][caller]["username"]
            if self.headers.get("Cookie") and self.headers.get("X-CSRF-Token") != f"csrf-{username}":
                return self.reply(401, {"message": "401 Unauthorized"})
            return self.reply(400, {"error": "view_diffs_file_by_file, ... are missing, at least one parameter must be provided"})
        if caller != 90:
            if method == "GET" and parts[0] in ("projects", "groups") and len(parts) == 2:
                return self.reply(404, {"message": "404 Project Not Found"})  # GitLab hides what a caller cannot see.
            return self.reply(403, {"message": "only the service account may call this stub"})
        if parts == ["users"]:
            return self.reply(200, [u for u in state["users"].values() if u["is_admin"] and u["state"] == "active"])
        if parts[0] == "users" and len(parts) == 2:
            user = state["users"].get(int(parts[1]))
            return self.reply(200, user) if user else self.reply(404, {"message": "404 User Not Found"})
        kind = {"projects": "project", "groups": "group"}.get(parts[0])
        table = state.get(parts[0])
        if kind and len(parts) == 2:
            if state["service_demoted"] and method == "GET":
                return self.reply(404, {"message": "404 Project Not Found"})  # hidden from a non-admin
            ref = parts[1]
            key = "path_with_namespace" if kind == "project" else "full_path"
            found = next((item for item in table.values() if str(item["id"]) == ref or item[key].lower() == ref.lower()), None)
            if not found:
                return self.reply(404, {"message": "404 Not Found"})
            if method == "GET":
                return self.reply(200, found)
            if method == "DELETE":
                state["delete_calls"] += 1
                if state["drop_delete_response"]:
                    found["marked_for_deletion_on"] = "2026-12-27"  # accepted, but the answer is lost
                    self.close_connection = True
                    return
                if state["delete_status"] == 202:
                    found["marked_for_deletion_on"] = "2026-12-27"
                    state["deleted"].append((kind, found["id"]))
                return self.reply(state["delete_status"], {"message": "202 Accepted" if state["delete_status"] == 202 else "boom"})
        if kind and parts[2:4] == ["members", "all"]:
            level = state["members"].get((kind, int(parts[1]), int(parts[4])))
            return self.reply(200, {"access_level": level}) if level else self.reply(404, {"message": "404 Not found"})
        if parts[:2] == ["projects", "30"]:
            rest = parts[2:]
            if rest == ["repository", "commits"] and method == "POST":
                if data["branch"] in state["branches"] or data.get("start_branch") != "main":
                    return self.reply(400, {"message": "A branch called this already exists"})
                state["branches"].add(data["branch"])
                state["commits"].append(data)
                return self.reply(201, {"id": "c0ffee", "short_id": "c0ffee"})
            if rest[:2] == ["repository", "branches"] and method == "DELETE":
                if state["fail_branch_delete"]:
                    return self.reply(500, {"message": "500 Internal Server Error"})
                name = "/".join(rest[2:])
                if name not in state["branches"]:
                    return self.reply(404, {"message": "404 Branch Not Found"})
                state["branches"].discard(name)
                return self.reply(204)
            if rest == ["merge_requests"] and method == "POST":
                if state["reject_assignee"] and data.get("assignee_ids"):
                    return self.reply(422, {"message": "assignee cannot be assigned"})
                iid = len(state["mrs"]) + 1
                mr = {"iid": iid, "source_branch": data["source_branch"], "title": data["title"],
                      "description": data["description"], "state": "opened", "author": {"id": 90},
                      "assignee_ids": data.get("assignee_ids", []),
                      "web_url": f"http://gitlab.example.com/example-group/deletion-requests/-/merge_requests/{iid}"}
                state["mrs"][iid] = mr
                return self.reply(201, mr)
            if rest == ["merge_requests"] and method == "GET":
                return self.reply(200, [mr for mr in state["mrs"].values() if mr["state"] == query["state"][0]])
            if rest[0] == "merge_requests" and len(rest) >= 2:
                mr = state["mrs"].get(int(rest[1]))
                if not mr:
                    return self.reply(404, {"message": "404 Not found"})
                if len(rest) == 2 and method == "GET":
                    return self.reply(200, mr)
                if len(rest) == 2 and method == "PUT":
                    if state["fail_close"]:
                        return self.reply(500, {"message": "500 Internal Server Error"})
                    mr["state"] = "closed" if data.get("state_event") == "close" else mr["state"]
                    return self.reply(200, mr)
                if rest[2:] == ["approvals"]:
                    if state["close_on_count"]:
                        mr["state"] = "closed"  # An admin closes the request while it is being counted.
                    ids = state["approvals"].get(mr["iid"], [])
                    return self.reply(200, {"approved_by": [{"user": {"id": user_id}} for user_id in ids]})
                if rest[2:] == ["notes"] and method == "POST":
                    if state["fail_notes"]:
                        return self.reply(500, {"message": "500 Internal Server Error"})
                    state["notes"].append((mr["iid"], data["body"]))
                    return self.reply(201, {"id": len(state["notes"])})
        return self.reply(404, {"message": f"stub has no route for {method} {split.path}"})

    do_GET = do_POST = do_DELETE = do_PUT = _handle


class Service(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.gitlab = ThreadingHTTPServer(("127.0.0.1", 0), StubGitLab)
        threading.Thread(target=cls.gitlab.serve_forever, daemon=True).start()
        cls.secrets = tempfile.TemporaryDirectory()
        cls.token_file = os.path.join(cls.secrets.name, "token")
        cls.key_file = os.path.join(cls.secrets.name, "upstream-key")
        cls.servers, cls.hooks = {}, {}
        for required in (0, 1, 2):
            config = dc.load_config({
                "DELETION_REQUIRED_ADMINS": str(required),
                "DELETION_REQUESTS_PROJECT": "example-group/deletion-requests",
                "DELETION_TOKEN_FILE": cls.token_file,
                "DELETION_UPSTREAM_KEY_FILE": cls.key_file,
                "DELETION_GITLAB_URL": f"http://127.0.0.1:{cls.gitlab.server_address[1]}",
            })
            control = dc.Control(config, dc.GitLab(config.upstream, config.token_file, config.key_file))
            server, hooks = dc.make_servers(control, "127.0.0.1", 0, 0)
            for each in (server, hooks):
                threading.Thread(target=each.serve_forever, daemon=True).start()
            cls.servers[required], cls.hooks[required] = server, hooks

    @classmethod
    def tearDownClass(cls):
        for server in list(cls.servers.values()) + list(cls.hooks.values()) + [cls.gitlab]:
            server.shutdown()
            server.server_close()
        cls.secrets.cleanup()

    def write_secret(self, path, value):
        with open(path, "w") as handle:
            handle.write(value)

    def setUp(self):
        StubGitLab.state = self.state = copy.deepcopy(BASE_STATE)
        self.write_secret(self.token_file, "svc-token\n")
        self.write_secret(self.key_file, KEY + "\n")
        for server in self.servers.values():
            server.control._project, server.control._service = None, (None, None)
        self.log = io.StringIO()
        self.redirect = contextlib.redirect_stderr(self.log)
        self.redirect.__enter__()

    def tearDown(self):
        self.redirect.__exit__(None, None, None)

    def send(self, method, path, body=b"", required=2, header_list=(), port=None):
        port = port or self.servers[required].server_address[1]
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        connection.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
        connection.putheader("Host", "gitlab.example.com")
        connection.putheader("X-Real-IP", "203.0.113.7")
        for name, value in header_list:
            connection.putheader(name, value)
        connection.putheader("Content-Length", str(len(body)))
        connection.endheaders()
        try:
            connection.send(body)
        except OSError:
            pass  # The service may answer and close before reading a refused body.
        response = connection.getresponse()
        result = (response.status, response.getheaders(), response.read())
        connection.close()
        return result

    def web_delete(self, path, who="carol", required=2, csrf=None, extra=b""):
        token = f"csrf-{who}" if csrf is None else csrf
        return self.send("POST", path, b"_method=delete&authenticity_token=" + token.encode() + extra, required, [
            ("Content-Type", "application/x-www-form-urlencoded"), ("Cookie", f"_gitlab_session={who}"),
            ("Accept", "text/html,application/xhtml+xml")])

    def hook(self, iid, action="approved", project_id=30, required=2):
        payload = {"object_kind": "merge_request", "project": {"id": project_id},
                   "object_attributes": {"iid": iid, "action": action}}
        status = self.send("POST", "/hook", json.dumps(payload).encode(), header_list=[("Content-Type", "application/json")],
                           port=self.hooks[required].server_address[1])[0]
        self.assertEqual(status, 202)
        self.hooks[required].queue.join()

    def location(self, response_headers):
        return dict((name.lower(), value) for name, value in response_headers).get("location")

    def test_owner_delete_becomes_a_merge_request(self):
        status, response_headers, _ = self.web_delete("/example-group/app")
        self.assertEqual(status, 303)
        self.assertEqual(self.location(response_headers), "http://gitlab.example.com/example-group/deletion-requests/-/merge_requests/1")
        mr = self.state["mrs"][1]
        self.assertRegex(mr["source_branch"], r"^delete/project-10/u-4-[0-9]+$")
        self.assertIn(mr["source_branch"], self.state["branches"])
        self.assertEqual(mr["title"], "删除工程：example-group/app")
        self.assertIn("@carol 申请删除工程 `example-group/app`（ID 10）", mr["description"])
        self.assertIn("请审批：@root @alice @bob", mr["description"])
        self.assertNotIn("deletion-bot", mr["description"])
        self.assertNotIn("已计 1 票", mr["description"])
        self.assertEqual(mr["assignee_ids"], [4])
        # The branch carries one commit so that GitLab shows the Approve button.
        commit = self.state["commits"][0]
        self.assertEqual((commit["branch"], commit["start_branch"], commit["commit_message"]),
                         (mr["source_branch"], "main", "删除工程：example-group/app"))
        action = commit["actions"][0]
        self.assertEqual(action["action"], "create")
        self.assertRegex(action["file_path"], r"^requests/project-10-u-4-[0-9]+\.md$")
        self.assertEqual(action["content"].rstrip("\n"), mr["description"])
        self.assertEqual((self.state["deleted"], self.state["forwarded"]), ([], []))

    def test_a_second_deletion_reuses_the_open_request(self):
        self.web_delete("/example-group/app")
        status, response_headers, _ = self.web_delete("/example-group/app", who="alice")
        self.assertEqual((status, len(self.state["mrs"])), (303, 1))
        self.assertTrue(self.location(response_headers).endswith("/merge_requests/1"))

    def test_normal_users_need_two_admins(self):
        self.web_delete("/example-group/app")
        self.state["approvals"][1] = [4, 2]  # carol herself does not count
        self.hook(1)
        self.assertEqual(self.state["deleted"], [])
        self.state["approvals"][1] = [4, 2, 5]  # a blocked admin does not count
        self.hook(1)
        self.assertEqual(self.state["deleted"], [])
        self.state["approvals"][1] = [4, 2, 3]
        self.hook(1)
        self.assertEqual(self.state["deleted"], [("project", 10)])
        mr = self.state["mrs"][1]
        self.assertEqual(mr["state"], "closed")
        self.assertNotIn(mr["source_branch"], self.state["branches"])
        self.assertEqual(self.state["notes"], [(1, "已删除工程 `example-group/app`，同意的管理员：@alice、@bob。"
                                                  "工程已进入回收站，保留期内管理员可以在回收站恢复。")])
        self.assertIn("EXECUTED project 10 example-group/app for !1 approved by 2,3", self.log.getvalue())

    def test_an_admin_initiator_counts_as_one_vote(self):
        self.web_delete("/example-group/app", who="alice")
        mr = self.state["mrs"][1]
        self.assertIn("发起人是管理员，已计 1 票。", mr["description"])
        self.assertIn("请审批：@root @bob", mr["description"])
        self.state["approvals"][1] = [2]  # approving her own request adds nothing
        self.hook(1)
        self.assertEqual(self.state["deleted"], [])
        self.state["approvals"][1] = [2, 1]
        self.hook(1)
        self.assertEqual(self.state["deleted"], [("project", 10)])

    def test_threshold_one_lets_an_admin_delete_at_once(self):
        status, _, body = self.send("DELETE", "/api/v4/projects/example-group%2Fapp", required=1,
                                    header_list=[("PRIVATE-TOKEN", "alice-pat")])
        self.assertEqual((status, json.loads(body)), (202, {"message": "202 Accepted"}))
        self.assertEqual(self.state["deleted"], [("project", 10)])
        self.assertEqual(self.state["mrs"][1]["state"], "closed")
        status, response_headers, _ = self.web_delete("/groups/example-group/team", who="alice", required=1)
        self.assertEqual((status, self.state["deleted"][-1]), (303, ("group", 21)))
        self.assertTrue(self.location(response_headers).endswith("/merge_requests/2"))

    def test_api_and_script_deletions_get_json(self):
        cases = [("DELETE", "/api/v4/projects/10", [("PRIVATE-TOKEN", "carol-pat")]),
                 ("POST", "/api/v4/projects/10?private_token=bob-pat", [("Content-Type", "application/x-www-form-urlencoded")]),
                 ("DELETE", "/example-group/app", [("Authorization", "Bearer bob-oauth"), ("Accept", "application/json")]),
                 ("DELETE", "/api/v4/projects/10", [("Cookie", "_gitlab_session=carol"), ("X-CSRF-Token", "csrf-carol")])]
        for method, path, header_list in cases:
            body = b"_method=delete" if method == "POST" else b""
            status, _, response = self.send(method, path, body, header_list=header_list)
            message = json.loads(response)["message"]
            self.assertEqual(status, 403, path)
            self.assertIn("已转为删除申请：http://gitlab.example.com/example-group/deletion-requests/-/merge_requests/1", message)
        self.assertEqual(len(self.state["mrs"]), 1)
        self.assertEqual(self.state["deleted"], [])

    def test_credentials_are_checked_like_gitlab(self):
        refused = [
            self.web_delete("/example-group/app", csrf="csrf-forged"),  # session without a valid CSRF token
            self.web_delete("/example-group/app", csrf=""),
            self.send("DELETE", "/api/v4/projects/10", header_list=[("Cookie", "_gitlab_session=carol")]),
            self.send("DELETE", "/api/v4/projects/10", header_list=[("PRIVATE-TOKEN", "carol-read")]),  # read_api only
            self.send("DELETE", "/api/v4/projects/10", header_list=[("Authorization", "Bearer carol-oauth-read")]),
            self.send("DELETE", "/api/v4/projects/10", header_list=[("Job-Token", "job"), ("PRIVATE-TOKEN", "carol-pat")]),
            self.send("DELETE", "/api/v4/projects/10?job_token=job"),
            self.send("DELETE", "/api/v4/projects/10"),
        ]
        self.assertEqual([status for status, _, _ in refused], [401] * len(refused))
        self.assertEqual((self.state["mrs"], self.state["forwarded"]), ({}, []))

    def test_admin_area_hard_delete_becomes_a_request(self):
        status, _, _ = self.web_delete("/admin/projects/example-group/app", who="alice")
        self.assertEqual(status, 303)
        self.assertRegex(self.state["mrs"][1]["source_branch"], r"^delete/project-10/u-2-")
        self.assertEqual(self.state["forwarded"], [])

    def test_personal_projects_and_format_suffixes_are_controlled(self):
        self.assertEqual(self.web_delete("/carol/sandbox")[0], 303)
        self.assertRegex(self.state["mrs"][1]["source_branch"], r"^delete/project-12/u-4-")
        self.assertEqual(self.web_delete("/example-group/app.atom!")[0], 303)
        self.assertRegex(self.state["mrs"][2]["source_branch"], r"^delete/project-10/u-4-")

    def test_refusals(self):
        status, _, page = self.web_delete("/example-group/team/lib")  # carol is only a Developer
        self.assertEqual((status, b"404 Not Found" in page), (404, True))
        status, response_headers, page = self.web_delete("/example-group/old", who="alice")
        self.assertEqual(status, 403)
        self.assertIn("已在回收站", page.decode())
        self.assertIn("default-src 'none'", dict(response_headers)["Content-Security-Policy"])
        self.assertEqual((self.state["mrs"], self.state["forwarded"], self.state["deleted"]), ({}, [], []))

    def test_page_escapes_the_message(self):
        self.state["projects"][14] = {"id": 14, "path_with_namespace": "example-group/<b>x", "namespace": {"kind": "group"},
                                      "marked_for_deletion_on": "2026-12-01"}
        page = self.web_delete("/example-group/%3Cb%3Ex", who="alice")[2].decode()
        self.assertNotIn("<b>x", page)
        self.assertIn("&lt;b&gt;x", page)

    def test_other_delete_routes_are_forwarded(self):
        status, _, _ = self.send("DELETE", "/example-group/app/notes/5", header_list=[("PRIVATE-TOKEN", "carol-pat")])
        self.assertEqual(status, 201)
        self.assertEqual([entry[:2] for entry in self.state["forwarded"]], [("DELETE", "/example-group/app/notes/5")])
        self.assertEqual(self.state["mrs"], {})

    def test_imports_may_not_overwrite_a_project(self):
        form = [("Content-Type", "application/x-www-form-urlencoded"), ("PRIVATE-TOKEN", "carol-pat")]
        for path, body, header_list in (("/api/v4/projects/import?overwrite=true", b"path=app", form),
                                        ("/api/v4/projects/import", b"path=app&overwrite=1", form),
                                        ("/api/v4/projects/remote-import", b'{"path": "app", "overwrite": true}',
                                         [("Content-Type", "application/json")])):
            status, _, response = self.send("POST", path, body, header_list=header_list)
            self.assertEqual(status, 403, path)
            self.assertIn("导入不能覆盖已有工程", json.loads(response)["message"])
        status, _, _ = self.send("POST", "/api/v4/projects/import", b"path=app&overwrite=false", header_list=form)
        self.assertEqual((status, len(self.state["forwarded"])), (201, 1))
        archive = bytes(range(256)) * (12 * 4096)
        upload = multipart(b"up", (b'Content-Disposition: form-data; name="file"; filename="export.tar.gz"', archive),
                           (b'Content-Disposition: form-data; name="overwrite"', b"true"))
        status = self.send("POST", "/api/v4/projects/import", upload,
                           header_list=[("Content-Type", "multipart/form-data; boundary=up")])[0]
        self.assertEqual((status, len(self.state["forwarded"])), (413, 1))
        upload = multipart(b"up", (b'Content-Disposition: form-data; name="file"; filename="export.tar.gz"', archive))
        status = self.send("POST", "/api/v4/projects/import", upload,
                           header_list=[("Content-Type", "multipart/form-data; boundary=up")])[0]
        self.assertEqual((status, len(self.state["forwarded"])), (201, 2))
        big_json = b'{"path": "x", "pad": "' + b"x" * (dc.MAX_INSPECTED_BODY + 1) + b'"}'
        self.assertEqual(self.send("POST", "/api/v4/projects/remote-import", big_json,
                                   header_list=[("Content-Type", "application/json")])[0], 413)

    def test_normal_posts_are_forwarded_intact(self):
        settings = b"_method=patch&project%5Bname%5D=app"
        status, _, body = self.send("POST", "/example-group/app", settings, header_list=[("Content-Type", "application/x-www-form-urlencoded")])
        self.assertEqual((status, body), (201, b"upstream:" + hashlib.sha256(settings).hexdigest().encode()))
        self.assertEqual(self.state["forwarded"][0][3], settings)
        self.assertEqual(self.log.getvalue(), "")

    def test_disabled_forwards_everything(self):
        status, _, _ = self.web_delete("/example-group/app", required=0)
        self.assertEqual(status, 201)
        self.assertEqual(self.state["forwarded"][0][:2], ("POST", "/example-group/app"))

    def test_upstream_key_is_added_and_never_taken_from_clients(self):
        self.send("POST", "/example-group/app/-/issues", b"x=1", header_list=[("X-Deletion-Control-Key", "client-guess")])
        sent = self.state["forwarded"][0][2]
        self.assertEqual([value for name, value in sent if name.lower() == "x-deletion-control-key"], [KEY])
        self.write_secret(self.key_file, "short")
        self.assertEqual(self.send("POST", "/example-group/app/-/issues", b"x=1")[0], 502)
        self.assertEqual(self.web_delete("/example-group/app")[0], 503)
        self.write_secret(self.key_file, "m" * 40)  # does not match gitlab.rb
        status, _, page = self.web_delete("/example-group/app")
        self.assertEqual(status, 503)
        self.assertIn("refused the upstream key", page.decode())
        self.assertEqual(self.state["mrs"], {})

    def test_the_service_token_needs_administrator_access(self):
        for token, reason in (("carol-pat", "must belong to an administrator"),
                              ("admin-mode-token", "admin_mode scope")):
            self.write_secret(self.token_file, token)
            status, _, page = self.web_delete("/example-group/app")
            self.assertEqual(status, 503, token)
            self.assertIn(reason, page.decode())
            # An unresolved target is not forwarded either: without full visibility it proves nothing.
            status = self.send("DELETE", "/example-group/hidden-project", header_list=[("PRIVATE-TOKEN", "carol-pat")])[0]
            self.assertEqual(status, 503, token)
        self.assertEqual((self.state["mrs"], self.state["forwarded"], self.state["deleted"]), ({}, [], []))

    def test_zero_leaves_open_requests_alone(self):
        self.web_delete("/example-group/app")
        self.hook(1, action="update", required=0)  # switched off with a request still open
        self.state["approvals"][1] = [2, 3]
        self.hook(1, required=0)
        self.assertEqual((self.state["deleted"], self.state["mrs"][1]["state"]), ([], "opened"))

    def test_a_request_closed_while_counting_is_not_executed(self):
        self.web_delete("/example-group/app")
        self.state["approvals"][1] = [2, 3]
        self.state["close_on_count"] = True
        self.hook(1)
        self.assertEqual(self.state["deleted"], [])
        self.assertIn("SKIP project 10: !1 was closed while it was being counted", self.log.getvalue())

    def test_a_request_deletes_at_most_once(self):
        # The outcome note fails, an admin restores the project, then another event arrives.
        self.state["fail_notes"] = True
        status, _, body = self.send("DELETE", "/api/v4/projects/10", required=1, header_list=[("PRIVATE-TOKEN", "alice-pat")])
        self.assertEqual((status, json.loads(body)), (202, {"message": "202 Accepted"}))
        self.assertEqual((self.state["deleted"], self.state["mrs"][1]["state"]), ([("project", 10)], "closed"))
        self.assertIn("could not note the outcome on !1", self.log.getvalue())
        self.state["fail_notes"] = False
        del self.state["projects"][10]["marked_for_deletion_on"]  # restored from the recycle bin
        self.hook(1, action="update", required=1)
        self.assertEqual(self.state["delete_calls"], 1)
        self.assertNotIn("marked_for_deletion_on", self.state["projects"][10])

    def test_nothing_is_deleted_when_the_request_cannot_be_closed(self):
        self.state["fail_close"] = True
        status = self.send("DELETE", "/api/v4/projects/10", required=1, header_list=[("PRIVATE-TOKEN", "alice-pat")])[0]
        self.assertEqual((status, self.state["delete_calls"], self.state["mrs"][1]["state"]), (503, 0, "opened"))

    def test_a_request_is_retired_before_anything_is_deleted(self):
        # GitLab refuses to reopen a merge request without its source branch, so the
        # target is only deleted once the request is closed and its branch is gone.
        self.state["fail_branch_delete"] = True
        status = self.send("DELETE", "/api/v4/projects/10", required=1, header_list=[("PRIVATE-TOKEN", "alice-pat")])[0]
        mr = self.state["mrs"][1]
        self.assertEqual((status, self.state["delete_calls"], mr["state"]), (503, 0, "closed"))
        self.assertIn(mr["source_branch"], self.state["branches"])
        self.assertIn("未执行删除：清理申请分支失败", self.state["notes"][0][1])
        # With the branch still there the request can be reopened; it then runs once.
        self.state["fail_branch_delete"] = False
        mr["state"] = "opened"
        self.hook(1, action="reopen", required=1)
        self.assertEqual((self.state["delete_calls"], mr["state"]), (1, "closed"))
        self.assertNotIn(mr["source_branch"], self.state["branches"])

    def test_a_lost_delete_answer_is_reported_as_unknown(self):
        self.state["drop_delete_response"] = True
        status, _, body = self.send("DELETE", "/api/v4/projects/10", required=1, header_list=[("PRIVATE-TOKEN", "alice-pat")])
        message = json.loads(body)["message"]
        self.assertEqual(status, 504)
        self.assertIn("结果待确认", message)
        self.assertNotIn("删除没有执行", message)
        mr = self.state["mrs"][1]
        self.assertEqual(mr["state"], "closed")
        self.assertNotIn(mr["source_branch"], self.state["branches"])
        self.assertIn("结果待确认", self.state["notes"][0][1])
        self.assertIn("UNKNOWN project 10 for !1", self.log.getvalue())
        self.state["drop_delete_response"] = False
        self.hook(1, action="update", required=1)  # no automatic retry
        self.assertEqual(self.state["delete_calls"], 1)

    def test_losing_admin_access_mid_request_never_forwards_a_deletion(self):
        # Demoted right after the access check. Had the check come before the lookup, the
        # lookup would then see nothing and the deletion would be forwarded with no votes.
        self.state["demote_after_check"] = True
        status = self.web_delete("/example-group/app")[0]
        self.assertEqual((status, self.state["forwarded"], self.state["deleted"]), (503, [], []))
        # Demoted before the lookup: the target is hidden, and the check that follows refuses.
        status = self.web_delete("/example-group/team/lib")[0]
        self.assertEqual((status, self.state["forwarded"], self.state["deleted"]), (503, [], []))

    def test_admin_access_is_checked_on_every_deletion(self):
        self.assertEqual(self.web_delete("/example-group/app")[0], 303)
        self.state["statistics_denied"] = True  # the same token loses administrator access
        status, _, page = self.web_delete("/example-group/team/lib")
        self.assertEqual(status, 503)
        self.assertIn("no administrator access", page.decode())
        status = self.send("DELETE", "/example-group/hidden-project", header_list=[("PRIVATE-TOKEN", "carol-pat")])[0]
        self.assertEqual((status, self.state["forwarded"]), (503, []))

    def test_hooks_only_act_on_own_requests(self):
        self.web_delete("/example-group/app")
        self.state["approvals"][1] = [1, 2, 3]
        self.hook(1, project_id=99)
        self.state["mrs"][1]["author"] = {"id": 2}  # same branch name, but not created by the service
        self.hook(1)
        self.assertEqual(self.state["deleted"], [])
        self.state["mrs"][1]["author"] = {"id": 90}
        self.hook(1, action="update")  # any event re-counts
        self.assertEqual(self.state["deleted"], [("project", 10)])

    def test_hooks_are_not_served_on_the_proxied_port(self):
        self.web_delete("/example-group/app")
        self.state["approvals"][1] = [1, 2, 3]
        payload = json.dumps({"object_kind": "merge_request", "project": {"id": 30}, "object_attributes": {"iid": 1}}).encode()
        for path in ("/hook", "/-/deletion-control/hook"):
            self.send("POST", path, payload, header_list=[("Content-Type", "application/json"), ("X-HTTP-Method-Override", "PATCH")])
        self.hooks[2].queue.join()
        self.assertEqual(self.state["deleted"], [])

    def test_closing_a_request_removes_its_branch(self):
        self.web_delete("/example-group/app")
        mr = self.state["mrs"][1]
        mr["state"] = "closed"
        self.hook(1, action="close")
        self.assertNotIn(mr["source_branch"], self.state["branches"])
        self.assertEqual(self.state["deleted"], [])

    def test_a_failed_deletion_closes_the_request(self):
        self.state["delete_status"] = 400
        self.web_delete("/example-group/app", who="alice")
        self.state["approvals"][1] = [3]
        self.hook(1)
        self.assertEqual(self.state["mrs"][1]["state"], "closed")
        self.assertIn("失败：GitLab 返回 400（boom）。申请已关闭", self.state["notes"][0][1])
        self.hook(1, action="update")  # a used request is not tried again
        self.assertEqual((self.state["delete_calls"], self.state["deleted"]), (1, []))

    def test_assignee_rejection_falls_back_to_the_mention(self):
        self.state["reject_assignee"] = True
        self.assertEqual(self.web_delete("/example-group/app")[0], 303)
        self.assertEqual(self.state["mrs"][1]["assignee_ids"], [])

    def test_token_problems_refuse_with_503(self):
        self.write_secret(self.token_file, "")
        status, _, page = self.web_delete("/example-group/app")
        self.assertEqual(status, 503)
        self.assertIn("删除没有执行", page.decode())
        self.write_secret(self.token_file, "stale-token-7")
        self.assertEqual(self.web_delete("/example-group/app")[0], 503)
        self.assertIn("service token was rejected", self.log.getvalue())
        self.assertEqual((self.state["mrs"], self.state["forwarded"]), ({}, []))

    def test_a_renewed_token_for_another_account_is_picked_up(self):
        self.web_delete("/example-group/app")
        self.state["users"][91] = {"id": 91, "username": "deletion-bot-2", "is_admin": True, "state": "active", "bot": False}
        self.state["credentials"]["PRIVATE-TOKEN=svc-token-2"] = (91, ["api"])
        self.write_secret(self.token_file, "svc-token-2")
        self.state["approvals"][1] = [1, 2, 3]
        self.hook(1)  # The request was opened by the old account, so it is no longer trusted.
        self.assertEqual(self.state["deleted"], [])

    def test_headers_are_preserved_and_hop_by_hop_headers_removed(self):
        status, response_headers, _ = self.send("POST", "/example-group/app/-/issues", b"x=1", header_list=[
            ("X-Custom", "one"), ("X-Custom", "two"), ("Cookie", "_gitlab_session=s"),
            ("Connection", "keep-alive, X-Hop"), ("Keep-Alive", "timeout=5"), ("TE", "trailers"),
            ("X-Hop", "drop"), ("Upgrade", "h2c")])
        self.assertEqual(status, 201)
        sent = self.state["forwarded"][0][2]
        names = [name.lower() for name, _ in sent]
        self.assertEqual([value for name, value in sent if name.lower() == "x-custom"], ["one", "two"])
        self.assertIn(("Host", "gitlab.example.com"), sent)
        for hop in ("keep-alive", "te", "x-hop", "upgrade"):
            self.assertNotIn(hop, names)
        self.assertEqual([value for name, value in response_headers if name.lower() == "set-cookie"], ["a=1", "b=2"])

    def test_redirects_are_returned_not_followed(self):
        status, response_headers, _ = self.send("POST", "/redirect", b"a=1")
        self.assertEqual((status, self.location(response_headers)), (302, "/elsewhere"))

    def test_large_bodies_are_streamed_intact(self):
        data = bytes(range(256)) * (12 * 4096)  # 12 MiB, above the inspection limit
        status, _, response = self.send("POST", "/example-group/app/uploads", data,
                                        header_list=[("Content-Type", "application/octet-stream")])
        self.assertEqual((status, response), (201, b"upstream:" + hashlib.sha256(data).hexdigest().encode()))
        data = data[:-64] + b"helper_method_name _method=delete"
        upload = multipart(b"up", (b'Content-Disposition: form-data; name="file"; filename="log.bin"', data))
        status, _, response = self.send("POST", "/example-group/app/uploads", upload,
                                        header_list=[("Content-Type", "multipart/form-data; boundary=up")])
        self.assertEqual((status, response), (201, b"upstream:" + hashlib.sha256(upload).hexdigest().encode()))

    def test_uninspectable_requests_are_refused(self):
        padding = b"x" * (dc.MAX_INSPECTED_BODY + 1)
        for content_type in ("application/x-www-form-urlencoded", "application/x-www-form-urlencoded,x"):
            self.assertEqual(self.send("POST", "/example-group/app", b"_method=delete&" + padding,
                                       header_list=[("Content-Type", content_type)])[0], 413, content_type)
        padded = multipart(b"pad", (b'Content-Disposition: form-data; name="file"; filename="a"', padding),
                           (b"Content-ID: _method", b"delete"))
        self.assertEqual(self.send("POST", "/example-group/app", padded,
                                   header_list=[("Content-Type", "multipart/form-data; boundary=pad")])[0], 413)
        with socket.create_connection(("127.0.0.1", self.servers[2].server_address[1]), 10) as sock:
            sock.sendall(b"POST /example-group/app HTTP/1.1\r\nHost: gitlab.example.com\r\n"
                         b"Transfer-Encoding: chunked\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n"
                         b"e\r\n_method=delete\r\n0\r\n\r\n")
            response = http.client.HTTPResponse(sock)
            response.begin()
            self.assertEqual(response.status, 400)
        self.assertEqual(self.state["forwarded"], [])

    def test_health_and_routing_check(self):
        self.assertEqual(self.send("GET", "/healthz")[::2], (200, b"ok\n"))
        status, _, body = self.send("POST", dc.CHECK_PATH)
        self.assertEqual((status, body), (200, b"deletion-control: requests reach this service\n"))
        self.assertEqual(self.state["forwarded"], [])

    def test_no_credentials_in_logs(self):
        self.send("DELETE", "/api/v4/projects/10?private_token=bob-pat")
        self.web_delete("/example-group/team/lib")
        self.write_secret(self.token_file, "stale-token-7")
        self.web_delete("/example-group/app")
        for secret in ("bob-pat", "svc-token", "stale-token-7", "_gitlab_session", "csrf-carol", KEY):
            self.assertNotIn(secret, self.log.getvalue())


class Hooks(unittest.TestCase):
    def test_queue_is_bounded_and_deduplicated(self):
        release = threading.Event()
        seen = []

        class SlowControl:
            def handle_hook(self, iid):
                seen.append(iid)
                release.wait(5)

        hooks = dc.HookQueue(SlowControl())
        self.assertTrue(hooks.enqueue(1))
        while not seen:
            release.wait(0.01)
        self.assertTrue(hooks.enqueue(2))
        self.assertTrue(hooks.enqueue(2))  # already waiting: not queued twice
        self.assertEqual(hooks.queue.qsize(), 1)
        for iid in range(3, dc.MAX_QUEUED_HOOKS + 2):
            self.assertTrue(hooks.enqueue(iid))
        self.assertFalse(hooks.enqueue(10_000))
        release.set()
        hooks.join()
        self.assertEqual(seen[:2], [1, 2])


class PassResult(unittest.TextTestResult):
    def addSuccess(self, test):
        super().addSuccess(test)
        print(f"PASS: deletion-control / {type(test).__name__} / {test._testMethodName[5:].replace('_', ' ')}", flush=True)


suite = unittest.TestSuite(unittest.defaultTestLoader.loadTestsFromTestCase(case)
                           for case in (Candidates, DeleteDetection, LargeUploadScan, NginxRouting, Configuration, Service, Hooks))
result = unittest.TextTestRunner(stream=sys.stderr, verbosity=0, resultclass=PassResult).run(suite)
if not result.wasSuccessful():
    sys.exit(1)
print(f"All {result.testsRun} deletion-control tests passed.")
PY
