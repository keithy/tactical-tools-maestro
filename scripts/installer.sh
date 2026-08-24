#!/usr/bin/env bash
# installer.sh — downloads and runs the bash `gt-installer` for the host
# platform. Mirrors the behaviour of the Rust crate's `scripts/installer.sh`:
# when invoked without arguments it defaults to `local-build`, otherwise the
# provided subcommand and arguments are forwarded.

set -euo pipefail

installer="gt-installer"

arguments=("$@")
if [[ $# -eq 0 ]]; then
    arguments=("local-build")
fi

base_url="https://github.com/keithhamilton/gt-installer-bashtest/releases/latest/download"
script_url="${base_url}/${installer}.sh"

case "$(uname -s)" in
    Linux)
        arch="$(uname -m)"
        case "${arch}" in
            x86_64)   suffix="linux-x86_64" ;;
            aarch64)  suffix="linux-aarch64" ;;
            *) echo "${arch} architecture is unsupported." >&2; exit 1 ;;
        esac
        ;;
    Darwin)
        arch="$(uname -m)"
        case "${arch}" in
            x86_64)
                if [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 1)" == "1" ]]; then
                    suffix="macos-aarch64"
                else
                    suffix="macos-x86_64"
                fi
                ;;
            arm64)    suffix="macos-aarch64" ;;
            *) echo "${arch} architecture is unsupported." >&2; exit 1 ;;
        esac
        ;;
    *)
        echo "$(uname -s) is unsupported." >&2
        exit 1
        ;;
esac

# Single-file bash implementation: there's nothing to fetch besides the
# script itself. For convenience we still prefer fetching the latest tag if
# available, falling back to the `main` branch.
fetch_url="${base_url}/${installer}-${suffix}.sh"
if ! curl -fsSL -o "${installer}.sh" "${fetch_url}" 2>/dev/null; then
    fetch_url="https://raw.githubusercontent.com/keithhamilton/gt-installer-bash/main/gt-installer.sh"
    curl -fsSL -o "${installer}.sh" "${fetch_url}"
fi

chmod +x "${installer}.sh"
./"${installer}.sh" "${arguments[@]}"