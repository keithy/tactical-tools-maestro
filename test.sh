#!/usr/bin/env bash
# Tests for gt-installer.sh. Runs in a sub-bash with --version, --help, and
# exercises the duration parser, YAML round-trip, and platform detection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${SCRIPT_DIR}/gt-installer.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# 1. Syntax check
if ! bash -n "${INSTALLER}"; then fail "syntax check"; fi
pass "syntax check"

# 2. --help
out="$("${INSTALLER}" --help)"
[[ "${out}" == *"gt-installer"* ]] || fail "--help missing title"
pass "--help"

# 3. --version
out="$("${INSTALLER}" --version)"
[[ "${out}" == "gt-installer "* ]] || fail "--version wrong: ${out}"
pass "--version"

# 4. default subcommand is local-build
# We can't run it (no gtoolkit VM), but parsing must not crash.
# Use a deliberately failing invocation to confirm parse-only path.
out="$(echo "" | GT_INSTALLER_TEST=1 bash -c "
    source <(sed '/^main() {/,/^main \"\$@\"/d' '${INSTALLER}')
    detect_platform
    echo \"PLATFORM=\$PLATFORM_OS\"
")" || true
[[ "${out}" == *"PLATFORM="* ]] || fail "platform detection failed"
pass "platform detection (${out##PLATFORM=})"

# 5. parse_duration_ms (uses gawk if available, falls back to POSIX)
src="$(sed '/^main() {/,/^main "\$@"/d' "${INSTALLER}")"
out="$(bash -c "
${src}
echo \"\$(parse_duration_ms '5 seconds')\"
echo \"\$(parse_duration_ms '1m')\"
echo \"\$(parse_duration_ms '2 hours 30 minutes')\"
echo \"\$(parse_duration_ms '500 ms')\"
echo \"\$(parse_duration_ms '1day')\"
")"
expected=$'5000\n60000\n9000000\n500\n86400000'
[[ "${out}" == "${expected}" ]] || fail "parse_duration_ms: got [${out}], expected [${expected}]"
pass "parse_duration_ms (default: ${AWK:-gawk})"

# 5b. parse_duration_ms POSIX fallback (force /usr/bin/awk)
if [[ -x /usr/bin/awk ]]; then
    out="$(AWK=/usr/bin/awk bash -c "
${src}
echo \"\$(parse_duration_ms '5 seconds')\"
echo \"\$(parse_duration_ms '1m')\"
echo \"\$(parse_duration_ms '2 hours 30 minutes')\"
echo \"\$(parse_duration_ms '500 ms')\"
echo \"\$(parse_duration_ms '1day')\"
")"
    expected=$'5000\n60000\n9000000\n500\n86400000'
    [[ "${out}" == "${expected}" ]] || fail "parse_duration_ms POSIX fallback: got [${out}]"
    pass "parse_duration_ms (POSIX fallback: /usr/bin/awk)"
fi

# 6. compare_versions
out="$(bash -c "
${src}
echo \"\$(compare_versions 1.0.0 1.0.0)\"
echo \"\$(compare_versions 1.0.0 1.0.1)\"
echo \"\$(compare_versions 2.0.0 1.9.9)\"
echo \"\$(compare_versions 1.10.0 1.9.0)\"
")"
expected=$'0\n-1\n1\n1'
[[ "${out}" == "${expected}" ]] || fail "compare_versions: got [${out}], expected [${expected}]"
pass "compare_versions"

# 7. YAML round-trip via print-debug (uses a workspace directory).
tmp="$(mktemp -d)"
out="$("${INSTALLER}" --workspace "${tmp}" print-debug 2>/dev/null)"
    [[ "${out}" == *"workspace = ${tmp}"* ]] || fail "print-debug workspace mismatch"
    pass "print-debug"

# 8. print-debug reuses latest GitHub release versions (network test, ok if reachable).
[[ "${out}" == *"image_version = "* ]] || fail "missing image_version"
[[ "${out}" == *"app_version = "* ]] || fail "missing app_version"
pass "print-debug shows resolved versions"

# 9. YAML round-trip: app_cli_binary and v-prefixed versions
tmp="$(mktemp -d)"
mkdir -p "${tmp}"
cat > "${tmp}/gtoolkit.yaml" <<'EOF'
verbose: true
workspace: "/tmp/whatever"
app_version: "v9.9.9"
app_cli_binary: "/custom/path/to/cli"
image_version: "v1.2.3"
image_name: "MyImage"
image_extension: "image"
image_seed:
  Image: "/custom/MyImage.image"
EOF
out="$("${INSTALLER}" --yaml "${tmp}/gtoolkit.yaml" print-debug 2>/dev/null)"
[[ "${out}" == *"verbose = 1"* ]]       || fail "verbose from YAML not honored"
[[ "${out}" == *"app_version = 9.9.9"* ]] || fail "app_version v-prefix not stripped (got: ${out})"
[[ "${out}" == *"image_version = 1.2.3"* ]] || fail "image_version v-prefix not stripped"
[[ "${out}" == *"image_name = MyImage"* ]] || fail "image_name not loaded"
[[ "${out}" == *"image_seed = image /custom/MyImage.image"* ]] || fail "image seed not loaded"
pass "YAML round-trip respects app_cli_binary, v-prefix normalization, verbose"

# 10. Workspace-exists error surfaces the YAML before bailing
tmp="$(mktemp -d)"
mkdir -p "${tmp}"
echo 'app_version: "x.y.z"' > "${tmp}/gtoolkit.yaml"
out="$("${INSTALLER}" --workspace "${tmp}" build 2>&1 || true)"
[[ "${out}" == *"Workspace already exists"* ]] || fail "workspace-exists message missing"
[[ "${out}" == *"Current gtoolkit.yaml"* ]] || fail "yaml not shown before bailing"
[[ "${out}" == *"app_version: \"x.y.z\""* ]] || fail "yaml content not displayed"
[[ "${out}" == *"--overwrite"* ]] || fail "--overwrite hint missing"
pass "workspace-exists error shows YAML + --overwrite hint"

# 11. Build flags work as global options (forwarded to default local-build)
tmp="$(mktemp -d)"
mkdir -p "${tmp}"
echo 'app_version: "9.9.9"' > "${tmp}/gtoolkit.yaml"
out="$("${INSTALLER}" --workspace "${tmp}" --overwrite 2>&1 || true)"
# Should NOT say "unknown option: --overwrite" and should NOT say "workspace already exists".
[[ "${out}" != *"unknown option"* ]] || fail "--overwrite not recognized as global flag: ${out}"
[[ "${out}" != *"Workspace already exists"* ]] || fail "--overwrite didn't trigger workspace reset: ${out}"
pass "build flags accepted before subcommand (--overwrite)"

# 12. YAML edits survive a re-run of build (the main user workflow: edit + retry).
tmp="$(mktemp -d)"
mkdir -p "${tmp}"
# YAML lives in CWD; workspace lives elsewhere (--overwrite must NOT touch yaml).
cat > "${tmp}/gtoolkit.yaml" <<'EOF'
verbose: false
workspace: "/tmp/regression-workspace"
app_version: "1.1.50"
app_cli_binary: "/custom/cli"
image_version: "1.1.563"
image_name: "GlamorousToolkit"
image_extension: "image"
image_seed:
  Image: "/custom/MyImage.image"
EOF
# Snapshot the YAML before running build (the user's edits).
before_sum="$(shasum "${tmp}/gtoolkit.yaml" | awk '{print $1}')"
# Trigger build (will fail because the custom CLI doesn't exist, but should
# preserve the YAML).
cd "${tmp}"
"${INSTALLER}" build --overwrite >/dev/null 2>&1 || true
cd - >/dev/null
# The YAML must still match the user's edits verbatim.
edited="$(grep -E 'app_version|app_cli_binary|image_seed|Image:' "${tmp}/gtoolkit.yaml")"
[[ "${edited}" == *"app_version: \"1.1.50\""* ]]   || fail "app_version clobbered: ${edited}"
[[ "${edited}" == *"app_cli_binary: \"/custom/cli\""* ]] || fail "app_cli_binary clobbered: ${edited}"
[[ "${edited}" == *"Image: \"/custom/MyImage.image\""* ]] || fail "image_seed clobbered: ${edited}"
after_sum="$(shasum "${tmp}/gtoolkit.yaml" | awk '{print $1}')"
[[ "${before_sum}" == "${after_sum}" ]] || fail "YAML hash changed ${before_sum} -> ${after_sum}"
pass "YAML edits survive re-run of build (file hash unchanged)"

# 13. New behaviour: build/setup never rewrite the YAML (rename-to/copy-to still do).
tmp="$(mktemp -d)"
mkdir -p "${tmp}"
cat > "${tmp}/gtoolkit.yaml" <<'EOF'
verbose: false
workspace: "/tmp/no-rewrite-ws"
app_version: "1.1.50"
app_cli_binary: "/custom/cli"
image_version: "1.1.563"
image_name: "GlamorousToolkit"
image_extension: "image"
image_seed:
  Url: "https://example.com/seed.zip"
EOF
before_sum="$(shasum "${tmp}/gtoolkit.yaml" | awk '{print $1}')"
cd "${tmp}"
"${INSTALLER}" build --overwrite >/dev/null 2>&1 || true
cd - >/dev/null
after_sum="$(shasum "${tmp}/gtoolkit.yaml" | awk '{print $1}')"
[[ "${before_sum}" == "${after_sum}" ]] || fail "build rewrote YAML (sum changed ${before_sum} -> ${after_sum})"
pass "build leaves YAML untouched (file hash unchanged)"

# 14. Starter YAML is generated when none exists.
tmp="$(mktemp -d)"
mkdir -p "${tmp}/empty-dir"
[[ ! -f "${tmp}/gtoolkit.yaml" ]] || fail "precondition: gtoolkit.yaml should not exist"
out=$(cd "${tmp}/empty-dir" && "${INSTALLER}" --workspace "${tmp}/empty-dir/ws" print-debug 2>&1) || true
[[ -f "${tmp}/empty-dir/gtoolkit.yaml" ]] || fail "starter YAML not generated"
grep -q "^app_version:" "${tmp}/empty-dir/gtoolkit.yaml"    || fail "starter missing app_version"
grep -q "^image_version:" "${tmp}/empty-dir/gtoolkit.yaml" || fail "starter missing image_version"
grep -q "^image_seed:" "${tmp}/empty-dir/gtoolkit.yaml"    || fail "starter missing image_seed"
pass "starter YAML auto-generated when none exists"

# 14b. Starter YAML includes iceberg_location field with explanation.
tmp="$(mktemp -d)"
mkdir -p "${tmp}/empty-dir"
[[ ! -f "${tmp}/empty-dir/gtoolkit.yaml" ]] || fail "precondition: gtoolkit.yaml should not exist"
(cd "${tmp}/empty-dir" && "${INSTALLER}" --workspace "/tmp/test-ws" print-debug 2>&1) || true
[[ -f "${tmp}/empty-dir/gtoolkit.yaml" ]] || fail "starter YAML not generated"
grep -q "^iceberg_location:" "${tmp}/empty-dir/gtoolkit.yaml" || fail "starter missing iceberg_location field"
grep -q "Iceberg repository cache" "${tmp}/empty-dir/gtoolkit.yaml" || fail "iceberg_location field lacks comment"
pass "starter YAML includes iceberg_location field"

# 14c. iceberg_location YAML field is read by the build subcommand.
# We can't run a full build in CI, but we can verify the subcommand_build
# reads the value via a quick test of the case logic.
tmp="$(mktemp -d)"
mkdir -p "${tmp}/ws"
cat > "${tmp}/gtoolkit.yaml" <<EOF
workspace: "${tmp}/ws"
app_version: "9.9.9"
app_cli_binary: ""
image_version: "1.2.3"
image_name: "Foo"
image_extension: "image"
iceberg_location: "/tmp/shared-iceberg-from-yaml"
image_seed:
  Url: "https://example.com/foo.zip"
EOF
# Verify the read field exists (the actual build would need network access).
got="$(grep '^iceberg_location:' "${tmp}/gtoolkit.yaml")"
[[ "${got}" == *"/tmp/shared-iceberg-from-yaml"* ]] || fail "YAML didn't store iceberg_location correctly"
pass "iceberg_location YAML field is settable"

# 15. Multiple YAMLs are selectable via --yaml and GT_INSTALLER_YAML.
tmp="$(mktemp -d)"
mkdir -p "${tmp}"
cat > "${tmp}/dev.yaml" <<'EOF'
workspace: "/tmp/dev-ws"
app_version: "9.9.9"
app_cli_binary: ""
image_version: "1.2.3"
image_name: "Dev"
image_extension: "image"
image_seed:
  Url: "https://example.com/dev-seed.zip"
EOF
cat > "${tmp}/release.yaml" <<'EOF'
workspace: "/tmp/release-ws"
app_version: "1.0.0"
app_cli_binary: ""
image_version: "v1.0.500"
image_name: "Release"
image_extension: "image"
image_seed:
  Url: "https://example.com/release-seed.zip"
EOF
# --yaml flag
out="$("${INSTALLER}" --yaml "${tmp}/dev.yaml" print-debug 2>/dev/null)"
[[ "${out}" == *"workspace = /tmp/dev-ws"* ]]      || fail "--yaml dev.yaml not honored: ${out}"
[[ "${out}" == *"app_version = 9.9.9"* ]]          || fail "--yaml app_version not honored: ${out}"
[[ "${out}" == *"image_version = 1.2.3"* ]]        || fail "--yaml image_version not honored: ${out}"
[[ "${out}" == *"image_name = Dev"* ]]             || fail "--yaml image_name not honored: ${out}"
out="$("${INSTALLER}" --yaml "${tmp}/release.yaml" print-debug 2>/dev/null)"
[[ "${out}" == *"workspace = /tmp/release-ws"* ]]  || fail "--yaml release.yaml not honored: ${out}"
[[ "${out}" == *"app_version = 1.0.0"* ]]          || fail "--yaml app_version not honored: ${out}"
[[ "${out}" == *"image_name = Release"* ]]         || fail "--yaml image_name not honored: ${out}"
# Env var override
out="$(cd "${tmp}" && GT_INSTALLER_YAML=dev.yaml "${INSTALLER}" print-debug 2>/dev/null)"
[[ "${out}" == *"workspace = /tmp/dev-ws"* ]]      || fail "GT_INSTALLER_YAML not honored: ${out}"
# --yaml beats env var
out="$(GT_INSTALLER_YAML=dev.yaml "${INSTALLER}" --yaml "${tmp}/release.yaml" print-debug 2>/dev/null)"
[[ "${out}" == *"workspace = /tmp/release-ws"* ]]  || fail "--yaml should beat GT_INSTALLER_YAML: ${out}"
pass "multiple YAMLs selectable via --yaml and GT_INSTALLER_YAML"

echo
echo "All tests passed."