#!/usr/bin/env python3
"""Turn GitLab project and group deletions into merge requests that admins approve.

Runs as the deletion-control Compose service; see docs/deletion-control.md.
GitLab's bundled Nginx (ops/deletion-control/gitlab.rb.example) sends requests
that could delete a project or group to port 8931; everything else never
arrives. A deletion becomes a merge request in DELETION_REQUESTS_PROJECT,
created by the service account whose token this program holds. Once the
initiator (if an admin) and the admins who clicked Approve reach
DELETION_REQUIRED_ADMINS, the program deletes the target through the GitLab
API, so it goes to the recycle bin. A system hook on port 8933 reports each
Approve. Every other request is forwarded to GitLab unchanged through the
internal port 8932, which only accepts requests carrying the upstream key.
Standard library only; keep compatible with Python 3.9+.
"""
import html
import http.client
import json
import os
import queue
import re
import signal
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_PORT = 8931
HOOK_PORT = 8933
DEFAULT_UPSTREAM = "http://gitlab:8932"
DEFAULT_TOKEN_FILE = "/run/secrets/deletion-control/token"
DEFAULT_KEY_FILE = "/run/secrets/deletion-control/upstream-key"
KEY_HEADER = "X-Deletion-Control-Key"
CHECK_PATH = "/.deletion-control"
# Settings forms (with avatars) are far smaller. Larger form bodies that could
# carry _method are refused instead of being forwarded uninspected.
MAX_INSPECTED_BODY = 8 * 1024 * 1024
MAX_PART_HEADER = 16 * 1024
MAX_HOOK_BODY = 1024 * 1024
MAX_QUEUED_HOOKS = 200
UPSTREAM_TIMEOUT = 900
API_TIMEOUT = 60
CHUNK = 64 * 1024
HOP_BY_HOP = frozenset({
    "connection", "keep-alive", "proxy-connection", "proxy-authenticate",
    "proxy-authorization", "te", "trailer", "trailers", "transfer-encoding", "upgrade",
})
PROJECT_PATH = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_.][A-Za-z0-9_.-]*)+")
UPSTREAM_KEY = re.compile(r"[A-Za-z0-9]{32,128}")
# delete/<kind>-<target id>/u-<initiator id>-<milliseconds>; a source branch cannot be renamed.
BRANCH = re.compile(r"delete/(project|group)-([0-9]+)/u-([0-9]+)-[0-9]+")
# Project imports that may overwrite (and so destroy) an existing project.
IMPORT_ENDPOINTS = frozenset({"import", "remote-import", "remote-import-s3"})
NOUNS = {"project": "工程", "group": "组"}
# Rack: %r|\Amultipart/.*boundary=\"?([^\";,]+)\"?|ni. The lookahead yields every
# boundary= occurrence, including the last one that Rack's greedy match picks.
BOUNDARY = re.compile(r'(?=boundary="?([^";,]+)"?)', re.I)
FALSE_VALUES = frozenset({"", "0", "false", "f", "no", "n", "off"})


class ConfigError(Exception):
    pass


class GitLabError(Exception):
    """GitLab could not be asked; the deletion is neither executed nor forwarded."""


class Config:
    def __init__(self, required_admins, requests_project, token_file, key_file, upstream):
        self.required_admins = required_admins
        self.requests_project = requests_project
        self.token_file = token_file
        self.key_file = key_file
        self.upstream = upstream


def load_config(env):
    required = env.get("DELETION_REQUIRED_ADMINS", "").strip() or "0"
    if not re.fullmatch(r"[0-9]{1,2}", required):
        raise ConfigError("DELETION_REQUIRED_ADMINS must be an integer from 0 to 99")
    project = env.get("DELETION_REQUESTS_PROJECT", "").strip().strip("/")
    if int(required) and not PROJECT_PATH.fullmatch(project):
        raise ConfigError("DELETION_REQUESTS_PROJECT must be a full project path such as deletion-bot/deletion-requests")
    upstream = urllib.parse.urlsplit(env.get("DELETION_GITLAB_URL", "").strip() or DEFAULT_UPSTREAM)
    if upstream.scheme != "http" or not upstream.hostname or upstream.path not in ("", "/"):
        raise ConfigError("DELETION_GITLAB_URL must be http://host[:port]")
    return Config(int(required), project, env.get("DELETION_TOKEN_FILE", "").strip() or DEFAULT_TOKEN_FILE,
                  env.get("DELETION_UPSTREAM_KEY_FILE", "").strip() or DEFAULT_KEY_FILE,
                  (upstream.hostname, upstream.port or 80))


def log(message):
    stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    sys.stderr.write(f"{stamp} deletion-control: {message}\n")
    sys.stderr.flush()


def printable(value, limit=512):
    return re.sub(r"[^\x21-\x7e]", "?", str(value) if value is not None else "-")[:limit]


def read_secret(path, name):
    try:
        with open(path, encoding="utf-8") as handle:
            value = handle.read().strip()
    except OSError as error:
        raise GitLabError(f"cannot read the {name} file ({error.strerror})") from None
    if not value:
        raise GitLabError(f"the {name} file is empty")
    return value


def request_path(target):
    """Path part of an origin-form or absolute-form request target, without the query."""
    if not target.startswith("/"):
        target = urllib.parse.urlsplit(target).path or "/"
    return target.split("?", 1)[0]


def dot_resolved(segments):
    resolved = []
    for segment in segments:
        if segment in ("", "."):
            continue
        if segment == "..":
            if resolved:
                resolved.pop()
            continue
        resolved.append(segment)
    return resolved


def with_format_variants(ref):
    """Rails routes accept an optional .format suffix of almost any characters;
    try the path cut at every dot of its last segment."""
    head, _, last = ref.rpartition("/")
    variants = [ref]
    position = last.find(".")
    while position > 0:
        variants.append((head + "/" if head else "") + last[:position])
        position = last.find(".", position + 1)
    return list(dict.fromkeys(variants))


def api_segments(target):
    # API ids are one raw segment that may contain %2F, so decode per segment.
    return dot_resolved(urllib.parse.unquote(segment, errors="replace") for segment in request_path(target).split("/"))


def deletion_candidates(target):
    """(kind, ref) pairs a DELETE to this path could remove; kind is project,
    group or any, ref a full path or numeric ID. Empty when the path cannot be a
    project or group destroy route. Over-matching is safe: a candidate that is
    not an existing project or group is forwarded unchanged."""
    raw = api_segments(target)
    if raw[:1] and raw[0].lower() == "api":
        if len(raw) == 4 and raw[1].lower() == "v4" and raw[2].lower() in ("projects", "groups"):
            kind = "project" if raw[2].lower() == "projects" else "group"
            return [(kind, ref) for ref in with_format_variants(raw[3])]
        return []
    # Web routes see the fully decoded path.
    segments = dot_resolved(urllib.parse.unquote(request_path(target), errors="replace").split("/"))
    if "-" in segments:
        return []
    candidates = web_candidates(segments)
    if len(segments) >= 3 and segments[0].lower() == "o":
        candidates += web_candidates(segments[2:])  # Organization-scoped paths: /o/<organization>/...
    return list(dict.fromkeys(candidates))


def web_candidates(segments):
    head = [segment.lower() for segment in segments[:2]]
    if head == ["admin", "projects"]:
        kind, rest = "project", segments[2:]
    elif head == ["admin", "groups"]:
        kind, rest = "group", segments[2:]
    elif head[:1] == ["groups"]:
        kind, rest = "group", segments[1:]
    else:
        kind, rest = "any", segments
    if not rest or (kind == "project" and len(rest) < 2):
        return []
    if kind == "any" and len(rest) == 1:
        kind = "group"  # A project always has a namespace.
    return [(kind, ref) for ref in with_format_variants("/".join(rest))]


def import_endpoint(target):
    raw = api_segments(target)
    return len(raw) == 4 and [part.lower() for part in raw[:3]] == ["api", "v4", "projects"] and raw[3].lower() in IMPORT_ENDPOINTS


def urlencoded_values(body, field):
    values = []
    # Rack 2 also splits on ";" and skips spaces after separators.
    for piece in re.split(r"[&;]", body.decode("latin-1")):
        key, _, value = piece.partition("=")
        if urllib.parse.unquote_plus(key, encoding="latin-1").strip().lower() == field:
            values.append(urllib.parse.unquote_plus(value, encoding="latin-1"))
    return values


def mentions(head, fields):
    """Whether a multipart part header mentions one of the fields anywhere: in
    name=, Content-ID (which Rack also uses as a name) or escaped. Over-matching
    only refuses more."""
    text = head.decode("latin-1").replace("\\", "").lower()
    return any(field in text for field in fields)


def multipart_values(body, boundary, field):
    values = []
    # Parts after the closing delimiter are scanned too: matching more is safe.
    for part in body.split(b"--" + boundary)[1:]:
        head, separator, value = part.partition(b"\r\n\r\n")
        if not separator:
            head, separator, value = part.partition(b"\n\n")
        if separator and mentions(head, (field,)):
            values.append(value.rstrip(b"\r\n").decode("latin-1"))
    return values


def multipart_boundaries(content_type):
    boundaries = set()
    for match in BOUNDARY.finditer(content_type or ""):
        boundaries.update({match.group(1), match.group(1).strip()})
    boundaries.discard("")
    return {boundary.encode("latin-1") for boundary in boundaries}


def field_values(headers, body, field):
    """Values Rack could read for a form field. Parses the body as urlencoded and
    as multipart with every boundary in any Content-Type, whatever the media
    type says: reading more than Rack would only refuses more."""
    values = urlencoded_values(body, field)
    for content_type in content_types(headers):
        for boundary in multipart_boundaries(content_type):
            values.extend(multipart_values(body, boundary, field))
    return values


class MultipartWatch:
    """Streaming check of a large multipart body for parts that mention one of
    the fields. Only part headers are inspected, so file contents never cause a
    refusal."""

    def __init__(self, boundaries, fields=("_method",)):
        self.delimiters = [b"--" + boundary for boundary in boundaries]
        self.fields = fields
        self.carry = max(len(delimiter) for delimiter in self.delimiters) - 1
        self.buffer = b""

    def suspicious(self, chunk):
        """True once the stream mentions a field in a part header, or a header is implausibly long."""
        self.buffer += chunk
        keep = max(0, len(self.buffer) - self.carry)
        for delimiter in self.delimiters:
            position = 0
            while True:
                found = self.buffer.find(delimiter, position)
                if found < 0:
                    break
                start = found + len(delimiter)
                ends = [end for end in (self.buffer.find(b"\r\n\r\n", start), self.buffer.find(b"\n\n", start)) if end >= 0]
                if not ends:
                    if len(self.buffer) - start > MAX_PART_HEADER:
                        return True
                    keep = min(keep, found)  # Header continues in the next chunk.
                    break
                if mentions(self.buffer[start:min(ends)], self.fields):
                    return True
                position = min(ends)
        self.buffer = self.buffer[keep:]
        return False


def content_types(headers):
    values = headers.get_all("Content-Type") or [None]
    if len(values) > 1:
        values.append(", ".join(values))
    return values


def media_types(headers):
    # Rack's media type ends at the first ";" or ",".
    return {re.split(r"[;,]", value or "", 1)[0].strip().lower() for value in content_types(headers)}


def override_header_deletes(headers):
    return any("delete" in value.lower() for value in headers.get_all("X-HTTP-Method-Override") or [])


def requests_delete(method, headers, body):
    if method == "DELETE" or override_header_deletes(headers):
        return True
    return method == "POST" and any(value.strip().lower() == "delete" for value in field_values(headers, body, "_method"))


def import_overwrites(target, headers, body):
    """Whether a project import asks to overwrite (and so destroy) an existing project."""
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(target).query, keep_blank_values=True)
    values = [value for key, items in query.items() if key.lower() == "overwrite" for value in items]
    values += field_values(headers, body, "overwrite")
    try:
        document = json.loads(body) if body.strip()[:1] == b"{" else None
    except ValueError:
        document = None
    if isinstance(document, dict):
        values += [str(value) for key, value in document.items() if key.lower() == "overwrite"]
    return any(str(value).strip().lower() not in FALSE_VALUES for value in values)


class GitLab:
    """Minimal GitLab REST client over the internal port. Secrets are read on
    every call, so a renewed token written into the same file takes effect
    without a restart."""

    def __init__(self, upstream, token_file, key_file):
        self.host, self.port = upstream
        self.token_file = token_file
        self.key_file = key_file

    def token(self):
        return read_secret(self.token_file, "token")

    def key(self):
        key = read_secret(self.key_file, "upstream key")
        if not UPSTREAM_KEY.fullmatch(key):
            raise GitLabError("the upstream key must be 32 to 128 letters or digits")
        return key

    def call(self, method, path, params=None, data=None, credentials=None):
        """(status, decoded JSON or None). credentials replaces the service token."""
        url = (path if path.startswith("/") else f"/api/v4/{path}") + (f"?{urllib.parse.urlencode(params)}" if params else "")
        body = json.dumps(data).encode("utf-8") if data is not None else None
        headers = {"Accept": "application/json", KEY_HEADER: self.key()}
        if body is not None:
            headers["Content-Type"] = "application/json"
        if credentials is None:
            headers["PRIVATE-TOKEN"] = self.token()
        else:
            headers.update(credentials)
        connection = http.client.HTTPConnection(self.host, self.port, timeout=API_TIMEOUT)
        try:
            connection.request(method, url, body=body, headers=headers)
            response = connection.getresponse()
            raw = response.read()
        except (OSError, http.client.HTTPException) as error:
            raise GitLabError(f"GitLab is unreachable ({error})") from None
        finally:
            connection.close()
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = None
        if response.status == 401 and credentials is None:
            raise GitLabError("the service token was rejected (expired or revoked?)")
        if response.status == 403 and payload is None and b"upstream key" in raw:
            raise GitLabError("the internal GitLab port refused the upstream key; compare it with gitlab.rb")
        return response.status, payload

    def get(self, path, params=None):
        status, payload = self.call("GET", path, params)
        if status == 404:
            return None
        if status != 200:
            raise GitLabError(f"GET {path} returned {status}")
        return payload

    def pages(self, path, params, limit=20):
        items = []
        for page in range(1, limit + 1):
            batch = self.get(path, dict(params, per_page=100, page=page)) or []
            items.extend(batch)
            if len(batch) < 100:
                break
        return items

    def write(self, method, path, data=None, ok=(200, 201, 202, 204)):
        status, payload = self.call(method, path, data=data)
        if status not in ok:
            message = payload.get("message") if isinstance(payload, dict) else None
            raise GitLabError(f"{method} {path} returned {status}" + (f": {message}" if message else ""))
        return payload


class Credentials:
    """What a request authenticates with, the way GitLab's API reads it."""

    def __init__(self, handler, body):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(handler.path).query)
        self.tokens = {name: handler.headers[name] for name in ("Private-Token", "Authorization") if handler.headers.get(name)}
        self.params = {name: query[name][0] for name in ("private_token", "access_token") if query.get(name)}
        self.job = bool(handler.headers.get("Job-Token") or query.get("job_token"))
        self.cookie = handler.headers.get("Cookie")
        csrf = handler.headers.get("X-CSRF-Token") or next(iter(field_values(handler.headers, body, "authenticity_token")), None)
        self.csrf = csrf.strip() if csrf else None


class Outcome:
    def __init__(self, kind, status=200, message="", url=None):
        self.kind = kind  # forward, refuse, pending, executed
        self.status = status
        self.message = message
        self.url = url


class Control:
    """Deletion requests. One lock serializes them: they are rare, and it keeps
    a request from being created or executed twice."""

    def __init__(self, config, gitlab):
        self.config = config
        self.gitlab = gitlab
        self.lock = threading.Lock()
        self._service = (None, None)
        self._project = None

    # Lookups -------------------------------------------------------------
    def service(self):
        token = self.gitlab.token()
        if self._service[0] != token:  # A renewed token may belong to another account.
            user = self.gitlab.get("user")
            if not user or not user.get("is_admin"):
                raise GitLabError("the service token must belong to an administrator")
            self._service = (token, user)
        return self._service[1]

    def ensure_admin_access(self):
        """Checked on every deletion, never cached: without administrator access the
        program cannot see every project, and would forward deletions of the ones it
        cannot see. An account can be demoted, or Admin Mode turned on, at any time."""
        self.service()
        status, _ = self.gitlab.call("GET", "application/statistics")
        if status != 200:
            raise GitLabError(f"the service token has no administrator access ({status}); "
                              "with Admin Mode on it also needs the admin_mode scope")

    def requests_project(self):
        if self._project is None:
            project = self.gitlab.get("projects/" + urllib.parse.quote(self.config.requests_project, safe=""))
            if not project or not project.get("default_branch"):
                raise GitLabError(f"requests project {self.config.requests_project} is missing or has no default branch")
            self._project = project
        return self._project

    def admin(self, user_id):
        """The user, if an active human administrator other than the service account."""
        user = self.gitlab.get(f"users/{int(user_id)}")
        if (not user or not user.get("is_admin") or user.get("state") != "active" or user.get("bot")
                or user["id"] == self.service()["id"]):
            return None
        return user

    def admins(self):
        users = self.gitlab.pages("users", {"admins": "true", "active": "true"})
        return [user for user in users if user.get("is_admin") and not user.get("bot")
                and user["id"] != self.service()["id"]]

    def identify(self, credentials):
        """The user who sent a request, checked as strictly as GitLab would for a
        deletion; None if the request could not have deleted anything."""
        if credentials.job:
            return None  # CI job tokens cannot delete projects or groups.
        if credentials.tokens or credentials.params:
            scopes = self.token_scopes(credentials)
            if scopes is None or "api" not in scopes:
                return None
            return self.current_user(credentials.tokens, credentials.params)
        if credentials.cookie:
            if not credentials.csrf:
                return None
            # A session counts only with a valid CSRF token, as for any GitLab write. This
            # write fails validation (400) without changing anything; 401 means the
            # session or token was not accepted.
            status, _ = self.gitlab.call("PUT", "user/preferences", data={},
                                         credentials={"Cookie": credentials.cookie, "X-CSRF-Token": credentials.csrf})
            if status == 401:
                return None
            if status not in (200, 400):
                raise GitLabError(f"checking the session returned {status}")
            return self.current_user({"Cookie": credentials.cookie}, {})
        return None

    def token_scopes(self, credentials):
        status, info = self.gitlab.call("GET", "personal_access_tokens/self", credentials.params or None,
                                        credentials=credentials.tokens)
        if status == 200 and isinstance(info, dict):
            return info.get("scopes") if info.get("active", True) and not info.get("revoked") else None
        if (credentials.tokens.get("Authorization") or "").lower().startswith("bearer ") or credentials.params.get("access_token"):
            status, info = self.gitlab.call("GET", "/oauth/token/info", credentials.params or None, credentials=credentials.tokens)
            if status == 200 and isinstance(info, dict):
                return info.get("scope") or info.get("scopes")
        if status in (401, 403, 404):
            return None
        raise GitLabError(f"checking the token scopes returned {status}")

    def current_user(self, headers, params):
        status, user = self.gitlab.call("GET", "user", params or None, credentials=headers)
        if status in (401, 403):
            return None
        if status != 200 or not isinstance(user, dict) or "id" not in user:
            raise GitLabError(f"identifying the requester returned {status}")
        return user

    def resolve(self, candidates):
        for kind, ref in candidates:
            for each in (("project", "group") if kind == "any" else (kind,)):
                found = self.gitlab.get(f"{each}s/" + urllib.parse.quote(ref, safe=""),
                                        {"with_projects": "false"} if each == "group" else None)
                if found:
                    return each, found
        return None

    def target(self, kind, target_id):
        return self.gitlab.get(f"{kind}s/{int(target_id)}", {"with_projects": "false"} if kind == "group" else None)

    def can_delete(self, kind, target, user):
        """GitLab lets Owners and administrators delete a project or group."""
        if self.admin(user["id"]):
            return True
        if kind == "project" and (target.get("namespace") or {}).get("kind") == "user" \
                and (target.get("owner") or {}).get("id") == user["id"]:
            return True
        member = self.gitlab.get(f"{kind}s/{target['id']}/members/all/{int(user['id'])}")
        return bool(member) and member.get("access_level", 0) >= 50

    # Requests --------------------------------------------------------------
    def ours(self, mr):
        match = BRANCH.fullmatch(mr.get("source_branch") or "")
        if not match or (mr.get("author") or {}).get("id") != self.service()["id"]:
            return None
        return match.group(1), int(match.group(2)), int(match.group(3))

    def open_request(self, kind, target_id):
        project = self.requests_project()
        for mr in self.gitlab.pages(f"projects/{project['id']}/merge_requests", {"state": "opened"}):
            parsed = self.ours(mr)
            if parsed and parsed[:2] == (kind, target_id):
                return mr
        return None

    def create_request(self, kind, target, user):
        project = self.requests_project()
        noun, path = NOUNS[kind], full_path(kind, target)
        branch = f"delete/{kind}-{target['id']}/u-{user['id']}-{int(time.time() * 1000)}"
        others = [admin for admin in self.admins() if admin["id"] != user["id"]]
        initiator_is_admin = self.admin(user["id"]) is not None
        required = self.config.required_admins
        lines = [
            f"@{user['username']} 申请删除{noun} `{path}`（ID {target['id']}）。",
            "",
            f"- 需要 {required} 位管理员同意。" + ("发起人是管理员，已计 1 票。" if initiator_is_admin else ""),
            "- 同意：管理员点 **Approve**。票数够了程序立即删除，删除对象进入回收站，保留期内管理员可以恢复。",
            "- 拒绝：关闭这个合并请求。",
        ]
        if others:
            lines += ["", "请审批：" + " ".join(f"@{admin['username']}" for admin in others)]
        # GitLab hides the Approve button on a merge request without changes, so the
        # request branch carries one commit that adds a file describing the request.
        self.gitlab.write("POST", f"projects/{project['id']}/repository/commits", {
            "branch": branch, "start_branch": project["default_branch"], "commit_message": f"删除{noun}：{path}",
            "actions": [{"action": "create", "file_path": f"requests/{branch[len('delete/'):].replace('/', '-')}.md",
                         "content": "\n".join(lines) + "\n"}]})
        data = {"source_branch": branch, "target_branch": project["default_branch"],
                "title": f"删除{noun}：{path}", "description": "\n".join(lines),
                "remove_source_branch": True, "assignee_ids": [user["id"]]}
        status, mr = self.gitlab.call("POST", f"projects/{project['id']}/merge_requests", data=data)
        if status in (400, 403, 422):
            # Assigning someone without access to the requests project can fail; the mention is enough.
            data.pop("assignee_ids")
            status, mr = self.gitlab.call("POST", f"projects/{project['id']}/merge_requests", data=data)
        if status != 201 or not isinstance(mr, dict):
            self.delete_branch(branch)
            raise GitLabError(f"creating the merge request returned {status}")
        log(f"REQUEST {kind} {target['id']} {printable(path)} by user {user['id']} -> !{mr['iid']}")
        return mr

    def voters(self, mr, initiator_id):
        project = self.requests_project()
        approvals = self.gitlab.get(f"projects/{project['id']}/merge_requests/{mr['iid']}/approvals") or {}
        ids = [initiator_id] + [entry["user"]["id"] for entry in approvals.get("approved_by", [])]
        admins = []
        for user_id in dict.fromkeys(ids):
            admin = self.admin(user_id)
            if admin:
                admins.append(admin)
        return admins

    def settle(self, mr):
        """Execute an open request once enough admins agree. Caller holds the lock."""
        kind, target_id, initiator_id = self.ours(mr)
        admins = self.voters(mr, initiator_id)
        if len(admins) < self.config.required_admins:
            return Outcome("pending", 403, f"删除需要 {self.config.required_admins} 位管理员同意，"
                           f"目前 {len(admins)} 位，已转为删除申请：{mr['web_url']}", mr["web_url"])
        return self.execute(mr, kind, target_id, admins)

    def execute(self, mr, kind, target_id, admins):
        noun = NOUNS[kind]
        target = self.target(kind, target_id)
        if not target:
            self.finish(mr, f"{noun}（ID {target_id}）已不存在，未执行删除，申请关闭。")
            return Outcome("refuse", 404, f"{noun}已不存在", mr["web_url"])
        path = full_path(kind, target)
        if scheduled(target):
            self.finish(mr, f"{noun} `{path}` 已在回收站，未重复删除，申请关闭。")
            return Outcome("refuse", 409, f"{noun}已在回收站", mr["web_url"])
        # Counting took several calls; an admin may have closed the request meanwhile.
        current = self.gitlab.get(f"projects/{self.requests_project()['id']}/merge_requests/{mr['iid']}")
        if not current or current.get("state") != "opened":
            log(f"SKIP {kind} {target_id}: !{mr['iid']} was closed while it was being counted")
            return Outcome("refuse", 409, "删除申请已关闭，未执行删除", mr["web_url"])
        # Retire the request before deleting: close it and remove its branch. GitLab
        # refuses to reopen a merge request whose source branch is gone, so a retired
        # request can never count its old approvals again. If either step fails,
        # nothing has been deleted.
        self.close(mr)
        try:
            self.remove_branch(mr["source_branch"])
        except GitLabError:
            self.report(mr, f"未执行删除：清理申请分支失败。申请已关闭；如仍需删除{noun} `{path}`，请重新发起。")
            raise
        try:
            status, payload = self.gitlab.call("DELETE", f"{kind}s/{target_id}")
        except GitLabError as error:
            # The request went out but no answer came back: GitLab may have accepted it.
            log(f"UNKNOWN {kind} {target_id} for !{mr['iid']}: {error}")
            unknown = (f"删除{noun} `{path}` 的结果待确认：请求已发出，但没有收到 GitLab 的答复。"
                       f"请查看该{noun}是否已进入回收站；没有的话请重新发起。")
            self.report(mr, unknown + "申请已关闭。")
            return Outcome("refuse", 504, unknown + f"申请已关闭：{mr['web_url']}", mr["web_url"])
        if status not in (200, 202, 204):
            message = payload.get("message") if isinstance(payload, dict) else None
            reason = f"GitLab 返回 {status}" + (f"（{message}）" if message else "")
            self.report(mr, f"删除{noun} `{path}` 失败：{reason}。申请已关闭；处理后如仍需删除，请重新发起。")
            log(f"FAILED {kind} {target_id} for !{mr['iid']}: {status}")
            return Outcome("refuse", 502, f"删除没有执行：{reason}。申请已关闭：{mr['web_url']}", mr["web_url"])
        log(f"EXECUTED {kind} {target_id} {printable(path)} for !{mr['iid']} approved by "
            + ",".join(str(admin["id"]) for admin in admins))
        names = "、".join(f"@{admin['username']}" for admin in admins)
        self.report(mr, f"已删除{noun} `{path}`，同意的管理员：{names}。"
                        f"{noun}已进入回收站，保留期内管理员可以在回收站恢复。")
        return Outcome("executed", 202, "202 Accepted", mr["web_url"])

    def note(self, mr, body):
        project = self.requests_project()
        self.gitlab.write("POST", f"projects/{project['id']}/merge_requests/{mr['iid']}/notes", {"body": body})

    def report(self, mr, body):
        """A note after the outcome is settled; failing to write it changes nothing."""
        try:
            self.note(mr, body)
        except GitLabError as error:
            log(f"could not note the outcome on !{mr['iid']}: {error}")

    def close(self, mr):
        project = self.requests_project()
        self.gitlab.write("PUT", f"projects/{project['id']}/merge_requests/{mr['iid']}", {"state_event": "close"})

    def finish(self, mr, body):
        self.note(mr, body)
        self.close(mr)
        self.delete_branch(mr["source_branch"])

    def remove_branch(self, branch):
        project = self.requests_project()
        status, _ = self.gitlab.call("DELETE", f"projects/{project['id']}/repository/branches/" + urllib.parse.quote(branch, safe=""))
        if status not in (204, 404):
            raise GitLabError(f"removing the request branch returned {status}")

    def delete_branch(self, branch):
        """Best-effort cleanup for requests that were not executed."""
        try:
            self.remove_branch(branch)
        except GitLabError as error:
            log(f"could not delete branch {printable(branch)}: {error}")

    # Entry points ----------------------------------------------------------
    def handle_deletion(self, candidates, credentials):
        user = self.identify(credentials)
        if user is None:
            return Outcome("refuse", 401, "无法确认你的身份或权限，删除没有执行。请在网页上登录后操作，"
                           "或使用有 api 权限的令牌。")
        found = self.resolve(candidates)
        # Checked after the lookup, not before: an unresolved target only proves that
        # nothing is there if the token still had administrator access afterwards.
        self.ensure_admin_access()
        if found is None:
            return Outcome("forward")  # Not a project or group: some other DELETE route.
        kind, target = found
        noun, path = NOUNS[kind], full_path(kind, target)
        if not self.can_delete(kind, target, user):
            log(f"REFUSE {kind} {target['id']} for user {user['id']}: not an Owner or administrator")
            return Outcome("refuse", 404, "404 Not Found")
        if scheduled(target):
            return Outcome("refuse", 403, f"{noun} {path} 已在回收站，到保留期满时自动删除，不能提前删除；"
                           "需要恢复时请管理员在回收站操作。")
        with self.lock:
            mr = self.open_request(kind, target["id"]) or self.create_request(kind, target, user)
            return self.settle(mr)

    def handle_hook(self, iid):
        if not self.config.required_admins:
            return  # 0 turns the feature off: open requests are left as they are.
        with self.lock:
            mr = self.gitlab.get(f"projects/{self.requests_project()['id']}/merge_requests/{iid}")
            if not mr or not self.ours(mr):
                return
            if mr.get("state") == "opened":
                self.settle(mr)  # Any event re-counts, so a missed Approve is caught by the next one.
            elif mr.get("state") in ("closed", "merged"):
                self.delete_branch(mr["source_branch"])


def full_path(kind, target):
    return target.get("path_with_namespace" if kind == "project" else "full_path") or str(target.get("id"))


def scheduled(target):
    return bool(target.get("marked_for_deletion_on") or target.get("marked_for_deletion_at"))


PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
body{{margin:0;background:#f7f7f8;color:#28282f;font:15px/1.75 -apple-system,"PingFang SC","Microsoft YaHei",sans-serif}}
main{{max-width:640px;margin:10vh auto;padding:28px 32px;background:#fff;border:1px solid #e3e3e8;border-radius:8px}}
h1{{margin:0 0 12px;font-size:20px}}
p{{margin:12px 0;word-break:break-word}}
</style>
</head>
<body>
<main>
<h1>{title}</h1>
<p>{message}</p>
</main>
</body>
</html>
"""
PAGE_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
}


class Responder(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "deletion-control"
    sys_version = ""

    def log_message(self, format, *args):
        """Forwarded traffic is not logged; decisions are logged explicitly."""

    def _refuse(self, status, method, reason):
        log(f"REJECT {status} {method} {printable(request_path(self.path))} from {printable(self.headers.get('X-Real-IP'), 64)}: {reason}")
        return self._respond(status, "text/plain; charset=utf-8", f"{reason}\n".encode("utf-8"))

    def _respond(self, status, content_type, body, extra=None):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in (extra or {}).items():
            self.send_header(name, value)
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _length(self, method):
        if self.headers.get_all("Transfer-Encoding"):
            self._refuse(400, method, "request bodies must arrive with Content-Length (enable proxy_request_buffering)")
            return None
        lengths = set(self.headers.get_all("Content-Length") or [])
        if len(lengths) > 1 or not all(re.fullmatch(r"[0-9]{1,15}", value.strip()) for value in lengths):
            self._refuse(400, method, "invalid Content-Length")
            return None
        return int(lengths.pop()) if lengths else 0


class Handler(Responder):
    """Requests from GitLab's bundled Nginx."""

    def do_GET(self):
        if self.path == "/healthz":
            return self._respond(200, "text/plain; charset=utf-8", b"ok\n")
        return self._handle()

    def _handle(self):
        method = self.command.upper()
        length = self._length(method)
        if length is None:
            return
        if method == "POST" and request_path(self.path) == CHECK_PATH:
            return self._respond(200, "text/plain; charset=utf-8", b"deletion-control: requests reach this service\n")
        if not self.server.control.config.required_admins:
            return self._forward(method, length)
        imports = method == "POST" and import_endpoint(self.path)
        candidates = deletion_candidates(self.path)
        if not candidates and not imports:
            return self._forward(method, length)
        if method == "DELETE" or override_header_deletes(self.headers):
            return self._deletion(method, length, candidates)
        if method != "POST":
            return self._forward(method, length)  # Rack only applies _method to POST.
        if length <= MAX_INSPECTED_BODY:
            body = self.rfile.read(length) if length else b""
            if len(body) != length:
                return self._refuse(400, method, "incomplete request body")
            if requests_delete(method, self.headers, body):
                return self._deletion(method, length, candidates, body)
            if imports and import_overwrites(self.path, self.headers, body):
                return self._refuse_import(method)
            return self._forward(method, length, body)
        if imports and import_overwrites(self.path, self.headers, b""):
            return self._refuse_import(method)
        media = media_types(self.headers)
        multipart = any(item.startswith("multipart/") for item in media)
        if media & {"", "application/x-www-form-urlencoded"} or (imports and not multipart):
            return self._refuse(413, method, "form body too large to inspect")
        if not multipart:
            return self._forward(method, length)  # Rack does not read _method from other types.
        # Large uploads (such as attachments or import archives) are streamed. Their part
        # headers are checked on the way; if one names a watched field, the rest is never sent.
        boundaries = set().union(*(multipart_boundaries(value) for value in content_types(self.headers)))
        if not boundaries:
            return self._refuse(413, method, "large multipart body without a boundary cannot be inspected")
        return self._forward(method, length, boundaries=boundaries, fields=("_method", "overwrite") if imports else ("_method",))

    do_POST = do_DELETE = do_PUT = do_PATCH = do_HEAD = do_OPTIONS = _handle

    def _refuse_import(self, method):
        log(f"REFUSE 403 {method} {printable(request_path(self.path))}: import would overwrite a project")
        message = "启用删除管控时，导入不能覆盖已有工程（覆盖会删除原工程）。请导入到新路径，或先为原工程走删除申请。"
        return self._respond(403, "application/json", json.dumps({"message": message}, ensure_ascii=False).encode("utf-8"))

    def _deletion(self, method, length, candidates, body=None):
        if body is None:
            if length > MAX_INSPECTED_BODY:
                return self._refuse(413, method, "deletion request body too large")
            body = self.rfile.read(length) if length else b""
            if len(body) != length:
                return self._refuse(400, method, "incomplete request body")
        if not candidates:
            return self._forward(method, length, body)  # An import endpoint used with DELETE: not a project.
        try:
            outcome = self.server.control.handle_deletion(candidates, Credentials(self, body))
        except GitLabError as error:
            log(f"ERROR {method} {printable(request_path(self.path))}: {error}")
            outcome = Outcome("refuse", 503, f"删除申请暂时无法创建，删除没有执行。请联系管理员检查 deletion-control：{error}")
        if outcome.kind == "forward":
            return self._forward(method, length, body)
        if outcome.kind == "refuse" and outcome.status != 404:
            log(f"REFUSE {outcome.status} {method} {printable(request_path(self.path))}")
        if self._wants_json():
            return self._respond(outcome.status, "application/json",
                                 json.dumps({"message": outcome.message}, ensure_ascii=False).encode("utf-8"))
        if outcome.url and outcome.kind in ("pending", "executed"):
            # The browser lands on the merge request, which explains what happens next.
            return self._respond(303, "text/plain; charset=utf-8", b"", {"Location": outcome.url})
        titles = {401: "无法确认身份", 404: "找不到", 503: "暂时无法处理", 504: "删除结果待确认"}
        page = PAGE.format(title=titles.get(outcome.status, "无法删除"), message=html.escape(outcome.message))
        return self._respond(outcome.status, "text/html; charset=utf-8", page.encode("utf-8"), PAGE_HEADERS)

    def _wants_json(self):
        if request_path(self.path).lower().startswith("/api/"):
            return True
        return "text/html" not in (self.headers.get("Accept") or "")

    def _forward_headers(self):
        listed = {token.strip().lower() for value in self.headers.get_all("Connection") or [] for token in value.split(",")}
        return [(name, value) for name, value in self.headers.items()
                if name.lower() not in HOP_BY_HOP and name.lower() not in listed and name.lower() != KEY_HEADER.lower()]

    def _forward(self, method, length, body=None, boundaries=None, fields=("_method",)):
        gitlab = self.server.control.gitlab
        try:
            key = gitlab.key()
        except GitLabError as error:
            log(f"ERROR forwarding {method} {printable(request_path(self.path))}: {error}")
            return self._respond(502, "text/plain; charset=utf-8", b"deletion-control cannot reach GitLab\n")
        connection = http.client.HTTPConnection(gitlab.host, gitlab.port, timeout=UPSTREAM_TIMEOUT)
        try:
            try:
                connection.putrequest(method, self.path, skip_host="Host" in self.headers, skip_accept_encoding=True)
                for name, value in self._forward_headers():
                    connection.putheader(name, value)
                connection.putheader(KEY_HEADER, key)
                connection.putheader("Connection", "close")
                connection.endheaders()
                if body is not None:
                    connection.send(body)
                else:
                    remaining = length
                    watch = MultipartWatch(boundaries, fields) if boundaries else None
                    while remaining:
                        chunk = self.rfile.read(min(CHUNK, remaining))
                        if not chunk:
                            raise ConnectionError("client closed the connection before sending the body")
                        if watch and watch.suspicious(chunk):
                            connection.close()
                            return self._refuse(413, method, f"large multipart body has a {'/'.join(fields)} part; refused unsent")
                        connection.send(chunk)
                        remaining -= len(chunk)
                response = connection.getresponse()
            except (OSError, http.client.HTTPException) as error:
                log(f"upstream error for {method} {printable(request_path(self.path))}: {error}")
                return self._respond(502, "text/plain; charset=utf-8", b"GitLab upstream unavailable\n")
            listed = {token.strip().lower() for token in (response.getheader("Connection") or "").split(",")}
            self.send_response_only(response.status, response.reason)
            for name, value in response.getheaders():
                if name.lower() not in HOP_BY_HOP and name.lower() not in listed:
                    self.send_header(name, value)
            # One request per connection; a body without Content-Length ends at close.
            self.send_header("Connection", "close")
            self.end_headers()
            if method != "HEAD":
                while True:
                    chunk = response.read(CHUNK)
                    if not chunk:
                        break
                    self.wfile.write(chunk)
        finally:
            connection.close()


class HookHandler(Responder):
    """GitLab system hooks, on a port GitLab's Nginx never routes to."""

    def do_POST(self):
        length = self._length("POST")
        if length is None:
            return
        if length > MAX_HOOK_BODY:
            return self._refuse(413, "POST", "hook body too large")
        body = self.rfile.read(length) if length else b""
        try:
            payload = json.loads(body)
        except ValueError:
            return self._refuse(400, "POST", "hook body is not JSON")
        iid = self.server.interesting(payload)
        if iid is not None and not self.server.enqueue(iid):
            return self._refuse(503, "POST", "too many queued hook events")
        return self._respond(202, "text/plain; charset=utf-8", b"queued\n")

    def do_GET(self):
        return self._respond(200, "text/plain; charset=utf-8", b"ok\n") if self.path == "/healthz" else self._respond(404, "text/plain", b"")


class HookQueue:
    """Bounded queue of MR iids; an iid already waiting is not queued twice,
    since one settle counts all approvals."""

    def __init__(self, control):
        self.control = control
        self.queue = queue.Queue(MAX_QUEUED_HOOKS)
        self.waiting = set()
        self.guard = threading.Lock()
        threading.Thread(target=self.work, daemon=True).start()

    def interesting(self, payload):
        if not isinstance(payload, dict) or payload.get("object_kind") != "merge_request":
            return None
        iid = (payload.get("object_attributes") or {}).get("iid")
        project_id = (payload.get("project") or {}).get("id")
        if not isinstance(iid, int) or not isinstance(project_id, int):
            return None
        try:
            if project_id != self.control.requests_project()["id"]:
                return None
        except GitLabError as error:
            log(f"ERROR handling a system hook: {error}")
            return None
        return iid

    def enqueue(self, iid):
        with self.guard:
            if iid in self.waiting:
                return True
            try:
                self.queue.put_nowait(iid)
            except queue.Full:
                return False
            self.waiting.add(iid)
            return True

    def work(self):
        while True:
            iid = self.queue.get()
            with self.guard:
                self.waiting.discard(iid)
            try:
                self.control.handle_hook(iid)
            except GitLabError as error:
                log(f"ERROR handling a system hook: {error}")
            except Exception as error:  # Keep the worker alive; the next event re-counts.
                log(f"ERROR handling a system hook: {type(error).__name__}: {error}")
            finally:
                self.queue.task_done()

    def join(self):
        self.queue.join()


def make_servers(control, host="0.0.0.0", port=LISTEN_PORT, hook_port=HOOK_PORT):
    server = ThreadingHTTPServer((host, port), Handler)
    server.daemon_threads = True
    server.control = control
    hooks = ThreadingHTTPServer((host, hook_port), HookHandler)
    hooks.daemon_threads = True
    hooks.queue = HookQueue(control)
    hooks.interesting = hooks.queue.interesting
    hooks.enqueue = hooks.queue.enqueue
    return server, hooks


def main():
    try:
        config = load_config(os.environ)
    except ConfigError as error:
        log(f"configuration error: {error}")
        return 2
    # PID 1 in a container ignores SIGTERM unless a handler is installed.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    server, hooks = make_servers(Control(config, GitLab(config.upstream, config.token_file, config.key_file)))
    threading.Thread(target=hooks.serve_forever, daemon=True).start()
    if config.required_admins:
        log(f"listening on :{LISTEN_PORT} (hooks on :{HOOK_PORT}); required admins: {config.required_admins}; "
            f"requests project: {config.requests_project}")
    else:
        log(f"listening on :{LISTEN_PORT}; DELETION_REQUIRED_ADMINS is 0, everything is forwarded")
    try:
        server.serve_forever()
    finally:
        server.server_close()
        hooks.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
