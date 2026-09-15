#!/usr/bin/env bash
# Offline package transfer: only ossutil is mocked; all files stay in this fixture.
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/dockseed-transfer-test.XXXXXX")
fixture=$(cd "$fixture" && pwd -P)
first_pid=''
cleanup() {
    if [[ -n $first_pid ]]; then
        kill "$first_pid" 2>/dev/null || true
        wait "$first_pid" 2>/dev/null || true
    fi
    rm -rf -- "$fixture"
}
trap cleanup EXIT
mkdir "$fixture/bin"
cp "$repo/ops/transfer.sh" "$fixture/transfer.sh"
if command -v sha256sum >/dev/null 2>&1; then sha=(sha256sum); else sha=(shasum -a 256); fi
# No Docker, Git, real ossutil or checkout/.env is reachable through this PATH.
for tool in bash date sed mkdir awk grep rm cp dirname cksum sleep "${sha[0]}"; do
    ln -s "$(command -v "$tool")" "$fixture/bin/$tool"
done
export MOCK_REAL_RMDIR MOCK_REAL_MV
MOCK_REAL_RMDIR=$(command -v rmdir)
MOCK_REAL_MV=$(command -v mv)
export MOCK_ROOT="$fixture" OSS_ENDPOINT=https://oss-fixture.invalid
export OSS_DESTINATION=oss://fixture-bucket/daily
id=dockseed-20260915T010203Z-0123456789abcdef
files=("${id}_gitlab_backup.tar" config.tar deployment.tar manifest.txt)

cat > "$fixture/bin/ossutil" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
bad() { printf 'MOCK-ERROR: %s\n' "$*" >> "$MOCK_STATE/commands"; exit 99; }
local_path() {
    case "$1" in
        oss://fixture-bucket/*) printf '%s/remote/%s\n' "$MOCK_STATE" "${1#oss://fixture-bucket/}" ;;
        "$MOCK_ROOT"/*) printf '%s\n' "$1" ;;
        *) bad 'path outside fixture' ;;
    esac
}
case "${1:-}" in
    version)
        [[ $# = 1 ]] || bad 'unexpected version arguments'
        if [[ $MOCK_CASE = wrong-version ]]; then printf 'ossutil version: 1.7.0\n'
        else printf 'ossutil version: 2.4.0\n'; fi ;;
    api)
        [[ $# = 13 && $2 = head-object && $3 = --bucket && $4 = fixture-bucket &&
            $5 = --key && $7 = --endpoint && $8 = https://oss-fixture.invalid &&
            $9 = --output-format && ${10} = json && ${11} = --output-query &&
            ${12} = 'to_number(Header."Content-Length"[0])' && ${13} = --quiet ]] || bad 'unexpected HEAD arguments'
        printf 'head %s\n' "$6" >> "$MOCK_STATE/commands"
        [[ $MOCK_CASE != head-failure ]] || exit 27
        if [[ $MOCK_CASE = invalid-size ]]; then printf 'null\n'; exit 0; fi
        if [[ $MOCK_CASE = huge-size ]]; then printf '9999999999999999\n'; exit 0; fi
        if [[ $MOCK_CASE = zero-size ]]; then printf '0\n'; exit 0; fi
        # Each fixture object reports 1 GiB to verify the total, not only headroom.
        [[ -s $(local_path "oss://fixture-bucket/$6") ]] || exit 20
        printf '1073741824\n' ;;
    cp)
        [[ $# = 11 && $4 = --endpoint && $5 = https://oss-fixture.invalid &&
            $6 = --ignore-existing && $7 = --no-progress && $8 = --checkpoint-dir &&
            ${10} = --output-dir ]] || bad 'unexpected cp arguments'
        printf 'cp %s %s\n' "$2" "$3" >> "$MOCK_STATE/commands"
        source=$(local_path "$2")
        destination=$(local_path "$3")
        [[ -f $source ]] || exit 20
        if [[ $MOCK_CASE = upload-failure && $3 = oss://*/config.tar ]]; then exit 21; fi
        if [[ $MOCK_CASE = concurrent && $3 = oss://*/*_gitlab_backup.tar ]]; then
            : > "$MOCK_STATE/upload-entered"
            for ((attempt=0; attempt<200; attempt++)); do
                [[ ! -e $MOCK_STATE/release-upload ]] || break
                sleep 0.05
            done
            [[ -e $MOCK_STATE/release-upload ]] || exit 22
        fi
        if [[ -e $destination ]]; then
            printf 'skipped %s\n' "$3" >> "$MOCK_STATE/commands"
        else
            mkdir -p "$(dirname "$destination")"
            cp "$source" "$destination"
        fi
        if [[ $MOCK_CASE = complete-response-lost && $3 = oss://*/COMPLETE ]]; then exit 26; fi ;;
    hash)
        [[ $# = 7 && $2 = crc64 && $4 = --endpoint && $5 = https://oss-fixture.invalid &&
            $6 = --output-format && $7 = raw ]] || bad 'unexpected hash arguments'
        printf 'hash %s\n' "$3" >> "$MOCK_STATE/commands"
        if [[ $3 = oss://*/config.tar ]]; then
            if [[ $MOCK_CASE = crc-mismatch ]]; then printf '0  mock\n'; exit 0; fi
            if [[ $MOCK_CASE = crc-failure ]]; then printf '123  mock\n'; exit 23; fi
        fi
        # cksum only supplies a content-dependent decimal stand-in, not an OSS protocol.
        cksum "$(local_path "$3")" | awk '{print $1}' ;;
    *) bad 'unexpected ossutil command' ;;
esac
MOCK
chmod +x "$fixture/bin/ossutil"
cat > "$fixture/bin/local-operation" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${0##*/}" in
    df)
        [[ $# = 2 && $1 = -Pk && $2 = "$MOCK_STATE/download" ]] || exit 99
        [[ $MOCK_CASE != df-failure ]] || exit 28
        free=7340032
        if [[ $MOCK_CASE = low-space ]]; then free=7340031; fi
        if [[ $MOCK_CASE = invalid-space ]]; then free=unknown; fi
        printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nmock 10000000 1 %s 1%% /mock\n' "$free" ;;
    rmdir)
        if [[ $MOCK_CASE = lock-release-failure && $1 = "$MOCK_STATE/download/.transfer.lock" ]]; then exit 24; fi
        exec "$MOCK_REAL_RMDIR" "$@" ;;
    mv)
        if [[ $MOCK_CASE = publish-failure && ${!#} = "$MOCK_STATE/download/LOCAL_COMPLETE" ]]; then exit 25; fi
        exec "$MOCK_REAL_MV" "$@" ;;
    *) exit 99 ;;
esac
MOCK
chmod +x "$fixture/bin/local-operation"
ln -s local-operation "$fixture/bin/rmdir"
ln -s local-operation "$fixture/bin/mv"
ln -s local-operation "$fixture/bin/df"

marker_for() {
    local digest
    digest=$("${sha[@]}" "$source/SHA256SUMS" | awk '{print $1}')
    printf 'backup_id=%s\ncompleted_at_utc=2026-09-15T01:02:03Z\nchecksums_sha256=%s\nrestore_tested=no\n' \
        "$id" "$digest" > "$source/LOCAL_COMPLETE"
}
setup_case() {
    export MOCK_CASE=$1 MOCK_STATE="$fixture/$1"
    source=$MOCK_STATE/source
    remote=$MOCK_STATE/remote/daily/$id
    mkdir -p "$source/history" "$MOCK_STATE/remote/daily/historical-success"
    : > "$MOCK_STATE/commands"
    printf 'application fixture\n' > "$source/${files[0]}"
    printf 'private fixture Secrets\n' > "$source/config.tar"
    printf 'deployment fixture\n' > "$source/deployment.tar"
    printf 'backup_id=%s\n' "$id" > "$source/manifest.txt"
    (cd "$source" && "${sha[@]}" "${files[@]}" > SHA256SUMS)
    marker_for
    printf 'keep local history\n' > "$source/history/success.tar"
    printf 'keep unrelated file\n' > "$source/unrelated.txt"
    printf 'keep operations log\n' > "$source/operations.log"
    printf 'keep remote history\n' > "$MOCK_STATE/remote/daily/historical-success/COMPLETE"
}
assert_preserved() {
    [[ $(cat "$source/history/success.tar") = 'keep local history' ]]
    [[ $(cat "$source/unrelated.txt") = 'keep unrelated file' ]]
    [[ $(cat "$source/operations.log") = 'keep operations log' ]]
    [[ $(cat "$MOCK_STATE/remote/daily/historical-success/COMPLETE") = 'keep remote history' ]]
    if grep -q '^MOCK-ERROR:' "$MOCK_STATE/commands"; then
        cat "$MOCK_STATE/commands" >&2; exit 1
    fi
}
run_transfer() {
    PATH="$fixture/bin" "$fixture/bin/bash" "$fixture/transfer.sh" "$@"
}
case_count=0
expect() {
    local expected=$1 result=0
    shift
    run_transfer "$@" > "$MOCK_STATE/stdout" 2> "$MOCK_STATE/stderr" || result=$?
    if { [[ $expected = pass ]] && ((result != 0)); } || { [[ $expected = fail ]] && ((result == 0)); }; then
        cat "$MOCK_STATE/stderr" >&2
        [[ ! -f $source/transfer.log ]] || cat "$source/transfer.log" >&2
        printf 'FAIL: %s / %s (exit %s)\n' "$MOCK_CASE" "$1" "$result" >&2
        exit 1
    fi
    if [[ $expected = fail ]]; then [[ ! -s $MOCK_STATE/stdout ]]; fi
    assert_preserved
    case_count=$((case_count + 1))
    printf 'PASS: transfer / %s / %s\n' "$MOCK_CASE" "$1"
}
assert_no_upload_marker() {
    [[ ! -e $remote/COMPLETE ]]
    if grep -Eq '^cp .* oss://[^ ]+/COMPLETE$' "$MOCK_STATE/commands"; then
        printf 'FAIL: attempted COMPLETE before payload verification\n' >&2; exit 1
    fi
}
seed_remote() {
    mkdir -p "$remote"
    for file in "${files[@]}" SHA256SUMS; do cp "$source/$file" "$remote/$file"; done
    cp "$source/LOCAL_COMPLETE" "$remote/COMPLETE"
}

setup_case roundtrip
expect pass upload "$source"
for file in "${files[@]}" SHA256SUMS; do cmp "$source/$file" "$remote/$file"; done
cmp "$source/LOCAL_COMPLETE" "$remote/COMPLETE"
[[ $(awk '/^cp / {last=$NF} END {print last}' "$MOCK_STATE/commands") = "$OSS_DESTINATION/$id/COMPLETE" ]]
cp "$remote/COMPLETE" "$MOCK_STATE/original-COMPLETE"
expect pass upload "$source"
grep -q '^skipped ' "$MOCK_STATE/commands"
cmp "$remote/COMPLETE" "$MOCK_STATE/original-COMPLETE"
OSS_DESTINATION='' expect pass download "oss://fixture-bucket/daily/$id" "$MOCK_STATE/download"
for file in "${files[@]}" SHA256SUMS LOCAL_COMPLETE; do cmp "$source/$file" "$MOCK_STATE/download/$file"; done
[[ ! -e $source/.transfer.lock && ! -e $MOCK_STATE/download/.transfer.lock ]]

setup_case remove-local
expect pass upload "$source" --remove-local
for file in "${files[@]}" SHA256SUMS LOCAL_COMPLETE; do [[ ! -e $source/$file ]]; done
[[ -s $source/transfer.log && -s $remote/COMPLETE ]]
(cd "$remote" && "${sha[@]}" -c SHA256SUMS >/dev/null)

for scenario in incomplete wrong-version missing-payload payload-corruption checksum-tamper relative-checksum-path absolute-checksum-path; do
    setup_case "$scenario"
    case "$scenario" in
        incomplete) rm "$source/LOCAL_COMPLETE" ;;
        missing-payload) rm "$source/config.tar" ;;
        payload-corruption) printf 'changed payload\n' >> "$source/config.tar" ;;
        checksum-tamper) printf 'changed checksum list\n' >> "$source/SHA256SUMS" ;;
        *-checksum-path)
            printf 'outside package but still inside fixture\n' > "$MOCK_STATE/outside-payload"
            path=../outside-payload
            [[ $scenario != absolute-checksum-path ]] || path=$MOCK_STATE/outside-payload
            (cd "$source" && "${sha[@]}" "$path" config.tar deployment.tar manifest.txt > SHA256SUMS)
            marker_for ;;
    esac
    expect fail upload "$source" --remove-local
    assert_no_upload_marker
    [[ ! -s $MOCK_STATE/commands && -s $source/SHA256SUMS && -s $source/${files[0]} ]]
done

for scenario in upload-failure crc-mismatch crc-failure existing-different; do
    setup_case "$scenario"
    if [[ $scenario = existing-different ]]; then
        mkdir -p "$remote"
        printf 'pre-existing object must survive\n' > "$remote/config.tar"
    fi
    expect fail upload "$source" --remove-local
    assert_no_upload_marker
    for file in "${files[@]}" SHA256SUMS LOCAL_COMPLETE; do [[ -s $source/$file ]]; done
    if [[ $scenario = existing-different ]]; then [[ $(cat "$remote/config.tar") = 'pre-existing object must survive' ]]; fi
    if [[ $scenario = upload-failure ]]; then
        # Retry the same package and partially uploaded prefix without regenerating it.
        MOCK_CASE=upload-retry
        expect pass upload "$source"
        for file in "${files[@]}" SHA256SUMS; do cmp "$source/$file" "$remote/$file"; done
        cmp "$source/LOCAL_COMPLETE" "$remote/COMPLETE"
    fi
done

setup_case complete-response-lost
expect fail upload "$source" --remove-local
for file in "${files[@]}" SHA256SUMS LOCAL_COMPLETE; do [[ -s $source/$file ]]; done
cmp "$source/LOCAL_COMPLETE" "$remote/COMPLETE"
cp "$remote/COMPLETE" "$MOCK_STATE/original-COMPLETE"
MOCK_CASE=complete-retry
expect pass upload "$source"
grep -Fx "skipped $OSS_DESTINATION/$id/COMPLETE" "$MOCK_STATE/commands" >/dev/null
cmp "$remote/COMPLETE" "$MOCK_STATE/original-COMPLETE"
cmp "$source/LOCAL_COMPLETE" "$MOCK_STATE/original-COMPLETE"
for file in "${files[@]}" SHA256SUMS; do cmp "$source/$file" "$remote/$file"; done

for scenario in missing-remote-marker missing-remote-payload corrupt-remote-payload existing-target lock-release-failure publish-failure \
    low-space df-failure invalid-space head-failure invalid-size huge-size zero-size; do
    setup_case "$scenario"
    seed_remote
    target=$MOCK_STATE/download
    case "$scenario" in
        missing-remote-marker) rm "$remote/COMPLETE" ;;
        missing-remote-payload) rm "$remote/config.tar" ;;
        corrupt-remote-payload) printf 'remote corruption\n' >> "$remote/config.tar" ;;
        existing-target) mkdir "$target"; printf 'do not overwrite\n' > "$target/sentinel" ;;
    esac
    expect fail download "oss://fixture-bucket/daily/$id" "$target"
    [[ ! -e $target/LOCAL_COMPLETE ]]
    case "$scenario" in
        low-space|df-failure|invalid-space|head-failure|invalid-size|huge-size|zero-size|missing-remote-*)
            if grep -q '^cp ' "$MOCK_STATE/commands"; then
                printf 'FAIL: downloaded payload before capacity/metadata checks passed\n' >&2; exit 1
            fi ;;
    esac
    if [[ $scenario = existing-target ]]; then
        [[ $(cat "$target/sentinel") = 'do not overwrite' && ! -s $MOCK_STATE/commands && ! -e $target/transfer.log ]]
    fi
done

setup_case concurrent
run_transfer upload "$source" > "$MOCK_STATE/first-stdout" 2> "$MOCK_STATE/first-stderr" &
first_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ ! -e $MOCK_STATE/upload-entered ]] || break
    sleep 0.05
done
[[ -e $MOCK_STATE/upload-entered ]]
expect fail upload "$source" --remove-local
grep -q 'transfer already running' "$MOCK_STATE/stderr"
[[ -d $source/.transfer.lock ]]
[[ $(grep -c '^cp ' "$MOCK_STATE/commands") = 1 ]]
: > "$MOCK_STATE/release-upload"
wait "$first_pid"
first_pid=''
[[ -s $source/LOCAL_COMPLETE && -s $remote/COMPLETE && ! -e $source/.transfer.lock ]]
assert_preserved
printf 'All %s transfer cases passed (including overlapping uploads).\n' "$case_count"
