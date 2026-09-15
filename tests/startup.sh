#!/usr/bin/env bash
# Exercise the actual Compose startup guard without Docker or real GitLab paths.
set -euo pipefail
umask 077
repo=$(cd "$(dirname "$0")/.." && pwd -P)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/dockseed-startup-test.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT
mkdir "$fixture/data"
compose=$repo/docker-compose.yml

# This project has one literal command block, not a general YAML parser.
guard=$(awk '
    /^    command:$/ {command=1; next}
    command && /^      - \|$/ {block=1; next}
    block && /^        / {sub(/^        /, ""); print; next}
    block {exit}
' "$compose")
[[ -n $guard ]]
grep -q '^      - /bin/bash$' "$compose"
grep -q '^      - -ec$' "$compose"
normal_mode=$(awk '/^      GITLAB_ALLOW_INITIALIZATION:/ {print $2}' "$compose")
[[ $normal_mode = '"false"' ]]
normal_mode=${normal_mode//\"/}
printf '%s\n' "$guard" | grep -qx 'exec /assets/init-container'
guard=$(printf '%s\n' "$guard" | awk -v fixture="$fixture" '
    {gsub(/\$\$/, "$")
     gsub("/etc/gitlab/gitlab-secrets.json", "\"" fixture "/data/secrets\"")
     gsub("/var/opt/gitlab/postgresql/data/PG_VERSION", "\"" fixture "/data/PG_VERSION\"")
     gsub("/assets/init-container", "\"" fixture "/init-container\""); print}
')
cat > "$fixture/init-container" <<'STUB'
#!/usr/bin/env bash
printf 'official init entered\n' > "$TEST_INIT_MARKER"
STUB
chmod +x "$fixture/init-container"
export TEST_INIT_MARKER="$fixture/entered"
snapshot() {
    find "$fixture/data" -print
    find "$fixture/data" -type f -exec cksum {} \;
}
passed=0
run_case() {
    local name=$1 secrets=$2 postgres=$3 mode=$4 expected=$5 result=0 before
    local command=(env -u GITLAB_ALLOW_INITIALIZATION)
    rm -f -- "$fixture/data/secrets" "$fixture/data/PG_VERSION" "$TEST_INIT_MARKER"
    case "$secrets" in present) printf '{}\n' > "$fixture/data/secrets" ;; empty) : > "$fixture/data/secrets" ;; esac
    case "$postgres" in present) printf '16\n' > "$fixture/data/PG_VERSION" ;; empty) : > "$fixture/data/PG_VERSION" ;; dangling) ln -s missing "$fixture/data/PG_VERSION" ;; esac
    before=$(snapshot)
    if [[ $mode != unset ]]; then command+=("GITLAB_ALLOW_INITIALIZATION=$mode"); fi
    "${command[@]}" /bin/bash -ec "$guard" > "$fixture/output" 2>&1 || result=$?
    if [[ $expected = pass ]]; then
        [[ $result = 0 && -s $TEST_INIT_MARKER ]]
    else
        [[ $result != 0 && ! -e $TEST_INIT_MARKER ]]
        grep -q 'Refusing to start GitLab:' "$fixture/output"
    fi
    [[ $(snapshot) = "$before" ]]
    passed=$((passed + 1))
    printf 'PASS: startup / %s\n' "$name"
}
run_case existing-data present present "$normal_mode" pass
run_case empty-directories missing missing "$normal_mode" fail
run_case missing-secrets missing present "$normal_mode" fail
run_case missing-postgresql present missing "$normal_mode" fail
run_case empty-secrets empty present "$normal_mode" fail
run_case empty-postgresql present empty "$normal_mode" fail
run_case explicit-initialization missing missing true pass
run_case restore-configuration present missing true pass
run_case reject-reinitialization present present true fail
run_case reject-reinitialization-missing-secrets missing present true fail
run_case reject-reinitialization-empty-marker present empty true fail
run_case reject-reinitialization-dangling-marker present dangling true fail
run_case missing-permission missing missing unset fail
run_case wrong-permission-value missing missing TRUE fail

# A literal Compose value cannot be expanded from host/.env configuration.
export GITLAB_ALLOW_INITIALIZATION=true
run_case normal-environment-remains-locked missing missing "$normal_mode" fail
for attempt in 1 2 3; do
    run_case "repeated-start-$attempt" missing missing "$normal_mode" fail
done
printf 'All %s startup guard tests passed.\n' "$passed"
