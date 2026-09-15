#!/usr/bin/env bash
# Offline local-generation fixtures only: Docker and Git use rejecting PATH mocks.
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/dockseed-backup-test.XXXXXX")
fixture=$(cd "$fixture" && pwd -P)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/project/ops" "$fixture/project/docs"
cp "$repo/ops/backup.sh" "$fixture/project/ops/"
for file in docker-compose.yml README.md ops/transfer.sh docs/recovery.md; do
    printf 'offline deployment fixture\n' > "$fixture/project/$file"
done
# Literal shell syntax creates a sentinel if deployment .env is accidentally sourced.
# shellcheck disable=SC2016
printf 'GITLAB_ROOT_PASSWORD=fixture-password-do-not-print\nUNSAFE=$(touch "%s/env-was-sourced")\n' "$fixture" > "$fixture/project/.env"
export MOCK_REAL_TAR MOCK_REAL_SHA MOCK_REAL_MV MOCK_REAL_MKDIR
MOCK_REAL_TAR=$(command -v tar)
MOCK_REAL_MV=$(command -v mv)
MOCK_REAL_MKDIR=$(command -v mkdir)
if command -v sha256sum >/dev/null 2>&1; then sha=(sha256sum); else sha=(shasum -a 256); fi
MOCK_REAL_SHA=$(command -v "${sha[0]}")
export PATH="$fixture/bin:/usr/bin:/bin"
unset OSS_DESTINATION OSS_ENDPOINT
if command -v ossutil >/dev/null 2>&1; then
    printf 'FAIL: isolated test PATH unexpectedly contains ossutil\n' >&2; exit 1
fi

cat > "$fixture/bin/mock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
bad() { printf 'unexpected mock command: %s\n' "$*" >&2; exit 99; }
case "${0##*/}" in
    mkdir)
        if [[ ${!#} = "$MOCK_STATE/work/"dockseed-* ]]; then
            [[ $MOCK_CASE != work-create-failure ]] || exit 32
            "$MOCK_REAL_MKDIR" "$@"
            if [[ $MOCK_CASE = log-create-failure ]]; then
                "$MOCK_REAL_MKDIR" "${!#}/operations.log"
            fi
            exit 0
        fi
        exec "$MOCK_REAL_MKDIR" "$@" ;;
    sha256sum|shasum)
        if [[ $MOCK_CASE = checksum-generation-failure && ${!#} = manifest.txt ]]; then
            "$MOCK_REAL_SHA" "$@"; exit 30
        fi
        if [[ $MOCK_CASE = final-checksum-failure && ${!#} = "$MOCK_STATE/work/"*/SHA256SUMS ]]; then
            printf '%064d  %s\n' 0 "${!#}"; exit 26
        fi
        exec "$MOCK_REAL_SHA" "$@" ;;
    tar)
        [[ $MOCK_CASE != deployment-archive-failure || $2 != */deployment.tar ]] || exit 33
        if [[ $MOCK_CASE = partial-extraction && $1 = -xOf && $2 = */config.tar && $3 = */gitlab-secrets.json ]]; then
            printf '{"partial":'; exit 22
        fi
        exec "$MOCK_REAL_TAR" "$@" ;;
    mv)
        printf 'mv %s\n' "$*" >> "$MOCK_STATE/commands"
        [[ $MOCK_CASE != publish-failure ]] || exit 29
        exec "$MOCK_REAL_MV" "$@" ;;
    git)
        [[ $* = *'rev-parse --verify HEAD' ]] || bad "$@"
        [[ $MOCK_CASE != git-failure ]] || { printf 'fixture: repository ownership check failed\n' >&2; exit 128; }
        printf '0123456789012345678901234567890123456789\n'; exit 0 ;;
    df)
        free=100000000
        if [[ $MOCK_CASE = low-space ]]; then free=1; fi
        if [[ $MOCK_CASE = low-copy-space && -d $MOCK_STATE/app && ${!#} = "$MOCK_STATE/work" ]]; then free=1; fi
        case "$MOCK_CASE" in
            separate-filesystems|low-work-space|low-backup-space)
                # 200 GiB data/work disks; /tmp resides on a 40 GiB system disk.
                free=209715200
                if [[ ${!#} = /tmp ||
                    ( $MOCK_CASE = low-work-space && ${!#} = "$MOCK_STATE/work" ) ||
                    ( $MOCK_CASE = low-backup-space && ${!#} = /var/opt/gitlab/backups ) ]]; then
                    free=41943040
                fi ;;
        esac
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nmock %s 1 %s 1%% /mock\n' "$((free + 1))" "$free"
        if [[ $MOCK_CASE = df-failure ]]; then exit 27; fi
        exit 0 ;;
    docker) printf 'docker %s\n' "$*" >> "$MOCK_STATE/commands" ;;
    *) bad "$@" ;;
esac
case "$1" in
    compose)
        case "${*: -1}" in version) exit 0 ;; gitlab) printf 'abcdef012345\n'; exit 0 ;; *) bad "$@" ;; esac ;;
    inspect)
        case "$3" in
            *State.Running*) if [[ $MOCK_CASE = unhealthy ]]; then printf 'true unhealthy\n'; else printf 'true healthy\n'; fi ;;
            '{{.Image}}') printf 'sha256:%064d\n' 0 ;;
            '{{.Config.Image}}') printf 'gitlab/gitlab-ce:18.8.2-ce.0\n' ;;
            *) bad "$@" ;;
        esac
        exit 0 ;;
    image) [[ $4 = *Architecture* ]] || bad "$@"; printf 'linux/amd64\n'; exit 0 ;;
    cp) cp "$MOCK_STATE/container/${2#*:}" "$3"; exit 0 ;;
    exec) [[ $2 = abcdef012345 ]] || bad "$@"; shift 2 ;;
    *) bad "$@" ;;
esac
if [[ $1 = env ]]; then
    shift
    while [[ $1 = -u ]]; do shift 2; done
fi
case "$1" in
    df) exec df "${@:2}" ;;
    mkdir)
        [[ $2 = -m && $3 = 700 ]] || bad "$@"
        mkdir -m 700 "$MOCK_STATE/container/$4"
        if [[ $MOCK_CASE = lock-race && $4 = */.dockseed-backup.lock ]]; then
            printf 'another task\n' > "$MOCK_STATE/container/$4/owner"
            exit 1
        fi ;;
    rmdir)
        if [[ $MOCK_CASE = cleanup-lock-failure && $2 = */.dockseed-backup.lock ]]; then exit 25; fi
        rmdir "$MOCK_STATE/container/$2" ;;
    rm)
        [[ $2 = -- ]] || bad "$@"
        for file in "${@:3}"; do
            if [[ $MOCK_CASE = cleanup-failure && $file = */gitlab_config_*.tar ]]; then exit 24; fi
            rm -- "$MOCK_STATE/container/$file"
        done ;;
    test)
        case "$2" in -s) [[ -s $MOCK_STATE/container/$3 ]] ;; '!') [[ ! -e $MOCK_STATE/container/$4 ]] ;; *) bad "$@" ;; esac ;;
    printenv)
        [[ $MOCK_CASE != missing-runtime-config ]] || exit 0
        printf 'external_url "http://fixture.invalid"\ngitlab_rails["initial_root_password"] = "fixture-password-do-not-print"\n' ;;
    dpkg-query)
        [[ $3 = '--showformat=${Package} ${Version} ${db:Status-Status}\n' ]] || bad "$@"
        if [[ $MOCK_CASE != missing-version ]]; then printf 'gitlab-ce 18.8.2-ce.0 installed\n'; fi
        if [[ $MOCK_CASE = ambiguous-packages ]]; then
            printf 'gitlab-ee 18.8.2-ee.0 installed\n'
        else printf 'gitlab-ee  not-installed\n'; fi ;;
    gitlab-rails) [[ $MOCK_CASE != nonzero-keep-time ]] ;;
    du) du -k "$MOCK_STATE/container/$3" ;;
    sha256sum)
        if [[ $MOCK_CASE = copy-corruption ]]; then printf '%064d  file\n' 0
        elif [[ ${MOCK_REAL_SHA##*/} = shasum ]]; then "$MOCK_REAL_SHA" -a 256 "$MOCK_STATE/container/$2"
        else "$MOCK_REAL_SHA" "$MOCK_STATE/container/$2"; fi
        [[ $MOCK_CASE != source-checksum-failure ]] || exit 31 ;;
    sh)
        [[ $3 = *gitlab_config_* ]] || bad "$@"
        files=("$MOCK_STATE/container/${5}"/gitlab_config_*.tar)
        [[ ${#files[@]} = 1 && -s ${files[0]} ]]
        printf '%s\n' "${files[0]##*/}" ;;
    gitlab-backup)
        [[ $2 = create && $3 = BACKUP=dockseed-* && $4 = SKIP=remote ]] || bad "$@"
        printf 'fixture-password-do-not-print: private tool progress\n'
        [[ $MOCK_CASE != app-failure ]] || exit 17
        [[ $MOCK_CASE != missing-app ]] || exit 0
        if [[ $MOCK_CASE = concurrent ]]; then
            : > "$MOCK_STATE/app-entered"
            for ((waits=0; waits<200; waits++)); do
                [[ ! -e $MOCK_STATE/release-app ]] || break
                sleep 0.1
            done
            [[ -e $MOCK_STATE/release-app ]] || exit 98
        fi
        mkdir -p "$MOCK_STATE/app/db"
        printf 'fixture logical database dump\n' > "$MOCK_STATE/app/db/database.sql.gz"
        skip=remote version=18.8.2
        if [[ $MOCK_CASE = partial-backup ]]; then skip=remote,repositories; fi
        if [[ $MOCK_CASE = wrong-version ]]; then version=18x8y2; fi
        if [[ $MOCK_CASE != missing-metadata ]]; then
            printf -- '---\n:backup_created_at: 2026-09-14 00:00:00.000000000 Z\n:gitlab_version: %s\n:skipped: %s\n' "$version" "$skip" > "$MOCK_STATE/app/backup_information.yml"
        fi
        tar -cf "$MOCK_STATE/container/var/opt/gitlab/backups/${3#BACKUP=}_gitlab_backup.tar" -C "$MOCK_STATE/app" . ;;
    gitlab-ctl)
        [[ $2 = backup-etc && $3 = --no-delete-old-backups && $4 = --backup-path ]] || bad "$@"
        [[ $MOCK_CASE != config-failure ]] || exit 18
        mkdir -p "$MOCK_STATE/config/etc/gitlab"
        cp "$MOCK_STATE/container/etc/gitlab/gitlab.rb" "$MOCK_STATE/config/etc/gitlab/"
        if [[ $MOCK_CASE != missing-archived-secret ]]; then
            secret=gitlab-secrets.json
            if [[ $MOCK_CASE = wrong-secret-name ]]; then secret=gitlab-secretsXjson; fi
            cp "$MOCK_STATE/container/etc/gitlab/gitlab-secrets.json" "$MOCK_STATE/config/etc/gitlab/$secret"
        fi
        tar -cf "$MOCK_STATE/container/$5/gitlab_config_1757800000_2026_09_14.tar" -C "$MOCK_STATE/config" etc/gitlab ;;
    *) bad "$@" ;;
esac
MOCK
chmod +x "$fixture/bin/mock"
for tool in docker git df tar mv mkdir "${sha[0]}"; do ln -s mock "$fixture/bin/$tool"; done

setup() {
    export MOCK_CASE=$1 MOCK_STATE="$fixture/$1"
    export BACKUP_WORK_DIR="$MOCK_STATE/work" BACKUP_ESTIMATE_KB=100000
    if [[ $1 = archive-too-large ]]; then BACKUP_ESTIMATE_KB=1; fi
    case "$1" in
        separate-filesystems|low-work-space|low-backup-space) BACKUP_ESTIMATE_KB=20971520 ;;
    esac
    backups=$MOCK_STATE/container/var/opt/gitlab/backups
    lock=$backups/.dockseed-backup.lock
    mkdir -p "$BACKUP_WORK_DIR/historical" "$backups" "$MOCK_STATE/container/etc/gitlab"
    for file in "$BACKUP_WORK_DIR/historical/LOCAL_COMPLETE" "$backups/historical.tar"; do
        printf 'preserve historical backup\n' > "$file"
    done
    if [[ $1 != missing-rb ]]; then printf '# fixture\n' > "$MOCK_STATE/container/etc/gitlab/gitlab.rb"; fi
    if [[ $1 != missing-secret ]]; then printf '{}\n' > "$MOCK_STATE/container/etc/gitlab/gitlab-secrets.json"; fi
    : > "$MOCK_STATE/commands"
}
reject_matches() {
    if grep -Eq "$1" "$2"; then printf 'FAIL: unexpected %s in %s\n' "$1" "$2" >&2; exit 1; fi
}
preserved() {
    for file in "$MOCK_STATE/work/historical/LOCAL_COMPLETE" "$backups/historical.tar"; do
        grep -qx 'preserve historical backup' "$file"
    done
    [[ ! -e $fixture/env-was-sourced ]]
}
local_valid() {
    local payload checksum member
    payload=$(cat "$1")
    [[ $payload = "$BACKUP_WORK_DIR"/dockseed-* && $payload != *$'\n'* ]]
    [[ $(wc -l < "$1" | tr -d ' ') = 1 && ! -e $lock ]]
    (cd "$payload" && "${sha[@]}" -c SHA256SUMS) > "$MOCK_STATE/restore-checksums"
    [[ $(wc -l < "$payload/SHA256SUMS" | tr -d ' ') = 4 ]]
    checksum=$("${sha[@]}" "$payload/SHA256SUMS" | awk '{print $1}')
    grep -qx "checksums_sha256=$checksum" "$payload/LOCAL_COMPLETE"
    grep -qx "backup_id=${payload##*/}" "$payload/LOCAL_COMPLETE"
    tar -tf "$payload/deployment.tar" > "$MOCK_STATE/deployment-members"
    for member in .env README.md runtime-omnibus.rb ops/backup.sh ops/transfer.sh docs/recovery.md; do
        grep -qx "$member" "$MOCK_STATE/deployment-members"
    done
    [[ $(find "$payload" -type f | wc -l | tr -d ' ') = 7 && -s $payload/operations.log ]]
    [[ ! -e $backups/${payload##*/}_gitlab_backup.tar && ! -e $backups/${payload##*/}-config ]]
}
passed=0
run_case() {
    local scenario=$1 expected=${2:-fail} result=0
    setup "$scenario"
    bash "$fixture/project/ops/backup.sh" > "$MOCK_STATE/output" 2> "$MOCK_STATE/errors" || result=$?
    if { [[ $expected = pass && $result != 0 ]]; } || { [[ $expected = fail && $result = 0 ]]; }; then
        cat "$MOCK_STATE/output" "$MOCK_STATE/errors" >&2
        for file in "$BACKUP_WORK_DIR"/dockseed-*/operations.log; do [[ ! -f $file ]] || cat "$file" >&2; done
        printf 'FAIL: %s (exit %s)\n' "$scenario" "$result" >&2; exit 1
    fi
    preserved
    reject_matches 'fixture-password-do-not-print' "$MOCK_STATE/output"
    reject_matches 'fixture-password-do-not-print' "$MOCK_STATE/errors"
    if [[ $expected = pass ]]; then local_valid "$MOCK_STATE/output"
    else
        [[ ! -s $MOCK_STATE/output ]]
        reject_matches 'backup: success;' "$MOCK_STATE/errors"
        for run in "$BACKUP_WORK_DIR"/dockseed-*; do [[ ! -e $run/LOCAL_COMPLETE ]]; done
        case "$scenario" in
            unhealthy|low-space|low-work-space|low-backup-space|df-failure|publish-failure|work-create-failure|log-create-failure|nonzero-keep-time|missing-secret|missing-rb|missing-version|ambiguous-packages|git-failure|missing-runtime-config|deployment-archive-failure)
                [[ ! -e $lock ]]
                if [[ $scenario != publish-failure ]]; then reject_matches 'gitlab-backup create' "$MOCK_STATE/commands"; fi ;;
            *) [[ -d $lock ]] ;;
        esac
        case "$scenario" in
            cleanup-failure|cleanup-lock-failure|publish-failure)
                for run in "$BACKUP_WORK_DIR"/dockseed-*; do [[ -s $run/config.tar && -s $run/.LOCAL_COMPLETE.tmp ]]; done ;;
            *) reject_matches '^docker exec [^ ]+ (rm|rmdir) ' "$MOCK_STATE/commands" ;;
        esac
    fi
    passed=$((passed + 1))
    printf 'PASS: backup / %s\n' "$scenario"
}
run_case success pass
reject_matches 'ossutil|OSS_DESTINATION|OSS_ENDPOINT' "$fixture/project/ops/backup.sh"
[[ $(tail -n 2 "$MOCK_STATE/commands" | head -n 1) = *'rmdir /var/opt/gitlab/backups/.dockseed-backup.lock' ]]
[[ $(tail -n 1 "$MOCK_STATE/commands") = 'mv '*'/LOCAL_COMPLETE' ]]
for variable in INCREMENTAL PREVIOUS_BACKUP REPOSITORIES_SERVER_SIDE REPOSITORIES_PATHS REPOSITORIES_STORAGES \
    SKIP_REPOSITORIES_PATHS COMPRESS_CMD DECOMPRESS_CMD STRATEGY GZIP_RSYNCABLE; do
    grep -q -- "-u $variable " "$MOCK_STATE/commands"
done
run_case separate-filesystems pass
reject_matches 'df -Pk /tmp$' "$MOCK_STATE/commands"
run_case low-work-space
grep -Fq 'host work directory: need 81.0 GiB, available 40.0 GiB' "$MOCK_STATE/errors"
run_case low-backup-space
grep -Fq 'container /var/opt/gitlab/backups: need 81.0 GiB, available 40.0 GiB' "$MOCK_STATE/errors"
run_case archive-too-large pass
grep -q 'WARNING: archives exceeded BACKUP_ESTIMATE_KB' "$MOCK_STATE/errors"
run_case lock-race
grep -qx 'another task' "$lock/owner"
reject_matches 'gitlab-backup create' "$MOCK_STATE/commands"
run_case git-failure
# A preflight failure must not prevent a corrected retry from backing up.
MOCK_CASE=success bash "$fixture/project/ops/backup.sh" > "$MOCK_STATE/retry-output" 2> "$MOCK_STATE/retry-errors"
local_valid "$MOCK_STATE/retry-output"
preserved
passed=$((passed + 1))
printf 'PASS: backup / retry after preflight failure\n'
for scenario in unhealthy low-space df-failure nonzero-keep-time missing-secret missing-rb missing-version ambiguous-packages \
    missing-runtime-config deployment-archive-failure low-copy-space \
    app-failure missing-app config-failure missing-archived-secret wrong-secret-name missing-metadata wrong-version partial-backup \
    partial-extraction copy-corruption source-checksum-failure checksum-generation-failure \
    final-checksum-failure publish-failure work-create-failure log-create-failure cleanup-failure cleanup-lock-failure; do
    run_case "$scenario"
done
# A retained cleanup failure prevents another application backup.
before=$(grep -c 'gitlab-backup create' "$MOCK_STATE/commands")
before_directories=$(find "$BACKUP_WORK_DIR" -type d | wc -l)
result=0
bash "$fixture/project/ops/backup.sh" > "$MOCK_STATE/retry-output" 2>&1 || result=$?
[[ $result != 0 && $(grep -c 'gitlab-backup create' "$MOCK_STATE/commands") = "$before" ]]
[[ $(find "$BACKUP_WORK_DIR" -type d | wc -l) = "$before_directories" ]]
grep -q 'previous failure retained' "$MOCK_STATE/retry-output"
preserved
passed=$((passed + 1))
printf 'PASS: backup / retained failure blocks retry\n'

# Overlap two host work directories against one mock container data volume.
setup concurrent
bash "$fixture/project/ops/backup.sh" > "$MOCK_STATE/first-output" 2> "$MOCK_STATE/first-errors" &
first_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ ! -e $MOCK_STATE/app-entered ]] || break
    sleep 0.1
done
[[ -e $MOCK_STATE/app-entered ]] || { cat "$MOCK_STATE/first-output" >&2; exit 1; }
mkdir "$MOCK_STATE/second-work"
result=0
BACKUP_WORK_DIR="$MOCK_STATE/second-work" bash "$fixture/project/ops/backup.sh" > "$MOCK_STATE/second-output" 2>&1 || result=$?
: > "$MOCK_STATE/release-app"
wait "$first_pid"
[[ $result != 0 && $(grep -c 'gitlab-backup create' "$MOCK_STATE/commands") = 1 ]]
grep -q 'backup already running' "$MOCK_STATE/second-output"
[[ $(find "$MOCK_STATE/second-work" -mindepth 1 | wc -l | tr -d ' ') = 0 ]]
preserved
local_valid "$MOCK_STATE/first-output"
passed=$((passed + 1))
printf 'PASS: backup / concurrent across work directories\nAll %s backup mock tests passed.\n' "$passed"
