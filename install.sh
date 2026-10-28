#!/usr/bin/env bash
# Installer for show-drive-bays
#   ./install.sh               install to /usr/local/bin/show-drive-bays
#   ./install.sh --uninstall   remove it
#   PREFIX=/opt ./install.sh   install to /opt/bin/show-drive-bays
set -euo pipefail

PREFIX="${PREFIX:-/usr/local}"
TARGET="$PREFIX/bin/show-drive-bays"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/show-drive-bays.sh"

SUDO=()
if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || { echo "error: run as root or install sudo" >&2; exit 1; }
    SUDO=(sudo)
fi

usage() { echo "Usage: $0 [--uninstall] [--help]"; }

uninstall() {
    if [[ -e "$TARGET" ]]; then
        "${SUDO[@]}" rm -f "$TARGET"
        echo "Removed $TARGET"
    else
        echo "Nothing to remove ($TARGET not found)"
    fi
}

check_deps() {
    local missing=0 t hba=""
    for t in sas3ircu sas2ircu storcli64 storcli perccli64 perccli; do
        if command -v "$t" >/dev/null 2>&1; then hba="$t"; break; fi
    done
    if [[ -n "$hba" ]]; then
        echo "  [ok]   HBA tool: $hba"
    else
        echo "  [warn] no HBA tool found (sas3ircu / sas2ircu / storcli)."
        echo "         The tool will fall back to SES (/sys/class/enclosure) or a positional disk list."
        missing=1
    fi
    for t in mdadm udevadm lsblk smartctl; do
        if command -v "$t" >/dev/null 2>&1; then
            echo "  [ok]   $t"
        else
            case "$t" in
                lsblk)    echo "  [warn] lsblk missing — REQUIRED (package: util-linux)" ;;
                udevadm)  echo "  [warn] udevadm missing — needed for WWN matching (package: udev/systemd)" ;;
                mdadm)    echo "  [warn] mdadm missing — RAID summary will be unavailable (package: mdadm)" ;;
                smartctl) echo "  [info] smartctl missing — health/temperature columns disabled (package: smartmontools)" ;;
            esac
            missing=1
        fi
    done
    (( missing )) && echo "  Install continues; missing tools only limit functionality."
    return 0
}

case "${1:-}" in
    --uninstall|-u) uninstall; exit 0 ;;
    --help|-h)      usage; exit 0 ;;
    "")             ;;
    *)              usage >&2; exit 1 ;;
esac

[[ -f "$SRC" ]] || { echo "error: $SRC not found" >&2; exit 1; }

echo "Checking dependencies..."
check_deps
"${SUDO[@]}" install -d -m 0755 "$PREFIX/bin"
"${SUDO[@]}" install -m 0755 "$SRC" "$TARGET"
echo "Installed $TARGET"
echo "Run: show-drive-bays --help"
