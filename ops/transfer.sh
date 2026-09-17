#!/usr/bin/env bash
# Transfer a complete backup package; never starts GitLab or deletes OSS objects.
set -euo pipefail
umask 077
export LC_ALL=C
# fd 3 sends progress/errors to the terminal; fd 4 only emits the final directory.
exec 3>&2 4>&1

fail() { printf 'transfer: %s\n' "$*" >&3; exit 1; }
log() { printf '%s transfer: %s\n' "$(date -u +%FT%TZ)" "$*" >&3; }
usage() { fail 'usage: transfer.sh upload /backup/directory [--remove-local] | download oss://bucket/prefix/backup-id /new/directory'; }
action=${1:-}
remove_local=false
# marker is LOCAL_COMPLETE for uploads, a temporary downloaded COMPLETE for downloads.
case "$action" in
    upload)
        [[ $# = 2 || ( $# = 3 && $3 = --remove-local ) ]] || usage
        if [[ $# = 3 ]]; then remove_local=true; fi
        dir=$2
        [[ $dir = /* && -d $dir && ! -L $dir ]] || fail 'upload directory must be an existing absolute directory, not a symlink'
        dir=$(cd "$dir" && pwd -P)
        marker=$dir/LOCAL_COMPLETE
        [[ -s $marker && ! -L $marker ]] || fail 'LOCAL_COMPLETE is required; this backup is not ready'
        id=$(sed -n 's/^backup_id=//p' "$marker")
        : "${OSS_DESTINATION:?set OSS_DESTINATION=oss://bucket/prefix}"
        remote=${OSS_DESTINATION%/}/$id
        ;;
    download)
        [[ $# = 3 ]] || usage
        remote=${2%/}
        id=${remote##*/}
        dir=$3
        [[ $dir = /* && ! -e $dir && ! -L $dir && -d ${dir%/*} ]] || fail 'download target must be a new absolute directory with an existing parent'
        marker=$dir/.complete.download
        ;;
    *) usage ;;
esac
[[ $id =~ ^dockseed-[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}$ ]] || fail 'select an explicit dockseed backup ID'
[[ $remote =~ ^oss://[a-z0-9][a-z0-9-]+/[A-Za-z0-9._/-]+$ ]] || fail 'invalid OSS bucket/prefix'
: "${OSS_ENDPOINT:?set an HTTPS OSS_ENDPOINT}"
[[ $OSS_ENDPOINT =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || fail 'OSS_ENDPOINT must use HTTPS'
command -v ossutil >/dev/null 2>&1 || fail 'ossutil 2.x is required for transfer'
oss_version=$(ossutil version)
[[ $oss_version =~ (^|[[:space:]])v?2\.[0-9]+\. ]] || fail 'official ossutil 2.x is required'
if command -v sha256sum >/dev/null 2>&1; then
    sha=(sha256sum)
else
    command -v shasum >/dev/null 2>&1 || fail 'sha256sum or shasum is required'
    sha=(shasum -a 256)
fi
if [[ $action = download ]]; then mkdir -m 700 "$dir"; fi
# Serialize transfers of this local package; unrelated backups remain independent.
mkdir -m 700 "$dir/.transfer.lock" 2>/dev/null || fail 'transfer already running or stale .transfer.lock; inspect before retrying'
on_exit() {
    local rc=$?
    trap - EXIT
    rmdir "$dir/.transfer.lock" || rc=1
    if [[ $rc != 0 ]]; then log "FAILED; retained $dir; details: $dir/transfer.log"; fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
exec >>"$dir/transfer.log" 2>&1
log "$action $id; private details: $dir/transfer.log"
files=("${id}_gitlab_backup.tar" config.tar deployment.tar manifest.txt)

verify_package() {
    local file marker_id marker_digest checksum_digest expected_files listed_files
    for file in "${files[@]}" SHA256SUMS; do
        [[ -f $dir/$file && -s $dir/$file && ! -L $dir/$file ]] || fail "required file missing or symlink: $file"
    done
    [[ -f $marker && -s $marker && ! -L $marker ]] || fail 'completion marker missing or symlink'
    marker_id=$(sed -n 's/^backup_id=//p' "$marker")
    [[ $marker_id = "$id" ]] || fail 'completion marker backup ID mismatch'
    marker_digest=$(sed -n 's/^checksums_sha256=//p' "$marker")
    [[ $marker_digest =~ ^[a-f0-9]{64}$ ]] || fail 'invalid SHA256SUMS hash in completion marker'
    checksum_digest=$("${sha[@]}" "$dir/SHA256SUMS" | awk '{print $1}')
    [[ $checksum_digest = "$marker_digest" ]] || fail 'SHA256SUMS differs from completion marker'
    # Only these four relative filenames may be read by the checksum command.
    expected_files=$(printf '  %s\n' "${files[@]}")
    listed_files=$(sed -E 's/^[a-f0-9]{64}//' "$dir/SHA256SUMS")
    [[ $listed_files = "$expected_files" ]] || fail 'SHA256SUMS must list exactly the four expected files'
    grep -Fx "backup_id=$id" "$dir/manifest.txt" >/dev/null || fail 'manifest backup ID mismatch'
    (cd "$dir" && "${sha[@]}" -c SHA256SUMS)
}

copy_object() {
    log "$action ${1##*/} -> ${2##*/}"
    ossutil cp "$1" "$2" --endpoint "$OSS_ENDPOINT" --ignore-existing --no-progress \
        --checkpoint-dir "$dir/checkpoints" --output-dir "$dir/ossutil-output" ||
        fail "transfer failed; check $dir/transfer.log (credentials, permissions, endpoint and network)"
}
crc64() {
    local value
    value=$(ossutil hash crc64 "$1" --endpoint "$OSS_ENDPOINT" --output-format raw |
        awk '$1 ~ /^[0-9]+$/ {print $1}') || fail "cannot compute CRC64: $1"
    [[ $value =~ ^[0-9]+$ ]] || fail 'ossutil did not return a CRC64 value'
    printf '%s\n' "$value"
}
upload_object() {
    local source=$1 destination=$2 local_crc remote_crc
    copy_object "$source" "$destination"
    # A skipped existing object also returns success. Compare OSS's CRC64 using
    # ossutil; keep 64-bit values as strings, without floating-point conversion.
    local_crc=$(crc64 "$source")
    remote_crc=$(crc64 "$destination")
    [[ $local_crc = "$remote_crc" ]] || fail "OSS CRC64 mismatch: ${destination##*/}"
}

if [[ $action = upload ]]; then
    verify_package
    for file in "${files[@]}" SHA256SUMS; do upload_object "$dir/$file" "$remote/$file"; done
    # Confirm local files did not change during upload before publishing COMPLETE.
    verify_package
    # Stable bytes allow retrying after a lost response. COMPLETE is always last.
    upload_object "$marker" "$remote/COMPLETE"
    if [[ $remove_local = true ]]; then
        # Invalidate local readiness first; delete only this package's known files.
        rm -- "$marker"
        for file in "${files[@]}" SHA256SUMS; do rm -- "$dir/$file"; done
    fi
else
    # HEAD needs only the existing GetObject permission. Size is for capacity,
    # not integrity; the downloaded package must still pass SHA-256 verification.
    log 'checking download size and free space'
    object_path=${remote#oss://}
    headroom_kb=1048576 # 1 GiB
    required_kb=$headroom_kb
    for file in COMPLETE SHA256SUMS "${files[@]}"; do
        bytes=$(ossutil api head-object --bucket "${object_path%%/*}" --key "${object_path#*/}/$file" \
            --endpoint "$OSS_ENDPOINT" --output-format json \
            --output-query 'to_number(Header."Content-Length"[0])' --quiet) ||
            fail "cannot read remote file size: $file; check $dir/transfer.log"
        [[ $bytes =~ ^[1-9][0-9]{0,14}$ ]] || fail "missing or invalid remote file size: $file"
        required_kb=$((required_kb + (bytes + 1023) / 1024))
    done
    available=$(df -Pk "$dir" | awk 'END {print $4}')
    [[ $available =~ ^[0-9]+$ ]] || fail 'cannot read download filesystem free space'
    ((available >= required_kb)) || fail "insufficient download space: $(awk -v need="$required_kb" -v free="$available" 'BEGIN {printf "need %.1f GiB, available %.1f GiB", need/1048576, free/1048576}')"
    copy_object "$remote/COMPLETE" "$marker"
    for file in SHA256SUMS "${files[@]}"; do copy_object "$remote/$file" "$dir/$file"; done
    log 'verifying downloaded package (SHA-256)'
    verify_package
fi
# Unlock before publishing local readiness or reporting success; unlock failure
# must still fail the transfer. The EXIT trap handles earlier failures instead.
rmdir "$dir/.transfer.lock"
trap - EXIT
if [[ $action = download ]]; then
    mv -- "$marker" "$dir/LOCAL_COMPLETE" || fail "cannot publish LOCAL_COMPLETE; retained $dir"
    log "download complete; SHA-256 verified; elapsed ${SECONDS}s; follow docs/recovery.md for restoration"
else
    log "upload complete; CRC64 verified; remote: $remote; elapsed ${SECONDS}s (a real restore drill is still required)"
fi
printf '%s\n' "$dir" >&4
