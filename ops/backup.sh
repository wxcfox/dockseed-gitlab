#!/usr/bin/env bash
# Generate one complete local backup; usage and recovery: docs/recovery.md.
set -euo pipefail
umask 077
export LC_ALL=C
# fd 3 sends progress/errors to the terminal; fd 4 only emits the final directory.
exec 3>&2 4>&1

fail() { printf 'backup: %s\n' "$*" >&3; exit 1; }
log() { printf '%s backup: %s\n' "$(date -u +%FT%TZ)" "$*" >&3; }

# 1. Parameters and dependencies
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
for tool in docker git tar gzip; do
    command -v "$tool" >/dev/null 2>&1 || fail "missing dependency: $tool"
done
if command -v sha256sum >/dev/null 2>&1; then
    sha=(sha256sum)
else
    command -v shasum >/dev/null 2>&1 || fail 'sha256sum or shasum is required'
    sha=(shasum -a 256)
fi
if [[ -z ${BACKUP_WORK_DIR:-} || -z ${BACKUP_ESTIMATE_KB:-} ]]; then
    # Keep $HOME literal in the copyable command example.
    # shellcheck disable=SC2016
    fail 'set both parameters on the same command line, for example: BACKUP_WORK_DIR="$HOME/gitlab-backup-work" BACKUP_ESTIMATE_KB=20971520 bash ops/backup.sh (20 GiB budget; see docs/recovery.md)'
fi
[[ $BACKUP_ESTIMATE_KB =~ ^[1-9][0-9]{0,11}$ ]] || fail 'BACKUP_ESTIMATE_KB must be positive decimal KiB (at most 12 digits)'
[[ $BACKUP_WORK_DIR = /* && -d $BACKUP_WORK_DIR && ! -L $BACKUP_WORK_DIR ]] || fail 'BACKUP_WORK_DIR must be an existing absolute directory, not a symlink'
[[ -s $repo/.env && -s $repo/docker-compose.yml ]] || fail 'actual .env and docker-compose.yml are required'
compose=(docker compose --project-directory "$repo" --env-file "$repo/.env" -f "$repo/docker-compose.yml")
"${compose[@]}" version >/dev/null
work=$(cd "$BACKUP_WORK_DIR" && pwd -P)
[[ -w $work ]] || fail 'BACKUP_WORK_DIR must be writable by the current user'

# 2. Preflight (no lock acquired)
container_backups=/var/opt/gitlab/backups
headroom_kb=1048576 # 1 GiB
cid=$("${compose[@]}" ps -q gitlab)
[[ $cid =~ ^[a-f0-9]+$ ]] || fail 'expected exactly one running Compose gitlab container'
[[ $(docker inspect --format '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid") = 'true healthy' ]] || fail 'GitLab must be running and healthy'
check_free() {
    local available=$1 required=$2 label=$3
    [[ $available =~ ^[0-9]+$ ]] || fail "cannot read free space: $label"
    ((available >= required)) || fail "insufficient space at $label: $(awk -v need="$required" -v free="$available" 'BEGIN {printf "need %.1f GiB, available %.1f GiB", need/1048576, free/1048576}')"
}
# Allow for GitLab staging, archives and a host copy, plus headroom.
available=$(df -Pk "$work" | awk 'END {print $4}')
check_free "$available" "$((4 * BACKUP_ESTIMATE_KB + headroom_kb))" 'host work directory'
available=$(docker exec "$cid" df -Pk "$container_backups" | awk 'END {print $4}')
check_free "$available" "$((4 * BACKUP_ESTIMATE_KB + headroom_kb))" "container $container_backups"

# The data-volume lock covers all checkouts. Check it now to avoid extra diagnostic
# directories, then acquire it atomically with mkdir after preflight. Failures retain
# it for manual inspection: a disconnected docker exec may still be backing up.
# Successful cleanup releases it with rmdir before publishing LOCAL_COMPLETE.
lock=$container_backups/.dockseed-backup.lock
docker exec "$cid" test ! -e "$lock" || fail "backup already running or previous failure retained; inspect $lock (docs/recovery.md)"
run_id=dockseed-$(date -u +%Y%m%dT%H%M%SZ)-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
run=$work/$run_id
mkdir -m 700 "$run"
log_file=$run/operations.log
: > "$log_file"
# Raw tool output stays private; only the final directory goes to stdout.
exec >>"$log_file" 2>&1
on_exit() {
    local rc=$?
    trap - EXIT
    if [[ $rc != 0 ]]; then
        printf 'backup: FAILED (exit %s); retained %s; see private log and docs/recovery.md.\n' "$rc" "$run" >&3
    fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
log "preflight $run_id; private details: $log_file"

# Start Rails once: validate backup path/retention and report Registry enablement.
# Keep this Ruby backup path identical to container_backups above.
registry_enabled=$(docker exec "$cid" gitlab-rails runner \
    'abort "backup_path must be /var/opt/gitlab/backups" unless Gitlab.config.backup.path.to_s == "/var/opt/gitlab/backups"
     abort "backup keep_time must be zero" unless Gitlab.config.backup.keep_time.to_i == 0
     puts Gitlab.config.registry.enabled')
[[ $registry_enabled = true || $registry_enabled = false ]] || fail 'cannot determine whether Registry is enabled'
docker exec "$cid" test -s /etc/gitlab/gitlab-secrets.json
docker exec "$cid" test -s /etc/gitlab/gitlab.rb
# Read only two booleans using GitLab's bundled Ruby; never print registry credentials.
# The marker also protects retained metadata when Registry has been disabled.
registry_state=$(docker exec "$cid" /opt/gitlab/embedded/bin/ruby -ryaml -e '
    # registry-probe:begin
    path = "/var/opt/gitlab/registry/config.yml"
    config = File.file?(path) ? YAML.load_file(path) : {}
    # GitLab 19.3 Omnibus defaults to "prefer"; it is not a boolean.
    database = ["prefer", "true", true].include?(config.dig("database", "enabled")) ||
        File.exist?("/var/opt/gitlab/gitlab-rails/shared/registry/docker/registry/lockfiles/database-in-use")
    puts "#{File.file?(path) || database} #{database}"
    # registry-probe:end
')
case "$registry_state" in
    'true true'|'true false'|'false false') ;;
    *) fail 'cannot determine Registry files and metadata database usage' ;;
esac
read -r registry_leftovers registry_database <<< "$registry_state"
if [[ $registry_enabled = false && $registry_leftovers = true ]]; then
    fail 'Registry is disabled but retained configuration/data exists; re-enable Registry before backing up its data (see README: 关闭 Registry)'
fi
if [[ $registry_database = true ]]; then
    for credential in env-connection env-backup_user env-restore_user; do
        docker exec "$cid" test -s "/opt/gitlab/etc/gitlab-backup/env/$credential" ||
            fail 'Registry metadata database requires backup/restore roles; see docs/recovery.md#registry-元数据库'
    done
fi
# dpkg may also list the other edition as not-installed, with an empty version.
package=$(docker exec "$cid" dpkg-query --show '--showformat=${Package} ${Version} ${db:Status-Status}\n' 'gitlab-?e' |
    awk '$3 == "installed" {print $1, $2}')
[[ $package =~ ^gitlab-(ce|ee)[[:space:]]([0-9]+\.[0-9]+\.[0-9]+-(ce|ee)\.[0-9]+)$ ]] || fail 'expected exactly one installed CE/EE package with a supported exact version'
edition=${BASH_REMATCH[1]}
package_version=${BASH_REMATCH[2]}
[[ $edition = "${BASH_REMATCH[3]}" ]] || fail 'GitLab package edition mismatch'
version=${package_version%%-*}
if [[ $edition = ee ]]; then version=$version-ee; fi
image_id=$(docker inspect --format '{{.Image}}' "$cid")
[[ $image_id =~ ^sha256:[a-f0-9]{64}$ ]] || fail 'missing image ID'
image_ref=$(docker inspect --format '{{.Config.Image}}' "$cid")
[[ -n $image_ref && $image_ref != *$'\n'* ]] || fail 'missing image reference'
platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}{{if .Variant}}/{{.Variant}}{{end}}' "$image_id")
[[ $platform =~ ^linux/(amd64|arm64)(/v[0-9]+)?$ ]] || fail 'missing or unsupported image platform'
docker exec "$cid" printenv GITLAB_OMNIBUS_CONFIG > "$run/runtime-omnibus.rb"
[[ -s $run/runtime-omnibus.rb ]] || fail 'missing injected GITLAB_OMNIBUS_CONFIG'
commit=$(git -C "$repo" rev-parse --verify HEAD)
# Explicit file list: never archive the checkout, .git or unrelated credentials.
deployment=(docker-compose.yml .env README.md ops/backup.sh ops/transfer.sh docs/recovery.md)
for file in "${deployment[@]}"; do
    [[ -s $repo/$file && ! -L $repo/$file ]] || fail "missing deployment material (or symlink): $file"
done
tar -cf "$run/deployment.tar" -C "$repo" "${deployment[@]}" -C "$run" runtime-omnibus.rb

# 3. Acquire the lock and create backups
docker exec "$cid" mkdir -m 700 "$lock" >/dev/null 2>&1 || fail "backup already running, previous failure retained, or backup directory unavailable; inspect $lock (docs/recovery.md)"
log "started $run_id"
app_file=${run_id}_gitlab_backup.tar
container_config=$container_backups/$run_id-config
docker exec "$cid" test ! -e "$container_backups/$app_file"
docker exec "$cid" mkdir -m 700 "$container_config"
log 'creating official GitLab application backup'
# Clear incremental, partial-repository, compression and copy-strategy overrides
# so GitLab produces a complete backup in its default format.
docker exec "$cid" env -u INCREMENTAL -u PREVIOUS_BACKUP -u REPOSITORIES_SERVER_SIDE \
    -u REPOSITORIES_PATHS -u REPOSITORIES_STORAGES -u SKIP_REPOSITORIES_PATHS \
    -u COMPRESS_CMD -u DECOMPRESS_CMD -u STRATEGY -u GZIP_RSYNCABLE \
    gitlab-backup create "BACKUP=$run_id" SKIP=remote
docker exec "$cid" test -s "$container_backups/$app_file"
log 'saving configuration and Secrets'
docker exec "$cid" gitlab-ctl backup-etc --no-delete-old-backups --backup-path "$container_config"
# A fresh task-specific directory must contain exactly one nonempty official config archive.
config_file=$(docker exec "$cid" sh -c '
    set -- "$1"/gitlab_config_*.tar
    [ "$#" -eq 1 ] && [ -s "$1" ] || exit 1
    printf "%s\n" "${1##*/}"
' sh "$container_config")
[[ $config_file =~ ^gitlab_config_[0-9_]+\.tar$ ]] || fail 'cannot identify this task configuration archive'

# 4. Copy and validate archives
# Use actual archive sizes for the copy; an estimate is not a hard size limit.
app_kb=$(docker exec "$cid" du -k "$container_backups/$app_file" | awk '{print $1}')
config_kb=$(docker exec "$cid" du -k "$container_config/$config_file" | awk '{print $1}')
[[ $app_kb =~ ^[0-9]+$ && $config_kb =~ ^[0-9]+$ ]] || fail 'cannot measure backup files'
((app_kb + config_kb <= BACKUP_ESTIMATE_KB)) || log 'WARNING: archives exceeded BACKUP_ESTIMATE_KB; checking actual space; increase the budget for future backups'
available=$(df -Pk "$work" | awk 'END {print $4}')
check_free "$available" "$((app_kb + config_kb + headroom_kb))" 'host before copy'
docker cp "$cid:$container_backups/$app_file" "$run/$app_file"
docker cp "$cid:$container_config/$config_file" "$run/config.tar"
chmod 600 "$run/$app_file" "$run/config.tar"
tar -tf "$run/config.tar" > "$run/config-members.txt"
for required in gitlab.rb gitlab-secrets.json; do
    member=$(grep -Fx -e "etc/gitlab/$required" -e "./etc/gitlab/$required" -e "/etc/gitlab/$required" \
        "$run/config-members.txt") || fail "configuration archive missing $required"
    [[ -n $member && $member != *$'\n'* ]] || fail "configuration archive missing $required"
    # Check archive payload, not just the live source or the member name.
    archived_bytes=$(tar -xOf "$run/config.tar" "$member" | wc -c | tr -d ' ') || fail "cannot extract archived $required"
    [[ $archived_bytes -gt 0 ]] || fail "empty archived $required"
done
tar -tf "$run/$app_file" > "$run/application-members.txt"
databases=(database)
if [[ $registry_database = true ]]; then
    databases+=(registry_database)
fi
if [[ $registry_enabled = true ]]; then
    grep -Eq '^(\./)?registry\.tar\.gz$' "$run/application-members.txt" || fail 'application archive missing Registry files; keep Registry enabled when backing up its data'
fi
for database in "${databases[@]}"; do
    member=$(grep -Fx -e "db/$database.sql.gz" -e "./db/$database.sql.gz" "$run/application-members.txt") ||
        fail "application archive missing $database dump"
    [[ $member != *$'\n'* ]] || fail "ambiguous $database dump"
    archived_bytes=$(tar -xOf "$run/$app_file" "$member" | gzip -dc | wc -c | tr -d ' ') || fail "cannot read $database dump"
    [[ $archived_bytes -gt 0 ]] || fail "empty $database dump"
done
metadata_member=$(grep -Ex '(\./)?backup_information.yml' "$run/application-members.txt") || fail 'application archive missing backup metadata'
tar -xOf "$run/$app_file" "$metadata_member" > "$run/backup_information.yml"
grep -Eq '^:?(backup_created_at|backup_id):' "$run/backup_information.yml" || fail 'missing backup identity/time metadata'
grep -Eq "^:?gitlab_version: ['\"]?${version//./[.]}['\"]?$" "$run/backup_information.yml" || fail 'application archive version mismatch'
# Only remote upload may be skipped.
grep -Eq "^:?skipped: ['\"]?remote['\"]?$" "$run/backup_information.yml" || fail 'unexpected skipped backup components'
verify_copy() {
    local source=$1 target=$2 source_hash host_hash
    source_hash=$(docker exec "$cid" sha256sum "$source" | awk '{print $1}')
    host_hash=$("${sha[@]}" "$target" | awk '{print $1}')
    [[ $source_hash = "$host_hash" ]] || fail "container-to-host checksum mismatch: ${target##*/}"
}
verify_copy "$container_backups/$app_file" "$run/$app_file"
verify_copy "$container_config/$config_file" "$run/config.tar"

# 5. Prepare completion metadata, clean up and publish
cat > "$run/manifest.txt" <<MANIFEST
format=1
backup_id=$run_id
application_file=$app_file
configuration_file=config.tar
configuration_original_file=$config_file
created_at_utc=$(date -u +%FT%TZ)
gitlab_version=$version
gitlab_edition=$edition
gitlab_package_version=$package_version
image_reference=$image_ref
image_id=$image_id
image_platform=$platform
project_commit=$commit
registry_database=$registry_database
restore_tested=no
MANIFEST
files=("$app_file" config.tar deployment.tar manifest.txt)
for file in "${files[@]}"; do [[ -s $run/$file ]] || fail "required file missing: $file"; done
(cd "$run" && "${sha[@]}" "${files[@]}" > SHA256SUMS)
checksums_sha256=$("${sha[@]}" "$run/SHA256SUMS" | awk '{print $1}') || fail 'cannot hash SHA256SUMS for LOCAL_COMPLETE'
[[ $checksums_sha256 =~ ^[a-f0-9]{64}$ ]] || fail 'invalid SHA256SUMS hash for LOCAL_COMPLETE'
printf 'backup_id=%s\ncompleted_at_utc=%s\nchecksums_sha256=%s\nrestore_tested=no\n' \
    "$run_id" "$(date -u +%FT%TZ)" "$checksums_sha256" > "$run/.LOCAL_COMPLETE.tmp"
# Preserve the local payload. Only this run's container artifacts and sidecars go.
docker exec "$cid" rm -- "$container_backups/$app_file" "$container_config/$config_file"
docker exec "$cid" rmdir "$container_config"
for file in config-members.txt application-members.txt backup_information.yml runtime-omnibus.rb; do rm -- "$run/$file"; done
docker exec "$cid" rmdir "$lock"
# Publish only after cleanup and unlocking; incomplete directories cannot be uploaded.
mv -- "$run/.LOCAL_COMPLETE.tmp" "$run/LOCAL_COMPLETE"
log "success; local backup ready (restore drill still required): $run; elapsed ${SECONDS}s"
printf '%s\n' "$run" >&4
