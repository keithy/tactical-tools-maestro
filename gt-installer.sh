#!/usr/bin/env bash
# gt-installer.sh — bash port of feenkcom/gtoolkit-maestro-rs `gt-installer`.
#
# Default subcommand is `local-build` (matching the Rust binary and the
# shipped scripts/installer.sh), e.g.
#   curl -LsS https://.../installer.sh | bash
#
# Requires: bash 4+, curl, unzip, awk, sed, grep, jq (used for the few places
# we need structured parsing; falls back to sed/grep when missing).

set -Eeuo pipefail

# ---------- Paths & constants ---------------------------------------------
GT_INSTALLER_VERSION="0.1.0"
GT_INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Pick the best available awk / sed. GNU tools are preferred when present
# (gawk's `match()` with capture array and gsub's `\\1` back-references make
# the duration parser cleaner), but we fall back to whatever the platform
# ships so stock macOS / Alpine still work.
if [[ -x "${GT_INSTALLER_AWK:-}" ]]; then
    AWK="${GT_INSTALLER_AWK}"
elif command -v gawk >/dev/null 2>&1; then
    AWK="$(command -v gawk)"
else
    AWK="$(command -v awk)"
fi
if [[ -x "${GT_INSTALLER_SED:-}" ]]; then
    SED="${GT_INSTALLER_SED}"
elif command -v gsed >/dev/null 2>&1; then
    SED="$(command -v gsed)"
else
    SED="$(command -v sed)"
fi
# GNU sed supports `-E` for extended regex; BSD sed also does on macOS.
# We use `-E` everywhere for portability across modern platforms.

# Embedded Smalltalk assets (mirrors src/st/*.st in the Rust crate).
GT_INSTALLER_ST_DIR="${GT_INSTALLER_DIR}/st"
GT_INSTALLER_LOAD_PATCHES_ST="${GT_INSTALLER_ST_DIR}/load-patches.st"
GT_INSTALLER_CLONE_GT_TEMPLATE="${GT_INSTALLER_ST_DIR}/clone-gt.st.template"
GT_INSTALLER_LOAD_GT_TEMPLATE="${GT_INSTALLER_ST_DIR}/load-gt.st.template"

# Defaults (kept identical to the Rust constants in src/main.rs).
DEFAULT_IMAGE_NAME="GlamorousToolkit"
DEFAULT_IMAGE_EXTENSION="image"
DEFAULT_PHARO_IMAGE="https://dl.feenk.com/pharo/Pharo12.0-SNAPSHOT.build.1596.sha.e35513ca60.arch.64bit.zip"
SERIALIZATION_FILE="gtoolkit.yaml"
GTOOLKIT_REPOSITORY_OWNER="feenkcom"
GTOOLKIT_REPOSITORY_NAME="gtoolkit"
VM_REPOSITORY_OWNER="feenkcom"
VM_REPOSITORY_NAME="gtoolkit-vm"
VM_PRO_REPOSITORY_NAME="gtoolkit-vm-pro"
FEENK_DOWNLOAD_AUTH_SERVER_URL="https://dl-auth.feenk.com"
FEENK_CUSTOMER_ID_ENV="FEENK_CUSTOMER_ID"
FEENK_CUSTOMER_KEY_ENV="FEENK_CUSTOMER_KEY"

DEFAULT_WORKSPACE="glamoroustoolkit"
DEFAULT_DELAY="5 seconds"
DEFAULT_APPLICATION_STARTER="GtWorld openDefault"

# ---------- Logging helpers -----------------------------------------------
# Matches the Emoji constants in src/tools/mod.rs.
CHECKING="🔍 "
DOWNLOADING="📥 "
EXTRACTING="📦 "
MOVING="🚚 "
CREATING="📝 "
BUILDING="🔨 "
SPARKLE="✨ "

VERBOSE=0
NO_COLOR=0

_log() {
    local level="$1"; shift
    local color=""
    if [[ "${NO_COLOR}" -eq 0 && -t 1 ]]; then
        case "${level}" in
            info)  color="\033[1;34m" ;;
            warn)  color="\033[1;33m" ;;
            error) color="\033[1;31m" ;;
            *)     color="\033[0m" ;;
        esac
    fi
    printf "${color}%s\033[0m\n" "$*" >&2
}

info() { _log info "$*"; }
warn() { _log warn "$*"; }
error() { _log error "error: $*" >&2; }
die()  { error "$*"; exit 1; }

# ---------- Version parsing ----------------------------------------------
# `compare_versions a b` -> prints -1, 0, 1 (a < b, ==, >).
compare_versions() {
    awk -v a="$1" -v b="$2" '
        function split_ver(s,   parts, n, i) {
            n = split(s, parts, ".")
            for (i = 1; i <= n; i++) parts[i] = parts[i] + 0
            return n
        }
        BEGIN {
            na = split_ver(a, A); nb = split_ver(b, B)
            for (i = 1; i <= (na > nb ? na : nb); i++) {
                ai = (i in A) ? A[i] : 0
                bi = (i in B) ? B[i] : 0
                if (ai < bi) { print -1; exit }
                if (ai > bi) { print  1; exit }
            }
            print 0
        }
    '
}

# ---------- Tiny JSON helpers (no jq dependency) -------------------------
# Best-effort JSON helpers used only for parsing GitHub release responses.
_json_str() { "${SED}" -E 's/.*"[^"]+": *"([^"]*)".*/\1/'; }
_json_int() { "${SED}" -E 's/.*"[^"]+": *([0-9]+).*/\1/'; }

github_latest_release_tag() {
    local owner="$1" repo="$2"
    local url="https://api.github.com/repos/${owner}/${repo}/releases/latest"
    local body
    if ! body="$(curl -fsSL -H 'Accept: application/vnd.github+json' "${url}")"; then
        return 1
    fi
    # Strip leading 'v' so callers can prefix it themselves.
    printf '%s' "${body}" | grep -oE '"tag_name":\s*"v?[^"]+"' | head -n1 \
        | "${SED}" -E 's/.*"v?([^"]+)".*/\1/'
}

github_release_asset_url() {
    local owner="$1" repo="$2" tag="$3" asset_name="$4"
    local url="https://api.github.com/repos/${owner}/${repo}/releases/tags/${tag}"
    curl -fsSL -H 'Accept: application/vnd.github+json' "${url}" \
        | grep -oE "\"browser_download_url\":\\s*\"[^\"]*${asset_name}\"" \
        | head -n1 \
        | "${SED}" -E 's/.*"(https:[^"]+)".*/\1/'
}

# Some GitHub endpoints reject unauthenticated requests with rate limiting.
# When the API call fails (network, rate-limit) we expose a clear error
# pointing users to set GITHUB_TOKEN.
github_require_token() {
    if [[ -z "${GITHUB_TOKEN:-}" ]]; then
        die "GitHub API request failed. Set GITHUB_TOKEN to increase rate limit, or retry later."
    fi
}

# ---------- Host platform detection --------------------------------------
detect_platform() {
    local os arch translated=""
    case "$(uname -s)" in
        Linux)  os="linux" ;;
        Darwin) os="macos" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *) die "unsupported OS: $(uname -s)" ;;
    esac

    arch="$(uname -m)"
    case "${arch}" in
        x86_64|amd64)
            arch="x86_64"
            # Detect Apple Rosetta (x86_64 process running on Apple Silicon).
            if [[ "${os}" == "macos" ]] && command -v sysctl >/dev/null 2>&1; then
                if [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 1)" == "1" ]]; then
                    arch="aarch64"
                fi
            fi
            ;;
        arm64|aarch64) arch="aarch64" ;;
        *) die "unsupported architecture: ${arch}" ;;
    esac

    case "${os}-${arch}" in
        macos-x86_64)    PLATFORM_OS="MacOSX8664" ;    PLATFORM_TRIPLE="x86_64-apple-darwin" ;;
        macos-aarch64)   PLATFORM_OS="MacOSAarch64" ;   PLATFORM_TRIPLE="aarch64-apple-darwin" ;;
        linux-x86_64)    PLATFORM_OS="LinuxX8664" ;     PLATFORM_TRIPLE="x86_64-unknown-linux-gnu" ;;
        linux-aarch64)   PLATFORM_OS="LinuxAarch64" ;   PLATFORM_TRIPLE="aarch64-unknown-linux-gnu" ;;
        windows-x86_64)  PLATFORM_OS="WindowsX8664" ;   PLATFORM_TRIPLE="x86_64-pc-windows-msvc" ;;
        windows-aarch64) PLATFORM_OS="WindowsAarch64" ; PLATFORM_TRIPLE="aarch64-pc-windows-msvc" ;;
        *) die "unsupported platform: ${os}-${arch}" ;;
    esac
}

# ---------- Workspace helpers ---------------------------------------------
absolute_path() {
    local p="$1"
    if [[ -d "${p}" ]]; then
        (cd "${p}" && pwd)
    elif [[ -e "${p}" ]]; then
        local dir base
        dir="$(dirname "${p}")"; base="$(basename "${p}")"
        printf "%s/%s\n" "$(cd "${dir}" && pwd)" "${base}"
    else
        printf "%s\n" "${p}"
    fi
}

normalize_workspace() {
    local ws="$1"
    if [[ "${ws}" = /* ]] || [[ "${ws}" =~ ^[a-zA-Z]:[\\/] ]]; then
        printf "%s\n" "${ws}"
    else
        absolute_path "$(pwd)/${ws}"
    fi
}

# ---------- Serialization (gtoolkit.yaml) ---------------------------------
# We use the YAML subset that Application actually writes (see src/application.rs).
yaml_escape() { printf "%s" "$1" | "${SED}" -E 's/"/\\"/g'; }

read_yaml_field() {
    local file="$1" key="$2"
    [[ -f "${file}" ]] || return 1
    sed -nE "s/^[[:space:]]*${key}:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "${file}" | head -n1
}

write_application_yaml() {
    local out="$1" image_name="$2" image_ext="$3"
    local image_v="$4" app_v="$5" seed_kind="$6" seed_value="$7" workspace="$8"
    local verbose_v="${9:-false}"
    local cli_bin="${10:-}"
    # Always strip the leading 'v' on write so the YAML stays canonical,
    # matching how the Rust binary stores Version values.
    app_v="${app_v#v}"
    image_v="${image_v#v}"
    {
        echo "verbose: ${verbose_v}"
        echo "workspace: \"${workspace}\""
        echo "app_version: \"${app_v}\""
        if [[ -n "${cli_bin}" ]]; then
            echo "app_cli_binary: \"${cli_bin}\""
        else
            echo "app_cli_binary: "
        fi
        echo "image_version: \"${image_v}\""
        echo "image_name: \"${image_name}\""
        echo "image_extension: \"${image_ext}\""
        echo "image_seed:"
        case "${seed_kind}" in
            url)  echo "  Url: \"${seed_value}\"" ;;
            zip)  echo "  Zip: \"${seed_value}\"" ;;
            image) echo "  Image: \"${seed_value}\"" ;;
        esac
    } > "${out}"
}

# ---------- Application object (mirrors src/application.rs) ----------------
# This holds runtime state for the current invocation. Mirrors the `Application`
# struct in Rust but kept as plain shell variables plus an associative array
# for the workspace.
declare -A APP

app_workspace() { printf "%s" "${APP[workspace]:-$(pwd)}"; }
app_image_name() { printf "%s" "${APP[image_name]:-${DEFAULT_IMAGE_NAME}}"; }
app_image_ext()  { printf "%s" "${APP[image_ext]:-${DEFAULT_IMAGE_EXTENSION}}"; }
app_image_path() { printf "%s/%s.%s" "$(app_workspace)" "$(app_image_name)" "$(app_image_ext)"; }
app_image_version() { printf "%s" "${APP[image_version]:-}"; }
app_app_version()   { printf "%s" "${APP[app_version]:-}"; }
app_seed_kind()     { printf "%s" "${APP[seed_kind]:-url}"; }
app_seed_value()    { printf "%s" "${APP[seed_value]:-${DEFAULT_PHARO_IMAGE}}"; }

app_cli_path() {
    if [[ -n "${APP[app_cli_binary]:-}" ]]; then
        printf "%s" "${APP[app_cli_binary]}"
        return
    fi
    local loc; loc="$(app_workspace)"
    case "${PLATFORM_OS}" in
        MacOSX8664|MacOSAarch64)
            printf "%s/GlamorousToolkit.app/Contents/MacOS/GlamorousToolkit-cli" "${loc}" ;;
        WindowsX8664|WindowsAarch64)
            printf "%s/bin/GlamorousToolkit-cli.exe" "${loc}" ;;
        LinuxX8664|LinuxAarch64)
            printf "%s/bin/GlamorousToolkit-cli" "${loc}" ;;
        *)
            die "no CLI binary path for platform ${PLATFORM_OS}" ;;
    esac
}

app_gui_path() {
    local loc; loc="$(app_workspace)"
    case "${PLATFORM_OS}" in
        MacOSX8664|MacOSAarch64)
            printf "%s/GlamorousToolkit.app/Contents/MacOS/GlamorousToolkit" "${loc}" ;;
        WindowsX8664|WindowsAarch64)
            printf "%s/bin/GlamorousToolkit.exe" "${loc}" ;;
        LinuxX8664|LinuxAarch64)
            printf "%s/bin/GlamorousToolkit" "${loc}" ;;
    esac
}

app_gtoolkit_app_location_for_target() {
    local target="$1"
    if [[ "${target}" == "${PLATFORM_OS}" ]]; then
        app_workspace
    else
        printf "%s/%s" "$(app_workspace)" "${target}"
    fi
}

# ---------- Seed handling -------------------------------------------------
seed_image_directory() {
    local kind="$1" value="$2" workspace="$3"
    case "${kind}" in
        image)
            local dir; dir="$(dirname "${value}")"
            absolute_path "${dir}"
            ;;
        *)
            printf "%s/seed-image\n" "${workspace}"
            ;;
    esac
}

seed_target_image_directory() {
    local kind="$1" value="$2" workspace="$3"
    case "${kind}" in
        image) seed_image_directory "${kind}" "${value}" "${workspace}" ;;
        *)     printf "%s\n" "${workspace}" ;;
    esac
}

# ---------- Download / extract helpers ------------------------------------
download_to() {
    local url="$1" dest="$2"
    info "${DOWNLOADING}Downloading ${url}"
    mkdir -p "$(dirname "${dest}")"
    curl -fL --retry 3 -o "${dest}" "${url}" || die "failed to download ${url}"
}

unzip_into() {
    local zip="$1" dest="$2"
    info "${EXTRACTING}Extracting ${zip}"
    mkdir -p "${dest}"
    # Use -o to overwrite (matches the Rust unzipper default). -q keeps output tidy.
    unzip -oq "${zip}" -d "${dest}" || die "failed to unzip ${zip}"
}

move_file_to() {
    local src="$1" dest_dir="$2"
    [[ -e "${src}" ]] || die "move_file_to: missing source ${src}"
    mkdir -p "${dest_dir}"
    mv "${src}" "${dest_dir}/"
}

# ---------- Pro VM credentials -------------------------------------------
should_download_pro_vm() {
    local level="${1:-auto}"
    local has_creds=0
    if [[ -n "${!FEENK_CUSTOMER_ID_ENV:-}" && -n "${!FEENK_CUSTOMER_KEY_ENV:-}" ]]; then
        has_creds=1
    elif [[ -n "${FEENK_CUSTOMER_ID:-}" && -n "${FEENK_CUSTOMER_KEY:-}" ]]; then
        has_creds=1
    fi
    case "${level}" in
        auto)   [[ "${has_creds}" -eq 1 ]] && echo true || echo false ;;
        regular) echo false ;;
        pro)
            [[ "${has_creds}" -eq 1 ]] || die "FEENK_CUSTOMER_ID and FEENK_CUSTOMER_KEY must be set when --customer-level pro is used"
            echo true
            ;;
        *) die "unknown customer level: ${level}" ;;
    esac
}

# ---------- VM download (regular + pro) -----------------------------------
gtoolkit_app_url_for_target() {
    local target="$1" version="$2"
    local file
    case "${target}" in
        MacOSX8664)    file="GlamorousToolkit-x86_64-apple-darwin.app.zip" ;;
        MacOSAarch64)  file="GlamorousToolkit-aarch64-apple-darwin.app.zip" ;;
        WindowsX8664)  file="GlamorousToolkit-x86_64-pc-windows-msvc.zip" ;;
        WindowsAarch64) file="GlamorousToolkit-aarch64-pc-windows-msvc.zip" ;;
        LinuxX8664)    file="GlamorousToolkit-x86_64-unknown-linux-gnu.zip" ;;
        LinuxAarch64)  file="GlamorousToolkit-aarch64-unknown-linux-gnu.zip" ;;
        AndroidAarch64) file="GlamorousToolkit-aarch64-linux-android.apk" ;;
        *) die "unknown target ${target}" ;;
    esac
    printf "https://github.com/%s/%s/releases/download/v%s/%s" \
        "${VM_REPOSITORY_OWNER}" "${VM_REPOSITORY_NAME}" "${version}" "${file}"
}

gtoolkit_pro_app_url_for_target() {
    local target="$1" version="$2"
    local file
    case "${target}" in
        MacOSX8664)    file="GlamorousToolkit-x86_64-apple-darwin-pro.app.zip" ;;
        MacOSAarch64)  file="GlamorousToolkit-aarch64-apple-darwin-pro.app.zip" ;;
        WindowsX8664)  file="GlamorousToolkit-x86_64-pc-windows-msvc-pro.zip" ;;
        WindowsAarch64) file="GlamorousToolkit-aarch64-pc-windows-msvc-pro.zip" ;;
        LinuxX8664)    file="GlamorousToolkit-x86_64-unknown-linux-gnu-pro.zip" ;;
        LinuxAarch64)  file="GlamorousToolkit-aarch64-unknown-linux-gnu-pro.zip" ;;
        AndroidAarch64) file="GlamorousToolkit-aarch64-linux-android-pro.apk" ;;
        *) die "unknown target ${target}" ;;
    esac
    printf "https://github.com/%s/%s/releases/download/v%s/%s" \
        "${VM_REPOSITORY_OWNER}" "${VM_PRO_REPOSITORY_NAME}" "${version}" "${file}"
}

gtoolkit_app_file_name_for_target() {
    local target="$1"
    case "${target}" in
        MacOSX8664)    echo "GlamorousToolkit-x86_64-apple-darwin.app.zip" ;;
        MacOSAarch64)  echo "GlamorousToolkit-aarch64-apple-darwin.app.zip" ;;
        WindowsX8664)  echo "GlamorousToolkit-x86_64-pc-windows-msvc.zip" ;;
        WindowsAarch64) echo "GlamorousToolkit-aarch64-pc-windows-msvc.zip" ;;
        LinuxX8664)    echo "GlamorousToolkit-x86_64-unknown-linux-gnu.zip" ;;
        LinuxAarch64)  echo "GlamorousToolkit-aarch64-unknown-linux-gnu.zip" ;;
        AndroidAarch64) echo "GlamorousToolkit-aarch64-linux-android.apk" ;;
    esac
}

download_glamorous_toolkit_vm() {
    local target="${1:-${PLATFORM_OS}}" customer_level="${2:-auto}"
    if [[ -n "${APP[app_cli_binary]:-}" ]]; then
        # Explicit CLI binary override — skip VM download entirely.
        return 0
    fi

    local version; version="$(app_app_version)"
    [[ -n "${version}" ]] || die "application version not resolved"

    local dest_dir; dest_dir="$(app_gtoolkit_app_location_for_target "${target}")"
    local ext="zip"
    [[ "${target}" == "AndroidAarch64" ]] && ext="apk"
    local vm_file="GlamorousToolkitApp-v${version}.${ext}"

    info "${DOWNLOADING}Downloading GlamorousToolkit App (v${version}, ${target})"

    if [[ "$(should_download_pro_vm "${customer_level}")" == "true" ]]; then
        download_to "$(gtoolkit_pro_app_url_for_target "${target}" "${version}")" \
            "${dest_dir}/${vm_file}"
    else
        download_to "$(gtoolkit_app_url_for_target "${target}" "${version}")" \
            "${dest_dir}/${vm_file}"
    fi

    unzip_into "${dest_dir}/${vm_file}" "${dest_dir}"
    rm -f "${dest_dir}/${vm_file}"
}

# ---------- Smalltalk evaluation -----------------------------------------
# Mirrors src/smalltalk/evaluator.rs + smalltalk.rs. No flag means headless
# mode (the local GlamorousToolkit CLI runs headless by default and
# rejects --headless as an unknown argument; the only valid head/UI
# switch is --interactive, which we use when a UI is actually wanted).

smalltalk_command() {
    local mode="${1:-st}"; shift || true
    local cli; cli="$(app_cli_path)"
    local workspace; workspace="$(app_workspace)"
    [[ -x "${cli}" ]] || die "gtoolkit CLI not found at ${cli}; run download or build first"

    local -a cmd=("$(cd "${workspace}" && pwd -P)/$(basename "${cli}")")
    case "${PLATFORM_OS}" in
        MacOSX8664|MacOSAarch64)
            # CLI binary lives inside the .app bundle; invoke via absolute path.
            cmd=("${cli}") ;;
    esac

    # No flag by default means headless mode, which is correct for most
    # installer steps. Callers that want a UI pass --interactive
    # explicitly (via the smalltalk_command wrapper, or by setting
    # GT_INSTALLER_SMALLTALK_FLAGS=--interactive).
    local flags="${GT_INSTALLER_SMALLTALK_FLAGS:-}"
    # shellcheck disable=SC2206
    local flag_arr=( ${flags} )

    if [[ "${mode}" == "st" ]]; then
        # Run a script file:   <cli> [--interactive] <image> st [--quit|--no-quit] [--save] [--interactive] <script>
        local quit_flag="--quit"
        local save_flag=""
        local interactive_flag=""
        while (( $# )); do
            case "$1" in
                --quit)     quit_flag="--quit" ;;
                --no-quit)  quit_flag="--no-quit" ;;
                --save)     save_flag="--save" ;;
                --interactive) interactive_flag="--interactive" ;;
                *) break ;;
            esac
            shift
        done
        "${cmd[@]}" "${flag_arr[@]}" "$(app_image_path)" st "${quit_flag}" ${save_flag} ${interactive_flag} "$@"
    else
        # Eval mode: <cli> [--interactive] <image> eval [--no-quit] <expression>
        local quit_flag=""
        while (( $# )); do
            case "$1" in
                --no-quit) quit_flag="--no-quit" ;;
                *) break ;;
            esac
            shift
        done
        local expr="$1"
        if [[ "${quit_flag}" == "--no-quit" ]]; then
            "${cmd[@]}" "${flag_arr[@]}" "$(app_image_path)" eval --no-quit "${expr}"
        else
            "${cmd[@]}" "${flag_arr[@]}" "$(app_image_path)" eval "${expr}"
        fi
    fi
}

smalltalk_eval() {
    local expr="$1"; shift
    local save_flag=""
    while (( $# )); do
        case "$1" in
            save=true)    save_flag="1" ;;
            save=false)   save_flag="" ;;
            *) die "unknown smalltalk_eval option: $1" ;;
        esac
        shift
    done
    if [[ "${save_flag}" == "1" ]]; then
        # Save the image and quit the VM so the install step completes.
        # Earlier versions chained `andQuit: false` here, which left the
        # VM hanging waiting for stdin and the installer hung forever.
        smalltalk_command eval --no-quit "${expr}.Smalltalk snapshot: true andQuit: true"
    else
        smalltalk_command eval --no-quit "${expr}"
    fi
}

smalltalk_run_script() {
    local script="$1"; shift
    local save_flag=""
    while (( $# )); do
        case "$1" in
            save=true)  save_flag="--save" ;;
            save=false) save_flag="" ;;
            *) die "unknown smalltalk_run_script option: $1" ;;
        esac
        shift
    done
    smalltalk_command st --quit ${save_flag} "${script}"
}

# ---------- Loader template rendering ------------------------------------
# Substitutes {{gtoolkit_version}} and {{releaser_version}} placeholders that
# the Rust mustache::compile_str / render_to_string calls produce.

render_template() {
    local template_file="$1" out_file="$2" gtv="$3" relv="$4"
    "${SED}" -E -e "s/\{\{gtoolkit_version\}\}/${gtv}/g" \
            -e "s/\{\{releaser_version\}\}/${relv}/g" \
            "${template_file}" > "${out_file}"
}

resolve_loader_version_info() {
    local version_spec="$1"
    local gtv relv
    case "${version_spec}" in
        bleeding-edge)
            gtv="main"; relv="main" ;;
        latest-release)
            local v; v="$(github_latest_release_tag "${GTOOLKIT_REPOSITORY_OWNER}" "${GTOOLKIT_REPOSITORY_NAME}")" \
                || { github_require_token; die "failed to fetch latest gtoolkit release"; }
            gtv="v${v}"
            local url="https://raw.githubusercontent.com/${GTOOLKIT_REPOSITORY_OWNER}/${GTOOLKIT_REPOSITORY_NAME}/${gtv}/gtoolkit-releaser.version"
            local body; body="$(curl -fsSL "${url}" || true)"
            if [[ -z "${body}" ]]; then
                warn "could not fetch ${url}; falling back to main"
                relv="main"
            else
                relv="v$(printf '%s' "${body}" | tr -d '[:space:]')"
            fi
            ;;
        v*)
            gtv="${version_spec}"
            local url="https://raw.githubusercontent.com/${GTOOLKIT_REPOSITORY_OWNER}/${GTOOLKIT_REPOSITORY_NAME}/${gtv}/gtoolkit-releaser.version"
            local body; body="$(curl -fsSL "${url}" || true)"
            if [[ -z "${body}" ]]; then
                warn "could not fetch ${url}; falling back to main"
                relv="main"
            else
                relv="v$(printf '%s' "${body}" | tr -d '[:space:]')"
            fi
            ;;
        *)
            die "invalid --version: ${version_spec} (expected bleeding-edge, latest-release, or vX.Y.Z)" ;;
    esac
    printf "%s\n%s\n" "${gtv}" "${relv}"
}

# ---------- Subcommand implementations -----------------------------------
# Each corresponds 1:1 to a SubCommand variant in src/options.rs.

subcommand_build() {
    # Parse build options (parity with BuildOptions in src/tools/builder.rs).
    local overwrite=0 loader="cloner" image_url="" image_zip="" image_file=""
    local iceberg_location="${GT_INSTALLER_ICEBERG_LOCATION:-}" public_key="" private_key=""
    local version="bleeding-edge" app_version="latest-release" customer_level="auto"

    while (( $# )); do
        case "$1" in
            --overwrite) overwrite=1 ;;
            --loader) loader="$2"; shift ;;
            --image-url) image_url="$2"; shift ;;
            --image-zip) image_zip="$2"; shift ;;
            --image-file) image_file="$2"; shift ;;
            --iceberg-location) iceberg_location="$2"; shift ;;
            --public-key) public_key="$2"; shift ;;
            --private-key) private_key="$2"; shift ;;
            --version) version="$2"; shift ;;
            --app-version) app_version="$2"; shift ;;
            --customer-level) customer_level="$2"; shift ;;
            --) shift; break ;;
            -*) die "unknown build option: $1" ;;
            *) break ;;
        esac
        shift
    done

    # Resolve iceberg_location with priority: CLI flag > env var > YAML.
    if [[ -z "${iceberg_location}" ]]; then
        local yaml_ice
        yaml_ice="$(read_yaml_field "$(app_workspace)/${SERIALIZATION_FILE}" iceberg_location 2>/dev/null || true)"
        if [[ -n "${yaml_ice}" ]]; then
            iceberg_location="${yaml_ice}"
        fi
    fi

    local workspace; workspace="$(app_workspace)"
    info "${CHECKING}Checking the system..."

    # Snapshot the seed currently held in the APP state (loaded from YAML by
    # main()). A user re-running after editing gtoolkit.yaml will have their
    # custom image_seed respected, unless they explicitly pass one of the
    # --image-{file,zip,url} flags to override.
    local saved_seed_kind="${APP[seed_kind]:-}"
    local saved_seed_value="${APP[seed_value]:-}"
    local saved_image_name="${APP[image_name]:-}"
    local saved_image_ext="${APP[image_ext]:-}"

    # Seed selection (mutually exclusive).
    if [[ -n "${image_file}" ]]; then
        APP[seed_kind]="image"
        APP[seed_value]="${image_file}"
        # Recompute workspace/image name from the image file path.
        local abs; abs="$(absolute_path "${image_file}")"
        local dir; dir="$(dirname "${abs}")"
        local base; base="$(basename "${abs}")"
        APP[workspace]="${dir}"
        APP[image_name]="${base%.*}"
        APP[image_ext]="${base##*.}"
        workspace="${dir}"
    elif [[ -n "${image_zip}" ]]; then
        APP[seed_kind]="zip"; APP[seed_value]="${image_zip}"
    elif [[ -n "${image_url}" ]]; then
        APP[seed_kind]="url"; APP[seed_value]="${image_url}"
    elif [[ -z "${saved_seed_kind}" ]]; then
        # No persisted YAML and no CLI override — fall back to the default seed.
        APP[seed_kind]="url"; APP[seed_value]="${DEFAULT_PHARO_IMAGE}"
    fi
    # else: preserve whatever was loaded from gtoolkit.yaml.

    # Resolve explicit app version override.
    if [[ "${app_version}" != "latest-release" ]]; then
        APP[app_version]="${app_version#v}"
    fi

    if [[ "${overwrite}" -eq 1 && -d "${workspace}" ]]; then
        rm -rf "${workspace}"
    fi
    if [[ -d "${workspace}" ]]; then
        # Don't bail immediately — surface what's already there so the user can
        # decide between passing --overwrite, editing gtoolkit.yaml, or running
        # a different subcommand (download / setup / start / test / etc).
        info "${CHECKING}Workspace already exists: ${workspace}"
        if [[ -f "${workspace}/${SERIALIZATION_FILE}" ]]; then
            info "Current ${SERIALIZATION_FILE}:"
            # Indent so it stands out from surrounding log lines.
            "${SED}" 's/^/    /' "${workspace}/${SERIALIZATION_FILE}" >&2 || true
        else
            info "  (no ${SERIALIZATION_FILE} found in workspace)"
        fi
        die "refusing to overwrite. Pass --overwrite to delete and rebuild, or run a non-build subcommand (download, setup, start, test, ...) against this workspace."
    fi
    mkdir -p "${workspace}"

    info "${DOWNLOADING}Downloading files..."
    local seed_dir; seed_dir="$(seed_image_directory "${APP[seed_kind]}" "${APP[seed_value]}" "${workspace}")"

    # Download VM unless the user supplied an explicit CLI binary.
    download_glamorous_toolkit_vm "${PLATFORM_OS}" "${customer_level}"

    # Download the seed image (or skip for Image seeds).
    case "${APP[seed_kind]}" in
        url)
            download_to "${APP[seed_value]}" "${workspace}/seed-image.zip" ;;
        zip)
            cp "${APP[seed_value]}" "${workspace}/seed-image.zip" ;;
        image) : ;;
    esac

    info "${EXTRACTING}Extracting files..."
    case "${APP[seed_kind]}" in
        url|zip)
            mkdir -p "${seed_dir}"
            unzip_into "${workspace}/seed-image.zip" "${seed_dir}" ;;
        image) : ;;
    esac

    if [[ "${APP[seed_kind]}" != "image" ]]; then
        info "${MOVING}Moving files..."
        # Locate the .image inside the seed dir and rename it to the workspace.
        local seed_image; seed_image="$(find "${seed_dir}" -maxdepth 2 -name "*.${APP[image_ext]}" | head -n1 || true)"
        [[ -n "${seed_image}" ]] || die "no seed image found in ${seed_dir}"
        # Save into the workspace under the chosen image name.
        smalltalk_command eval --no-quit "Smalltalk saveSession." >/dev/null 2>&1 || true
        # The Pharo CLI exposes `save <name>`; using the seed CLI is identical to
        # the Rust binary which calls `SmalltalkCommand::new("save")`.
        local cli_bin
        cli_bin="$(app_cli_path)"
        # Save the seed image into the workspace. The local GlamorousToolkit
        # CLI runs headless by default (no flag) and rejects --headless as
        # an unknown argument; --interactive would open a UI which we don't
        # want. So: no flag at all.
        ( cd "${seed_dir}" && "${cli_bin}" "$(basename "${seed_image}")" \
            save "${workspace}/$(app_image_name)" ) \
            || die "failed to save seed image into workspace"

        # Move the .sources file alongside the image (matches FileToMove for *.sources).
        local sources; sources="$(find "${seed_dir}" -maxdepth 2 -name "*.sources" | head -n1 || true)"
        if [[ -n "${sources}" ]]; then
            mv "${sources}" "${workspace}/"
        fi
        rm -rf "${workspace}/seed-image" "${workspace}/seed-image.zip"
    fi

    # Render the loader scripts.
    info "${CREATING}Creating build scripts..."
    local gtv relv
    # resolve_loader_version_info prints two values, one per line. We
    # can't use a single `read gtv relv` because read treats newlines as
    # ordinary whitespace and merges the two lines into a single
    # space-separated value. Use a temp array instead.
    local gtv_relv
    mapfile -t gtv_relv < <(resolve_loader_version_info "${version}")
    gtv="${gtv_relv[0]:-}"
    relv="${gtv_relv[1]:-}"

    cp "${GT_INSTALLER_LOAD_PATCHES_ST}" "${workspace}/load-patches.st"
    local loader_script="load-gt-${gtv}.st"
    local template
    case "${loader}" in
        cloner)   template="${GT_INSTALLER_CLONE_GT_TEMPLATE}" ;;
        metacello) template="${GT_INSTALLER_LOAD_GT_TEMPLATE}" ;;
        *) die "unknown loader: ${loader}" ;;
    esac
    render_template "${template}" "${workspace}/${loader_script}" "${gtv}" "${relv}"

    info "${BUILDING}Preparing the image..."
    smalltalk_run_script "${workspace}/load-patches.st" save=true

    info "${BUILDING}Building Glamorous Toolkit..."

    # SSH key configuration (matches BuildOptions::ssh_keys in Rust).
    local pub="" priv=""
    if [[ -n "${public_key}" || -n "${private_key}" ]]; then
        if [[ -z "${public_key}" || -z "${private_key}" ]]; then
            die "Both --public-key and --private-key must be set, or neither"
        fi
        [[ -e "${public_key}" ]]  || die "public key does not exist: ${public_key}"
        [[ -e "${private_key}" ]] || die "private key does not exist: ${private_key}"
        pub="$(absolute_path "${public_key}")"
        priv="$(absolute_path "${private_key}")"
        smalltalk_eval \
            "IceCredentialsProvider useCustomSsh: true.IceCredentialsProvider sshCredentials publicKey: '${pub}'; privateKey: '${priv}'" \
            save=true >/dev/null
    fi

    if [[ -n "${iceberg_location}" ]]; then
        local abs_ice; abs_ice="$(absolute_path "${iceberg_location}")"
        smalltalk_eval \
            "IceLibgitRepository sharedRepositoriesLocationString: '${abs_ice}'.IceLibgitRepository shareRepositoriesBetweenImages: true" \
            save=true >/dev/null
    fi

    smalltalk_run_script "${workspace}/${loader_script}" save=true

    info "${SPARKLE}Done"
}

subcommand_download() {
    # Download subcommand. The Rust version accepts `vm` as a sub-subcommand;
    # for now we treat any positional argument as a target. When no argument
    # is given we default to `vm` (the only target the Rust binary exposes).
    local target="${1:-vm}"
    case "${target}" in
        vm)
            shift || true
            local level="auto"
            while (( $# )); do
                case "$1" in
                    --customer-level) level="$2"; shift ;;
                    *) die "unknown download vm option: $1" ;;
                esac
                shift
            done
            download_glamorous_toolkit_vm "${PLATFORM_OS}" "${level}" ;;
        *) die "unknown download target: ${target}" ;;
    esac
}

subcommand_setup() {
    local no_gt_world=0 target="local-build" bump="patch"
    while (( $# )); do
        case "$1" in
            --no-gt-world) no_gt_world=1 ;;
            --target) target="$2"; shift ;;
            --bump) bump="$2"; shift ;;
            --) shift; break ;;
            -*) die "unknown setup option: $1" ;;
            *) break ;;
        esac
        shift
    done

    case "${target}" in
        local-build)
            info "${CREATING}Setting up for local build..."
            smalltalk_eval "GtImageSetup performLocalSetup" save=true >/dev/null
            ;;
        release)
            info "${CREATING}Setting up for release..."
            smalltalk_eval "GtImageSetup performSetupForRelease: '${bump}'" save=true >/dev/null
            local v; v="$(smalltalk_command eval --no-quit "getgtoolkitversion" | tr -d '[:space:]')"
            APP[image_version]="${v#v}"
            smalltalk_command eval --no-quit "printNewCommits" >/dev/null || true
            ;;
        *) die "unknown setup target: ${target}" ;;
    esac

    if [[ "${no_gt_world}" -eq 0 ]]; then
        info "${BUILDING}Setting up GtWorld..."
        subcommand_start --expression "GtWorld openDefault" --delay "5 seconds" --no-save --no-quit
    fi

    info "To start GlamorousToolkit run:"
    info "  cd ${workspace:-$(app_workspace)}"
    info "  $(app_gui_path)"
}

subcommand_start() {
    local expression="${DEFAULT_APPLICATION_STARTER}" delay="${DEFAULT_DELAY}"
    local save=1 quit=1
    while (( $# )); do
        case "$1" in
            --expression) expression="$2"; shift ;;
            --delay) delay="$2"; shift ;;
            --no-save) save=0 ;;
            --no-quit) quit=0 ;;
            --) shift; break ;;
            *) break ;;
        esac
        shift
    done

    # parse_duration: accept "5 seconds", "5000 ms", "1m", "2h", etc.
    local millis
    millis="$(parse_duration_ms "${delay}")" || die "could not parse duration: ${delay}"

    local expr
    expr="${expression}.${millis} milliSeconds wait.BlHost pickHost universe snapshot: true andQuit: true"

    local -a cmd=()
    if [[ "${save}" -eq 1 ]]; then
        smalltalk_command eval --no-quit "${expr}"
    else
        smalltalk_command eval --no-quit "${expression}"
    fi
}

parse_duration_ms() {
    # Parse "<num><unit>" durations into milliseconds. Accepts both glued
    # forms ("5s", "2hours") and the more common "<num> <unit>" form
    # ("5 seconds", "2 hours"). Multiple durations separated by 1+ spaces
    # are summed (e.g. "2 hours 30 minutes" -> 9000000).
    #
    # Implementation note: BWK awk on stock macOS has no `switch` and its
    # gsub() does not honour `\\1` back-references, so the parser works in
    # two layers — a portable POSIX layer (used by default) and a tighter
    # GNU-only path that fires when AWK is gawk.
    local s="$1"
    if [[ "${AWK##*/}" == "gawk" || "${AWK}" == *"/gawk" ]]; then
        "${AWK}" -v s="${s}" '
            function step(num, unit,   mult, u) {
                u = tolower(unit)
                if (u == "ms" || u == "millisecond" || u == "milliseconds") mult = 1
                else if (u == "s" || u == "sec" || u == "second" || u == "seconds") mult = 1000
                else if (u == "m" || u == "min" || u == "minute" || u == "minutes") mult = 60 * 1000
                else if (u == "h" || u == "hour" || u == "hours") mult = 3600 * 1000
                else if (u == "d" || u == "day" || u == "days") mult = 86400 * 1000
                else { print "bad unit: " unit > "/dev/stderr"; exit 1 }
                return num * mult
            }
            BEGIN {
                # Collapse optional whitespace between a number and its unit.
                # Use gensub (gawk-only) since gsub does not honour backrefs.
                s = gensub(/([0-9])[ \t]+([a-zA-Z])/, "\\1\\2", "g", s)
                FS = "[ \t]+"
                n = split(s, parts)
                total = 0
                for (i = 1; i <= n; i++) {
                    p = parts[i]
                    if (p == "") continue
                    if (match(p, /^([0-9]+)([a-zA-Z]+)$/, m)) {
                        total += step(m[1] + 0, m[2])
                    } else {
                        print "bad token: " p > "/dev/stderr"; exit 1
                    }
                }
                print total
            }
        '
        return $?
    fi

    # Portable POSIX fallback (BWK awk).
    local prog
    prog="$(mktemp)"
    trap 'rm -f "${prog:-}"' RETURN
    s="$(printf '%s' "${s}" | "${SED}" -E 's/([0-9])[ \t]+([a-zA-Z])/\1\2/g')"
    cat > "${prog}" <<'EOF'
function step(num, unit,   mult, u) {
    u = tolower(unit)
    if (u == "ms" || u == "millisecond" || u == "milliseconds") mult = 1
    else if (u == "s" || u == "sec" || u == "second" || u == "seconds") mult = 1000
    else if (u == "m" || u == "min" || u == "minute" || u == "minutes") mult = 60 * 1000
    else if (u == "h" || u == "hour" || u == "hours") mult = 3600 * 1000
    else if (u == "d" || u == "day" || u == "days") mult = 86400 * 1000
    else { print "bad unit: " unit > "/dev/stderr"; exit 1 }
    return num * mult
}
BEGIN {
    FS = "[ \t]+"
    n = split(s, parts)
    total = 0
    for (i = 1; i <= n; i++) {
        p = parts[i]
        if (p == "") continue
        num = p
        sub(/[a-zA-Z]+$/, "", num)
        unit = p
        sub(/^[0-9]+/, "", unit)
        if (num == "" || num == p || unit == "") {
            print "bad token: " p > "/dev/stderr"; exit 1
        }
        total += step(num + 0, unit)
    }
    print total
}
EOF
    "${AWK}" -v s="${s}" -f "${prog}"
}

subcommand_cleanup() {
    info "${CREATING}Cleaning up image..."
    smalltalk_eval \
        "IceCredentialsProvider sshCredentials publicKey: ''; privateKey: ''.IceCredentialsProvider useCustomSsh: false.IceRepository registry removeAll.3 timesRepeat: [ Smalltalk garbageCollect ]" \
        save=true >/dev/null
}

subcommand_test() {
    local -a packages=() skip_packages=()
    local disable_deprecation_rewrites=0 disable_tests=0
    while (( $# )); do
        case "$1" in
            --packages) shift; while (( $# )) && [[ "$1" != -* ]]; do packages+=("$1"); shift; done ;;
            --skip-packages) shift; while (( $# )) && [[ "$1" != -* ]]; do skip_packages+=("$1"); shift; done ;;
            --disable-deprecation-rewrites) disable_deprecation_rewrites=1 ;;
            --disable-tests) disable_tests=1 ;;
            --) shift; break ;;
            *) break ;;
        esac
        shift
    done

    local verb_flag=""; [[ "${VERBOSE}" -eq 1 ]] && verb_flag="--verbose"
    local ddr_flag=""
    [[ "${disable_deprecation_rewrites}" -eq 1 ]] && ddr_flag="--disable-deprecation-rewrites"
    local skip_flag=""
    if (( ${#skip_packages[@]} > 0 )); then
        local joined; joined="$(IFS=,; echo "${skip_packages[*]}")"
        skip_flag="--skip-packages=\"${joined}\""
    fi

    if (( ${#packages[@]} > 0 )); then
        smalltalk_command eval --no-quit \
            "examples ${packages[*]} --junit-xml-output ${verb_flag} ${ddr_flag} ${skip_flag}" \
            >/dev/null
        if [[ "${disable_tests}" -eq 0 ]]; then
            smalltalk_command eval --no-quit \
                "test ${packages[*]} --junit-xml-output" >/dev/null
        fi
    else
        smalltalk_command eval --no-quit \
            "dedicatedReleaseBranchExamples --junit-xml-output ${verb_flag} ${ddr_flag} ${skip_flag}" \
            >/dev/null
        smalltalk_command eval --no-quit \
            "dedicatedReleaseBranchSlides --junit-xml-output ${verb_flag} ${ddr_flag} ${skip_flag}" \
            >/dev/null
        smalltalk_command eval --no-quit "gtexportreport --report=GtGtoolkitArchitecturalReport" >/dev/null
    fi
}

subcommand_copy_to() {
    local destination="${1:-${DEFAULT_WORKSPACE}}"
    local include_app=1
    shift || true
    while (( $# )); do
        case "$1" in
            --include-app) include_app=1 ;;
            --no-include-app) include_app=0 ;;
            *) die "unknown copy option: $1" ;;
        esac
        shift
    done

    local workspace; workspace="$(app_workspace)"
    destination="$(normalize_workspace "${destination}")"
    mkdir -p "${destination}"

    cp -p "${workspace}"/*.image        "${destination}/" 2>/dev/null || true
    cp -p "${workspace}"/*.changes      "${destination}/" 2>/dev/null || true
    cp -p "${workspace}"/*.sources      "${destination}/" 2>/dev/null || true
    cp -p "${workspace}/${SERIALIZATION_FILE}" "${destination}/" 2>/dev/null || true
    if [[ -d "${workspace}/gt-extra" ]]; then
        cp -R "${workspace}/gt-extra" "${destination}/"
    fi

    if [[ "${include_app}" -eq 1 ]]; then
        case "${PLATFORM_OS}" in
            MacOSX8664|MacOSAarch64)
                [[ -d "${workspace}/GlamorousToolkit.app" ]] && \
                    cp -R "${workspace}/GlamorousToolkit.app" "${destination}/" ;;
            WindowsX8664|WindowsAarch64)
                [[ -d "${workspace}/bin" ]] && cp -R "${workspace}/bin" "${destination}/" ;;
            LinuxX8664|LinuxAarch64)
                [[ -d "${workspace}/bin" ]] && cp -R "${workspace}/bin" "${destination}/"
                [[ -d "${workspace}/lib" ]] && cp -R "${workspace}/lib" "${destination}/" ;;
        esac
    fi

    APP[workspace]="${destination}"
    app_serialize
}

subcommand_rename_to() {
    local new_name="${1:?rename-to requires a new name}"
    shift
    local delete_old=1
    while (( $# )); do
        case "$1" in
            --no-delete-old) delete_old=0 ;;
            *) die "unknown rename option: $1" ;;
        esac
        shift
    done

    local workspace; workspace="$(app_workspace)"
    local old_image; old_image="$(app_image_path)"
    local old_changes="${old_image%.*}.changes"
    local new_image="${workspace}/${new_name}.image"

    local del_flag=""
    [[ "${delete_old}" -eq 1 ]] && del_flag="--delete-old"
    smalltalk_command eval --no-quit "save ${new_name} ${del_flag}" >/dev/null

    if [[ -e "${old_changes}" ]]; then
        rm -f "${old_changes}"
    fi

    APP[seed_kind]="image"
    APP[seed_value]="${new_image}"
    APP[image_name]="${new_name}"
    APP[image_ext]="image"
    app_serialize
}

subcommand_package_tentative() {
    local tentative="${1:?package-tentative requires an output path}"
    shift
    local ignore_absent=0
    while (( $# )); do
        case "$1" in
            --ignore-absent) ignore_absent=1 ;;
            *) die "unknown package option: $1" ;;
        esac
        shift
    done

    local workspace; workspace="$(app_workspace)"
    local tmp; tmp="$(mktemp -d)"
    cp -p "${workspace}"/*.image   "${tmp}/" 2>/dev/null || true
    cp -p "${workspace}"/*.changes "${tmp}/" 2>/dev/null || true
    cp -p "${workspace}"/*.sources "${tmp}/" 2>/dev/null || true
    cp -p "${workspace}/${SERIALIZATION_FILE}" "${tmp}/" 2>/dev/null || true
    if [[ -d "${workspace}/gt-extra" ]]; then
        cp -R "${workspace}/gt-extra" "${tmp}/"
    fi

    case "${PLATFORM_OS}" in
        MacOSX8664|MacOSAarch64)
            [[ -d "${workspace}/GlamorousToolkit.app" ]] && \
                cp -R "${workspace}/GlamorousToolkit.app" "${tmp}/" ;;
        WindowsX8664|WindowsAarch64)
            [[ -d "${workspace}/bin" ]] && cp -R "${workspace}/bin" "${tmp}/" ;;
        LinuxX8664|LinuxAarch64)
            [[ -d "${workspace}/bin" ]] && cp -R "${workspace}/bin" "${tmp}/"
            [[ -d "${workspace}/lib" ]] && cp -R "${workspace}/lib" "${tmp}/" ;;
    esac

    local parent="${workspace%/*}"
    if [[ -f "${parent}/scripts/docker/gtoolkit/Dockerfile" ]]; then
        mkdir -p "${tmp}/scripts/docker/gtoolkit"
        cp "${parent}/scripts/docker/gtoolkit/Dockerfile" "${tmp}/scripts/docker/gtoolkit/"
        if [[ -d "${parent}/scripts/docker/gtoolkit/docker-image" ]]; then
            cp -R "${parent}/scripts/docker/gtoolkit/docker-image" "${tmp}/scripts/docker/gtoolkit/"
        fi
    fi

    (cd "${tmp}" && zip -qr "${tentative}" .)
    rm -rf "${tmp}"
    printf "%s\n" "${tentative}"
}

subcommand_unpackage_tentative() {
    local tentative="${1:?unpackage-tentative requires an input path}"
    shift
    local ignore_absent=0
    while (( $# )); do
        case "$1" in
            --ignore-absent) ignore_absent=1 ;;
            *) die "unknown unpackage option: $1" ;;
        esac
        shift
    done
    local workspace; workspace="$(app_workspace)"
    mkdir -p "${workspace}"
    unzip_into "${tentative}" "${workspace}"
    app_load_from_yaml
    download_glamorous_toolkit_vm "${PLATFORM_OS}" "auto"
}

subcommand_package_release() {
    local release="${1:?package-release requires an output path template}"
    shift
    local target="${PLATFORM_OS}"
    while (( $# )); do
        case "$1" in
            --target) target="$2"; shift ;;
            *) die "unknown package-release option: $1" ;;
        esac
        shift
    done

    # Render {{version}}, {{os}}, {{arch}} placeholders.
    local os_part arch_part version_part
    case "${target}" in
        MacOSX8664|MacOSAarch64)   os_part="MacOS" ;;
        WindowsX8664|WindowsAarch64) os_part="Windows" ;;
        LinuxX8664|LinuxAarch64)   os_part="Linux" ;;
        AndroidAarch64)             os_part="Android" ;;
    esac
    case "${target}" in
        MacOSX8664|WindowsX8664|LinuxX8664) arch_part="x86_64" ;;
        *) arch_part="aarch64" ;;
    esac
    version_part="v$(app_image_version)"
    local out
    out="$(printf "%s" "${release}" | sed \
        -E -e "s/\{\{version\}\}/${version_part}/g" \
           -e "s/\{\{os\}\}/${os_part}/g" \
           -e "s/\{\{arch\}\}/${arch_part}/g")"

    # Ensure VM for target exists.
    if [[ ! -e "$(app_gtoolkit_app_location_for_target "${target}")/$(gtoolkit_app_file_name_for_target "${target}" | sed 's/\.zip$//' || true)" ]]; then
        download_glamorous_toolkit_vm "${target}" "auto"
    fi

    local workspace; workspace="$(app_workspace)"
    local tmp; tmp="$(mktemp -d)"
    cp -p "${workspace}"/*.image   "${tmp}/" 2>/dev/null || true
    cp -p "${workspace}"/*.changes "${tmp}/" 2>/dev/null || true
    cp -p "${workspace}"/*.sources "${tmp}/" 2>/dev/null || true
    if [[ -d "${workspace}/gt-extra" ]]; then
        cp -R "${workspace}/gt-extra" "${tmp}/"
    fi

    case "${target}" in
        MacOSX8664|MacOSAarch64)
            [[ -d "$(app_gtoolkit_app_location_for_target "${target}")/GlamorousToolkit.app" ]] && \
                cp -R "$(app_gtoolkit_app_location_for_target "${target}")/GlamorousToolkit.app" "${tmp}/" ;;
        WindowsX8664|WindowsAarch64)
            [[ -d "$(app_gtoolkit_app_location_for_target "${target}")/bin" ]] && \
                cp -R "$(app_gtoolkit_app_location_for_target "${target}")/bin" "${tmp}/" ;;
        LinuxX8664|LinuxAarch64)
            [[ -d "$(app_gtoolkit_app_location_for_target "${target}")/bin" ]] && \
                cp -R "$(app_gtoolkit_app_location_for_target "${target}")/bin" "${tmp}/"
            [[ -d "$(app_gtoolkit_app_location_for_target "${target}")/lib" ]] && \
                cp -R "$(app_gtoolkit_app_location_for_target "${target}")/lib" "${tmp}/" ;;
    esac

    (cd "${tmp}" && zip -qr "${out}" .)
    rm -rf "${tmp}"
    printf "%s\n" "${out}"
}

subcommand_run_releaser() {
    local bump="patch"
    while (( $# )); do
        case "$1" in
            --bump) bump="$2"; shift ;;
            *) die "unknown releaser option: $1" ;;
        esac
        shift
    done
    local verb_flag=""; [[ "${VERBOSE}" -eq 1 ]] && verb_flag="--verbose"
    smalltalk_command eval --no-quit \
        "releasegtoolkit --strategy=${bump} --expected=v$(app_image_version) ${verb_flag}" >/dev/null
}

subcommand_print_debug() {
    local workspace; workspace="$(app_workspace)"
    cat <<EOF
Application {
    verbose = ${VERBOSE}
    workspace = ${workspace}
    app_version = $(app_app_version)
    image_version = $(app_image_version)
    image_name = $(app_image_name)
    image_extension = $(app_image_ext)
    image_seed = $(app_seed_kind) $(app_seed_value)
    platform = ${PLATFORM_OS} (${PLATFORM_TRIPLE})
}
EOF
}

subcommand_print_image_version() {
    app_load_from_yaml
    printf "v%s\n" "$(app_image_version)"
}

subcommand_print_app_version() {
    app_load_from_yaml
    printf "v%s\n" "$(app_app_version)"
}

# ---------- Application (de)serialization --------------------------------
# `app_load_from_yaml` defaults to <workspace>/gtoolkit.yaml (matching the
# Rust crate). Callers that store the YAML elsewhere (e.g. in CWD as a
# "what to do file") should pass the path explicitly.
app_serialize() {
    write_application_yaml \
        "$(app_workspace)/${SERIALIZATION_FILE}" \
        "$(app_image_name)" \
        "$(app_image_ext)" \
        "$(app_image_version)" \
        "$(app_app_version)" \
        "$(app_seed_kind)" \
        "$(app_seed_value)" \
        "$(app_workspace)" \
        "${VERBOSE}" \
        "${APP[app_cli_binary]:-}"
}

app_load_from_yaml() {
    local file="${1:-$(app_workspace)/${SERIALIZATION_FILE}}"
    [[ -f "${file}" ]] || die "serialization file missing: ${file}"
    APP[image_name]="$(read_yaml_field "${file}" image_name)"
    APP[image_ext]="$(read_yaml_field "${file}" image_extension)"
    # Normalize: strip a leading 'v' so URL templates always see the bare
    # version (the Rust binary also stores these without the prefix).
    APP[image_version]="$(read_yaml_field "${file}" image_version | sed -E 's/^v//')"
    APP[app_version]="$(read_yaml_field "${file}" app_version | sed -E 's/^v//')"
    APP[app_cli_binary]="$(read_yaml_field "${file}" app_cli_binary || true)"

    # Seed kind is encoded as "Url"/"Zip"/"Image" in the YAML.
    for kind in Url Zip Image; do
        local v; v="$(read_yaml_field "${file}" "${kind}" || true)"
        if [[ -n "${v}" ]]; then
            APP[seed_kind]="${kind,,}"
            APP[seed_value]="${v}"
            return
        fi
    done
}

# Generate a starter "what to do file" in CWD when none exists. Probes
# GitHub for the latest versions of gtoolkit and gtoolkit-vm, and writes
# the YAML so the user can edit it if anything goes wrong.
generate_starter_yaml() {
    local out="$1"
    info "No ${SERIALIZATION_FILE} found — generating starter at ${out}"
    local img_v app_v
    img_v="$(github_latest_release_tag "${GTOOLKIT_REPOSITORY_OWNER}" "${GTOOLKIT_REPOSITORY_NAME}")" \
        || { github_require_token; die "failed to fetch latest gtoolkit image version"; }
    app_v="$(github_latest_release_tag "${VM_REPOSITORY_OWNER}" "${VM_REPOSITORY_NAME}")" \
        || { github_require_token; die "failed to fetch latest gtoolkit-vm version"; }
    cat > "${out}" <<EOF
# gtoolkit.yaml — "what to do" file for gt-installer.
#
# Edit any field below and re-run \`gt-installer\` to retry with different
# settings. The installer will NOT overwrite this file after writing it,
# so you stay in control.

# Where to put the image, changes, and gtoolkit app binary.
workspace: "${APP[workspace]:-${DEFAULT_WORKSPACE}}"

# Glamorous Toolkit VM (the gtoolkit-vm app) version.
app_version: "${app_v}"

# Optional override for the gtoolkit CLI binary. Leave empty to use the
# binary downloaded into \`workspace\`.
app_cli_binary: ""

# Override the Iceberg repository cache (where gtoolkit-vm stores cloned
# GT repos). Default is "pharo-local/iceberg/" relative to workspace.
# Set to an absolute path to share the cache across multiple workspaces
# (saves ~24 min on the second build). The --iceberg-location CLI flag
# takes precedence; the GT_INSTALLER_ICEBERG_LOCATION env var is also
# honoured.
iceberg_location: ""

# gtoolkit image version to load (resolved via the cloner/metacello loaders).
image_version: "${img_v}"

# Image filename and extension.
image_name: "${DEFAULT_IMAGE_NAME}"
image_extension: "${DEFAULT_IMAGE_EXTENSION}"

# What to seed the image with. Pick one of:
#   Url:  "https://..."      download a fresh Pharo image from this URL
#   Zip:  "/path/to/seed.zip"   use a local seed zip
#   Image: "/path/to/seed.image"  use an existing image file directly
image_seed:
  Url: "${DEFAULT_PHARO_IMAGE}"
EOF
    info "Wrote ${out}. Edit it and re-run \`gt-installer\` if anything fails."
}

# Populate the runtime VERBOSE flag from the persisted YAML. Called after
# app_load_from_yaml so a hand-edited `verbose: true` actually takes effect.
app_load_verbose_from_yaml() {
    local file="${1:-$(app_workspace)/${SERIALIZATION_FILE}}"
    [[ -f "${file}" ]] || return 0
    local v; v="$(read_yaml_field "${file}" verbose)"
    case "${v}" in
        true|1|yes|on)  VERBOSE=1 ;;
        false|0|no|off|"") : ;;
        *) warn "unrecognized verbose value in YAML: ${v}" ;;
    esac
}

# ---------- Composite subcommands (local-build / release-build) ---------
subcommand_local_build() {
    local no_gt_world=0
    while (( $# )); do
        case "$1" in
            --no-gt-world) no_gt_world=1 ;;
            --) shift; break ;;
            *) break ;;
        esac
        shift
    done

    # local-build = build + setup(target=local-build) + (optional) GtWorld open.
    subcommand_build "$@"
    local gt_world_flag=()
    [[ "${no_gt_world}" -eq 1 ]] && gt_world_flag+=(--no-gt-world)
    subcommand_setup --target local-build "${gt_world_flag[@]}"
}

subcommand_release_build() {
    local no_gt_world=0 bump="patch"
    while (( $# )); do
        case "$1" in
            --no-gt-world) no_gt_world=1 ;;
            --bump) bump="$2"; shift ;;
            --) shift; break ;;
            *) break ;;
        esac
        shift
    done

    subcommand_build "$@"
    local gt_world_flag=()
    [[ "${no_gt_world}" -eq 1 ]] && gt_world_flag+=(--no-gt-world)
    subcommand_setup --target release --bump "${bump}" "${gt_world_flag[@]}"
}

# ---------- Top-level dispatch -------------------------------------------
usage() {
    cat <<'EOF'
gt-installer — bash port of the Glamorous Toolkit installer

The installer reads a gtoolkit.yaml file as a "what to do" recipe. You can
keep several YAMLs side-by-side (e.g. dev.yaml, release.yaml, ci.yaml) and
point the installer at the one you want:

  gt-installer --yaml dev.yaml print-debug
  GT_INSTALLER_YAML=release.yaml gt-installer build --overwrite
  gt-installer                      # uses ./gtoolkit.yaml in CWD

If the YAML is missing, the installer generates a starter (with the latest
versions from GitHub) so you have something to edit if anything goes wrong.
Edit the YAML and re-run the installer — your edits are never overwritten
by `build` or `setup` (only by `rename-to` / `copy-to`, which intentionally
mutate the image identity).

Usage:
  gt-installer [global options] <subcommand> [subcommand options]
  gt-installer [global options] [build opts]    # same as `local-build`

Global options:
  --verbose                 Verbose output (mirrors `verbose` flag in Rust)
  --workspace <path>        Workspace directory (overrides YAML's value)
  --yaml <path>             Path to the YAML config (overrides GT_INSTALLER_YAML)
  --app-cli-binary <path>   Override path to the GlamorousToolkit CLI binary
  --no-color                Disable colored output
  -h, --help                Show this help

YAML lookup order: --yaml > $GT_INSTALLER_YAML > ./gtoolkit.yaml

Build flags accepted before the subcommand (forwarded to `local-build`):
  --overwrite               Delete and re-create the workspace before building
  --no-gt-world            Don't open a default GtWorld after setup
  --image-file <path>       Build on top of an existing .image
  --image-zip <path>        Build on top of a zipped image
  --image-url <url>         Build on top of an image at this URL
  --loader <cloner|metacello>
  --version <spec>          bleeding-edge | latest-release | vX.Y.Z
  --app-version <spec>      latest-release | vX.Y.Z (VM version)
  --customer-level <auto|regular|pro>
  --iceberg-location <path> --public-key <p> --private-key <p>

Subcommands:
  local-build [opts]          Build a local GToolkit and set it up (default)
  release-build [opts]        Build + setup for release
  build [opts]                Build only
  setup [opts]                Set up an existing image
  start [opts]                Start the image, wait, save, and quit
  clean-up                    Clean up SSH keys and iceberg repositories
  test [opts]                 Run GToolkit tests
  copy-to <destination>       Copy image (and optionally app) to a new workspace
  rename-to <name>            Rename the image
  package-tentative <path>    Package a tentative release
  unpackage-tentative <zip>   Unpackage a tentative release
  package-release <template>  Package a full release (supports {{version}}/{{os}}/{{arch}})
  run-releaser [opts]         Run the gtoolkit-releaser
  print-debug                 Print debug info about the application
  print-gtoolkit-image-version  Print the image version from gtoolkit.yaml
  print-gtoolkit-app-version    Print the app version from gtoolkit.yaml
  download [vm] [opts]        Download the GlamorousToolkit App

Run `gt-installer <subcommand> --help` to see subcommand-specific options.
EOF
}

main() {
    # Global options.
    local workspace="${DEFAULT_WORKSPACE}"
    local subcommand=""
    local positional=()
    # Forwarded to the default `local-build` subcommand when no explicit
    # subcommand is given (matches the Rust binary's default behaviour).
    local -a default_subcommand_args=()
    local yaml_arg=""

    while (( $# )); do
        case "$1" in
            -h|--help) usage; exit 0 ;;
            --verbose) VERBOSE=1 ;;
            --no-color) NO_COLOR=1 ;;
            --workspace) workspace="$2"; shift ;;
            --app-cli-binary) APP[app_cli_binary]="$2"; shift ;;
            --yaml) yaml_arg="$2"; shift ;;
            --version) echo "gt-installer ${GT_INSTALLER_VERSION}"; exit 0 ;;
            # Subcommand-style flags: when no subcommand is given, treat them
            # as arguments to the implicit `local-build` so things like
            # `gt-installer --overwrite` and `gt-installer --image-file foo`
            # work the same as `gt-installer local-build --overwrite`.
            --overwrite|--no-gt-world)
                default_subcommand_args+=("$1") ;;
            --loader|--image-url|--image-zip|--image-file|--iceberg-location|\
            --public-key|--private-key|--app-version|--customer-level)
                default_subcommand_args+=("$1" "$2"); shift ;;
            -*) die "unknown option: $1" ;;
            *)
                subcommand="$1"
                shift
                positional=("$@")
                break
                ;;
        esac
        shift
    done

    if [[ -z "${subcommand}" ]]; then
        subcommand="local-build"
        # Forward any build flags that were passed before the subcommand
        # (e.g. `./gt-installer.sh --overwrite` -> `local-build --overwrite`).
        positional=("${default_subcommand_args[@]}")
    fi

    detect_platform

    # Resolve the YAML location. By default it lives in CWD (the "what to do
    # file" the user can edit). `--workspace-yaml` overrides; `--workspace`
    # overrides the workspace path inside the YAML.
    local yaml_path
    # Lookup order: --yaml flag > GT_INSTALLER_YAML env var > ./gtoolkit.yaml.
    if [[ -n "${yaml_arg:-}" ]]; then
        yaml_path="$(normalize_workspace "${yaml_arg}")"
    elif [[ -n "${GT_INSTALLER_YAML:-}" ]]; then
        yaml_path="$(normalize_workspace "${GT_INSTALLER_YAML}")"
    else
        yaml_path="$(pwd)/${SERIALIZATION_FILE}"
    fi

    # Resolve workspace (defaults to the YAML's `workspace` field, then the
    # --workspace CLI override, then "glamoroustoolkit").
    if [[ -f "${yaml_path}" ]]; then
        # Load workspace from YAML if --workspace wasn't passed.
        if [[ "${workspace}" == "${DEFAULT_WORKSPACE}" ]]; then
            workspace="$(read_yaml_field "${yaml_path}" workspace || true)"
            [[ -n "${workspace}" ]] || workspace="${DEFAULT_WORKSPACE}"
        fi
        APP[workspace]="$(normalize_workspace "${workspace}")"
        # Allow CLI --workspace to override the YAML's value.
        app_load_from_yaml "${yaml_path}"
        app_load_verbose_from_yaml "${yaml_path}"
        APP[workspace]="$(normalize_workspace "${workspace}")"
    else
        APP[workspace]="$(normalize_workspace "${workspace}")"
        # No YAML present — generate a starter so the user has something to
        # edit if the build fails. Probe GitHub for the latest versions and
        # write a starter YAML at the configured path.
        generate_starter_yaml "${yaml_path}"
        # Now read what we just wrote so APP is populated.
        app_load_from_yaml "${yaml_path}"
        APP[workspace]="$(normalize_workspace "${workspace}")"
    fi

    case "${subcommand}" in
        local-build)                subcommand_local_build "${positional[@]:-}" ;;
        release-build)              subcommand_release_build "${positional[@]:-}" ;;
        build)                      subcommand_build "${positional[@]:-}" ;;
        setup)                      subcommand_setup "${positional[@]:-}" ;;
        start)                      subcommand_start "${positional[@]:-}" ;;
        clean-up|cleanup)           subcommand_cleanup "${positional[@]:-}" ;;
        test)                       subcommand_test "${positional[@]:-}" ;;
        copy-to|copyto)             subcommand_copy_to "${positional[@]:-}" ;;
        rename-to|renameto)         subcommand_rename_to "${positional[@]:-}" ;;
        package-tentative)          subcommand_package_tentative "${positional[@]:-}" ;;
        unpackage-tentative)        subcommand_unpackage_tentative "${positional[@]:-}" ;;
        package-release)            subcommand_package_release "${positional[@]:-}" ;;
        run-releaser)               subcommand_run_releaser "${positional[@]:-}" ;;
        download)                   subcommand_download "${positional[@]:-}" ;;
        print-debug)                subcommand_print_debug ;;
        print-gtoolkit-image-version) subcommand_print_image_version ;;
        print-gtoolkit-app-version)   subcommand_print_app_version ;;
        *) die "unknown subcommand: ${subcommand}" ;;
    esac
}

main "$@"