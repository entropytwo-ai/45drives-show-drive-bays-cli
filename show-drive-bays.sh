#!/usr/bin/env bash
# ==============================================================================
# show-drive-bays — drive / bay / RAID mapper for 45Drives and other servers
# ==============================================================================
#
# Maps physical drive bays (HBA enclosure + slot) to Linux block devices,
# mdadm software-RAID membership, SMART health and temperature, and draws an
# ASCII picture of the front of every enclosure.
#
# Supported hardware / backends (auto-detected in this order):
#   sas3ircu   Broadcom/LSI SAS3 HBAs (9300/9305/9400-series in IT/IR mode),
#              e.g. 45Drives Storinator, Stornado, HL15, C8, XL60 ...
#   sas2ircu   Broadcom/LSI SAS2 HBAs (9201/9207/9211/9240-series)
#   storcli    Broadcom MegaRAID / 94xx/95xx tri-mode HBAs (storcli/storcli64)
#   ses        Any SES-capable backplane exposed by the kernel through
#              /sys/class/enclosure (works with most HBAs/expanders)
#   none       No SAS HBA / enclosure: disks are listed positionally and the
#              mdadm RAID summary is still shown (onboard SATA, NVMe, VMs)
#
# Disks are matched to bays by WWN (falling back to serial number). SATA, SAS
# and NVMe devices are all scanned. Multiple controllers and multiple
# enclosures per controller are supported.
#
# Run with --help for usage.
# ==============================================================================

set -euo pipefail

VERSION="2.1.0"
PROG="${0##*/}"

# Overridable for testing / unusual systems
MDSTAT_FILE="${MDSTAT_FILE:-/proc/mdstat}"
SYSFS_ENCLOSURE="${SYSFS_ENCLOSURE:-/sys/class/enclosure}"

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
OPT_CONTROLLER=""      # empty = all controllers
OPT_BAYS=""            # empty = auto
OPT_COLS=""            # empty = auto
OPT_BACKEND="auto"
OPT_COLOR="auto"
OPT_JSON=0
OPT_WIDE=0
OPT_SMART=1
OPT_VIZ=1
OPT_RAID=1
OPT_DRY_RUN=0
OPT_TRACE=0

trap 'exit 130' INT TERM

usage() {
    cat <<EOF
$PROG $VERSION — map drive bays to devices, RAID arrays and SMART health

Usage: $PROG [options]

Options:
  -c, --controller N   Only query HBA controller N (default: all detected)
  -b, --bays N         Bays per enclosure in the visualization
                       (default: auto — enclosure slot count if reported,
                       otherwise highest populated slot, minimum 8)
      --cols N         Bays per row in the visualization (default: auto, max 12)
  -B, --backend NAME   Force backend: auto|sas3ircu|sas2ircu|storcli|ses|none
  -w, --wide           Add a temperature column (requires smartctl)
      --no-smart       Skip smartctl queries (faster)
      --no-viz         Skip the bay visualization
      --no-raid        Skip the mdadm RAID summary
      --no-color       Disable ANSI colors (also honoured: NO_COLOR env var)
      --color          Force ANSI colors even when not writing to a terminal
  -j, --json           Print drives and arrays as JSON (implies --no-color)
  -n, --dry-run        Execute nothing: report detected tools, the backend that
                       would be tried and every command that would be run
  -t, --trace          Run normally but log each privileged (sudo/root)
                       command to stderr before it is executed
  -V, --version        Print version
  -h, --help           Show this help

Examples:
  $PROG --dry-run             # see what would run, without running it
  $PROG                       # auto-detect everything
  $PROG --bays 15 --cols 5    # HL15: three rows of five
  $PROG --controller 1 --wide # second HBA only, with temperatures
  $PROG --json | jq '.drives[] | select(.health != "PASSED")'
EOF
}

die()  { echo "$PROG: error: $*" >&2; exit 1; }
warn() { echo "$PROG: warning: $*" >&2; }

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

parse_args() {
    while (($#)); do
        case "$1" in
            -c|--controller) is_uint "${2:-}" || die "--controller needs a number"; OPT_CONTROLLER="$2"; shift ;;
            -b|--bays)       is_uint "${2:-}" && (( $2 > 0 )) || die "--bays needs a positive number"; OPT_BAYS="$2"; shift ;;
            --cols)          is_uint "${2:-}" && (( $2 > 0 )) || die "--cols needs a positive number"; OPT_COLS="$2"; shift ;;
            -B|--backend)    OPT_BACKEND="${2:-}"; shift
                             [[ "$OPT_BACKEND" =~ ^(auto|sas3ircu|sas2ircu|storcli|ses|none)$ ]] || die "unknown backend '$OPT_BACKEND'" ;;
            -w|--wide)       OPT_WIDE=1 ;;
            --no-smart)      OPT_SMART=0 ;;
            --no-viz)        OPT_VIZ=0 ;;
            --no-raid)       OPT_RAID=0 ;;
            --no-color)      OPT_COLOR="never" ;;
            --color)         OPT_COLOR="always" ;;
            -j|--json)       OPT_JSON=1 ;;
            -n|--dry-run)    OPT_DRY_RUN=1 ;;
            -t|--trace)      OPT_TRACE=1 ;;
            -V|--version)    echo "$PROG $VERSION"; exit 0 ;;
            -h|--help)       usage; exit 0 ;;
            *)               usage >&2; die "unknown option '$1'" ;;
        esac
        shift
    done
}

# ------------------------------------------------------------------------------
# Colors / drawing characters
# ------------------------------------------------------------------------------
setup_colors() {
    local use=0
    case "$OPT_COLOR" in
        always) use=1 ;;
        never)  use=0 ;;
        auto)   [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]] && use=1 ;;
    esac
    (( OPT_JSON )) && use=0
    USE_COLOR=$use
    if (( use )); then
        RESET=$'\033[0m'; BOLD=$'\033[1m'
        FG_BLACK=$'\033[30m'; FG_RED=$'\033[31m'; FG_GREEN=$'\033[32m'
        FG_YELLOW=$'\033[33m'; FG_CYAN=$'\033[36m'; FG_WHITE=$'\033[97m'
        BG_RED=$'\033[41m'; BG_GREEN=$'\033[42m'; BG_YELLOW=$'\033[43m'
        BG_BLUE=$'\033[44m'; BG_MAGENTA=$'\033[45m'
    else
        RESET=""; BOLD=""; FG_BLACK=""; FG_RED=""; FG_GREEN=""; FG_YELLOW=""
        FG_CYAN=""; FG_WHITE=""; BG_RED=""; BG_GREEN=""; BG_YELLOW=""; BG_BLUE=""; BG_MAGENTA=""
    fi
    if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]]; then
        BOX_TL="┌"; BOX_TR="┐"; BOX_BL="└"; BOX_BR="┘"; BOX_H="─"; BOX_V="│"; RULE="═"
    else
        BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="-"; BOX_V="|"; RULE="="
    fi
}

repeat_char() { local i out=""; for ((i = 0; i < $2; i++)); do out+="$1"; done; printf '%s' "$out"; }

section() {
    local line; line=$(repeat_char "$RULE" 80)
    printf '\n%s\n %s%s%s\n%s\n' "$line" "$BOLD" "$1" "$RESET" "$line"
}

# Colorize an already padded cell according to the (unpadded) state text.
color_state() {
    local cell="$1" s="${2,,}"
    if (( ! USE_COLOR )); then printf '%s' "$cell"; return; fi
    case "$s" in
        *fail*|*offl*|*ubad*|*bad*|*missing*|*msng*|*faulty*|*inactive*) printf '%s%s%s' "$FG_RED" "$cell" "$RESET" ;;
        *degrad*|*rebuild*|*rbld*|*recover*|*resync*|*reshape*|*warn*)   printf '%s%s%s' "$FG_YELLOW" "$cell" "$RESET" ;;
        *optimal*|*opt*|*ready*|*rdy*|*onln*|*online*|*ugood*|*good*|*jbod*|*ok*|*passed*|*clean*|*active*)
                                                                          printf '%s%s%s' "$FG_GREEN" "$cell" "$RESET" ;;
        *)                                                                printf '%s' "$cell" ;;
    esac
}

# ------------------------------------------------------------------------------
# Privilege helper
# ------------------------------------------------------------------------------
SUDO=()
setup_sudo() {
    if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1; then SUDO=(sudo); fi
}
run_priv() {
    # fd 3 = original stderr, so traces survive the 2>/dev/null used by callers
    (( OPT_TRACE )) && printf '%s: trace: %s\n' "$PROG" "${SUDO[*]}${SUDO[*]:+ }$*" >&3
    "${SUDO[@]}" "$@"
}

# ------------------------------------------------------------------------------
# Global data
# ------------------------------------------------------------------------------
BACKEND=""
HBA_TOOL=""
CONTROLLERS=()

# Drives (parallel indexed arrays)
NDRIVES=0
D_CTRL=(); D_ENCL=(); D_SLOT=(); D_MODEL=(); D_SERIAL=(); D_FW=(); D_SIZE=()
D_STATE=(); D_WWN=(); D_DEV=(); D_ARRAY=(); D_ROLE=(); D_HEALTH=(); D_TEMP=()

# Enclosures: key "ctrl:encl"
declare -A ENC_SLOTS=() ENC_START=()
ENC_ORDER=()

# Device cache
declare -A WWN_DEV=() SERIAL_DEV=() DEV_MODEL=() DEV_SERIAL=() DEV_FW=() DEV_SIZE=() DEV_WWN=() DEV_SEEN=()
DISKS=()

# mdadm
MD_LIST=()
declare -A MD_DETAIL=() MD_NAME=() DEV_ARRAY=() DEV_ROLE=()

add_drive() {  # ctrl encl slot model serial fw size state wwn
    local i=$NDRIVES
    D_CTRL[i]="$1"; D_ENCL[i]="$2"; D_SLOT[i]="$3"; D_MODEL[i]="${4:--}"
    D_SERIAL[i]="${5:--}"; D_FW[i]="${6:--}"; D_SIZE[i]="${7:--}"; D_STATE[i]="${8:--}"
    D_WWN[i]="$(norm_id "${9:-}")"; D_DEV[i]="-"; D_ARRAY[i]="-"; D_ROLE[i]="-"
    D_HEALTH[i]="-"; D_TEMP[i]="-"
    NDRIVES=$((NDRIVES + 1))
}

add_enclosure() {  # ctrl encl numslots startslot
    local key="$1:$2"
    if [[ -z "${ENC_SLOTS[$key]+x}" ]]; then ENC_ORDER+=("$key"); fi
    ENC_SLOTS[$key]="${3:-0}"
    ENC_START[$key]="${4:-0}"
}

# Normalize a WWN / serial: lowercase, strip 0x / naa. / eui. / nvme. prefixes and spaces
norm_id() {
    local v="${1,,}"
    v="${v//[[:space:]]/}"
    v="${v#0x}"; v="${v#naa.}"; v="${v#eui.}"; v="${v#nvme.}"
    printf '%s' "$v"
}

bytes_to_tb() { awk -v b="${1:-0}" 'BEGIN{ if (b+0 > 0) printf "%.2f", b/1000/1000/1000/1000; else printf "-" }'; }

# ------------------------------------------------------------------------------
# Backend / controller detection
# ------------------------------------------------------------------------------
detect_backend() {
    local t
    if [[ "$OPT_BACKEND" != "auto" ]]; then
        BACKEND="$OPT_BACKEND"
        case "$BACKEND" in
            sas3ircu|sas2ircu) command -v "$BACKEND" >/dev/null 2>&1 || die "$BACKEND not found in PATH"; HBA_TOOL="$BACKEND" ;;
            storcli) for t in storcli64 storcli perccli64 perccli; do
                         if command -v "$t" >/dev/null 2>&1; then HBA_TOOL="$t"; break; fi
                     done
                     [[ -n "$HBA_TOOL" ]] || die "storcli/storcli64 not found in PATH" ;;
        esac
        return 0
    fi
    for t in sas3ircu sas2ircu; do
        if command -v "$t" >/dev/null 2>&1; then
            HBA_TOOL="$t"; BACKEND="$t"
            detect_controllers
            if ((${#CONTROLLERS[@]})); then return 0; fi
            warn "$t is installed but reported no controllers, trying next backend"
        fi
    done
    for t in storcli64 storcli perccli64 perccli; do
        if command -v "$t" >/dev/null 2>&1; then
            HBA_TOOL="$t"; BACKEND="storcli"
            detect_controllers
            if ((${#CONTROLLERS[@]})); then return 0; fi
            warn "$t is installed but reported no controllers, trying next backend"
            break
        fi
    done
    HBA_TOOL=""
    if compgen -G "$SYSFS_ENCLOSURE/*" >/dev/null; then BACKEND="ses"; return 0; fi
    BACKEND="none"
}

detect_controllers() {
    CONTROLLERS=()
    local out c
    case "$BACKEND" in
        sas3ircu|sas2ircu)
            out=$(run_priv "$HBA_TOOL" LIST 2>/dev/null || true)
            while read -r c; do CONTROLLERS+=("$c"); done < <(
                awk '$1 ~ /^[0-9]+$/ && NF >= 5 {print $1}' <<<"$out")
            ;;
        storcli)
            out=$(run_priv "$HBA_TOOL" show ctrlcount 2>/dev/null || true)
            c=$(awk -F'=' '/Controller Count|Number of Controllers/{gsub(/[^0-9]/,"",$2); print $2; exit}' <<<"$out")
            if is_uint "$c"; then
                local i; for ((i = 0; i < c; i++)); do CONTROLLERS+=("$i"); done
            fi
            ;;
        ses)
            CONTROLLERS=("0") ;;
        *)  ;;
    esac
    if [[ -n "$OPT_CONTROLLER" && "$BACKEND" =~ ^(sas3ircu|sas2ircu|storcli)$ ]]; then
        local found=0
        for c in "${CONTROLLERS[@]}"; do [[ "$c" == "$OPT_CONTROLLER" ]] && found=1; done
        (( found )) || warn "controller $OPT_CONTROLLER was not listed by $HBA_TOOL; querying it anyway"
        CONTROLLERS=("$OPT_CONTROLLER")
    fi
}

# ------------------------------------------------------------------------------
# Device cache: one udevadm call per disk, O(1) lookups afterwards
# ------------------------------------------------------------------------------
build_wwn_cache() {
    local dev type props wwn wwnx serial model rev size
    command -v udevadm >/dev/null 2>&1 || warn "udevadm not found; WWN matching disabled"
    while read -r dev type; do
        [[ "$type" == "disk" ]] || continue
        [[ "$dev" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+)$ ]] || continue
        DISKS+=("$dev")
        props=""
        if command -v udevadm >/dev/null 2>&1; then
            props=$(udevadm info --query=property --name="$dev" 2>/dev/null || true)
        fi
        wwn="" wwnx="" serial="" model="" rev=""
        while IFS='=' read -r k v; do
            case "$k" in
                ID_WWN) wwn="$v" ;;
                ID_WWN_WITH_EXTENSION) wwnx="$v" ;;
                ID_SERIAL_SHORT) serial="$v" ;;
                ID_MODEL) model="${v//_/ }" ;;
                ID_REVISION) rev="$v" ;;
            esac
        done <<<"$props"
        size=$(lsblk -dnbo SIZE "$dev" 2>/dev/null | head -n1 || true)
        wwn=$(norm_id "$wwn"); wwnx=$(norm_id "$wwnx")
        [[ -n "$wwn" ]]  && WWN_DEV[$wwn]="$dev"
        [[ -n "$wwnx" ]] && WWN_DEV[$wwnx]="$dev"
        [[ -n "$serial" ]] && SERIAL_DEV[$(norm_id "$serial")]="$dev"
        DEV_WWN[$dev]="${wwnx:-$wwn}"
        DEV_SERIAL[$dev]="$serial"; DEV_MODEL[$dev]="$model"; DEV_FW[$dev]="$rev"
        DEV_SIZE[$dev]="$(bytes_to_tb "${size// /}")"
    done < <(lsblk -dnpo NAME,TYPE 2>/dev/null || true)
}

# Find the block device for a drive reported by the HBA
lookup_dev() {  # wwn serial
    local wwn serial k
    wwn=$(norm_id "${1:-}"); serial=$(norm_id "${2:-}")
    if [[ -n "$wwn" && -n "${WWN_DEV[$wwn]:-}" ]]; then printf '%s' "${WWN_DEV[$wwn]}"; return; fi
    if [[ -n "$serial" && "$serial" != "-" ]]; then
        if [[ -n "${SERIAL_DEV[$serial]:-}" ]]; then printf '%s' "${SERIAL_DEV[$serial]}"; return; fi
        # HBA tools sometimes truncate serials (e.g. SAS drives); accept a unique prefix match
        if (( ${#serial} >= 6 )); then
            for k in "${!SERIAL_DEV[@]}"; do
                if [[ "$k" == "$serial"* || "$serial" == "$k"* ]]; then printf '%s' "${SERIAL_DEV[$k]}"; return; fi
            done
        fi
    fi
    # SAS drives: the HBA may report the target-port WWN which differs from the LU WWN in the last digit
    # (only accepted when exactly one device matches, to avoid mixing up drives with adjacent WWNs)
    if (( ${#wwn} == 16 )); then
        local hit="" n=0
        for k in "${!WWN_DEV[@]}"; do
            if [[ "${k:0:15}" == "${wwn:0:15}" && "${WWN_DEV[$k]}" != "$hit" ]]; then hit="${WWN_DEV[$k]}"; n=$((n + 1)); fi
        done
        if (( n == 1 )); then printf '%s' "$hit"; return; fi
    fi
    printf -- '-'
}

# ------------------------------------------------------------------------------
# Drive collection per backend
# ------------------------------------------------------------------------------
collect_ircu() {
    local c out
    for c in "${CONTROLLERS[@]}"; do
        if ! out=$(run_priv "$HBA_TOOL" "$c" display 2>/dev/null); then
            warn "$HBA_TOOL $c display failed"; continue
        fi
        while IFS='|' read -r kind a b cc d e f g h i; do
            case "$kind" in
                E) add_enclosure "$c" "$a" "$b" "$cc" ;;
                D) add_drive "$c" "$a" "$b" "$cc" "$d" "$e" "$f" "$g" "$h"
                   [[ -n "${ENC_SLOTS[$c:$a]+x}" ]] || add_enclosure "$c" "$a" 0 0 ;;
            esac
        done < <(awk '
            function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+$/, "", s); return s }
            function flush() {
                if (isdisk && model != "")
                    printf "D|%s|%s|%s|%s|%s|%s|%s|%s\n", encl, slot, model, serial, fw, size, state, guid
                isdisk = 0; encl = slot = model = serial = fw = size = state = guid = ""
            }
            /^Physical device information/ { sect = "pd"; next }
            /^Enclosure information/       { flush(); sect = "enc"; next }
            /^(IR Volume|Controller) information/ { flush(); sect = ""; next }
            sect == "pd" && /^Device is a/  { flush(); isdisk = ($0 ~ /Hard disk|Solid|SSD/); next }
            sect == "pd" && /^[ \t]*Enclosure #/      { encl = val($0) }
            sect == "pd" && /^[ \t]*Slot #/           { slot = val($0) }
            sect == "pd" && /^[ \t]*State[ \t]*:/     { state = val($0) }
            sect == "pd" && /^[ \t]*Model Number/     { model = val($0) }
            sect == "pd" && /^[ \t]*Firmware Revision/ { fw = val($0) }
            sect == "pd" && /^[ \t]*Serial No[ \t]*:/ { serial = val($0) }
            sect == "pd" && /^[ \t]*GUID/             { guid = val($0); if (guid ~ /^N\/A/) guid = "" }
            sect == "pd" && /^[ \t]*Size \(in MB\)/   { v = val($0); split(v, p, "/"); mb = p[1] + 0
                                                        size = (mb > 0) ? sprintf("%.2f", mb * 1048576 / 1e12) : "-" }
            sect == "enc" && /^[ \t]*Enclosure#/      { e = val($0) }
            sect == "enc" && /^[ \t]*Numslots/        { n = val($0) }
            sect == "enc" && /^[ \t]*StartSlot/       { printf "E|%s|%s|%s\n", e, n, val($0) }
            END { flush() }
        ' <<<"$out")
    done
}

collect_storcli() {
    local c out encl_out
    for c in "${CONTROLLERS[@]}"; do
        encl_out=$(run_priv "$HBA_TOOL" "/c$c/eall" show 2>/dev/null || true)
        while read -r e n; do add_enclosure "$c" "$e" "$n" 0; done < <(
            awk '$1 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $2 ~ /^[A-Za-z]/ {print $1, $3}' <<<"$encl_out")
        out=$(run_priv "$HBA_TOOL" "/c$c/eall/sall" show all 2>/dev/null || true)
        if ! grep -q '^Drive /c' <<<"$out"; then
            out=$(run_priv "$HBA_TOOL" "/c$c/sall" show all 2>/dev/null || true)
        fi
        if ! grep -q '^Drive /c' <<<"$out"; then warn "$HBA_TOOL reported no drives on controller $c"; continue; fi
        while IFS='|' read -r kind e s model serial fw size state wwn; do
            [[ "$kind" == "D" ]] || continue
            add_drive "$c" "$e" "$s" "$model" "$serial" "$fw" "$size" "$state" "$wwn"
            [[ -n "${ENC_SLOTS[$c:$e]+x}" ]] || add_enclosure "$c" "$e" 0 0
        done < <(awk '
            function kv(s) { sub(/^[^=]*=[ \t]*/, "", s); sub(/[ \t]+$/, "", s); return s }
            function tb(num, unit) { u = toupper(unit); f = 1
                if (u == "GB") f = 1/1024; else if (u == "MB") f = 1/1048576; else if (u == "PB") f = 1024
                return sprintf("%.2f", num * f) }
            function flush() {
                if (have) printf "D|%s|%s|%s|%s|%s|%s|%s|%s\n", e, s, model, sn, fw, size, st, wwn
                have = 0; model = sn = fw = size = st = wwn = ""
            }
            /^Drive \/c[0-9]+(\/e[0-9]+)?\/s[0-9]+ :[ \t]*$/ {
                flush(); have = 1; path = $2
                e = "-"; if (match(path, /\/e[0-9]+/)) e = substr(path, RSTART + 2, RLENGTH - 2)
                match(path, /\/s[0-9]+/); s = substr(path, RSTART + 2, RLENGTH - 2); next }
            have && $1 ~ /^[0-9]*:[0-9]+$/ && $2 ~ /^[0-9]+$/ {
                m = $3
                st = (m == "Onln") ? "Online" : (m == "Offln") ? "Offline" : (m == "UGood") ? "Unconfigured Good" : \
                     (m == "UBad") ? "Unconfigured Bad" : (m == "Rbld") ? "Rebuilding" : (m == "GHS") ? "Global Hot Spare" : \
                     (m == "DHS") ? "Dedicated Hot Spare" : (m == "Msng") ? "Missing" : (m == "Cpybck") ? "Copyback" : m
                size = tb($5, $6) }
            have && /^SN[ \t]*=/                { sn = kv($0) }
            have && /^Model Number[ \t]*=/      { model = kv($0) }
            have && /^Firmware Revision[ \t]*=/ { fw = kv($0) }
            have && /^WWN[ \t]*=/               { wwn = kv($0) }
            END { flush() }
        ' <<<"$out")
    done
}

collect_ses() {
    local encdir elem slot blk dev status e=0 n start
    for encdir in "$SYSFS_ENCLOSURE"/*; do
        [[ -d "$encdir" ]] || continue
        n=0; start=""
        for elem in "$encdir"/*; do
            [[ -d "$elem" ]] || continue
            slot=""
            if [[ -r "$elem/slot" ]]; then slot=$(<"$elem/slot")
            elif [[ "$(basename "$elem")" =~ ^(Slot|Disk|Drive|SLOT|DISK|ArrayDevice)?[^0-9]*([0-9]+)$ ]]; then slot=$((10#${BASH_REMATCH[2]}))
            fi
            is_uint "$slot" || continue
            n=$((n + 1))
            if [[ -z "$start" ]] || (( slot < start )); then start=$slot; fi
            blk=""
            if [[ -d "$elem/device/block" ]]; then blk=$(ls "$elem/device/block" 2>/dev/null | head -n1 || true); fi
            [[ -n "$blk" ]] || continue
            dev="/dev/$blk"
            status="Present"; [[ -r "$elem/status" ]] && status=$(<"$elem/status")
            add_drive 0 "$e" "$slot" "${DEV_MODEL[$dev]:-}" "${DEV_SERIAL[$dev]:-}" "${DEV_FW[$dev]:-}" \
                      "${DEV_SIZE[$dev]:-}" "$status" "${DEV_WWN[$dev]:-}"
            D_DEV[NDRIVES-1]="$dev"
        done
        if (( n > 0 )); then add_enclosure 0 "$e" "$n" "${start:-0}"; e=$((e + 1)); fi
    done
    if (( NDRIVES == 0 )); then
        warn "no populated slots found under $SYSFS_ENCLOSURE; falling back to positional listing"
        BACKEND="none"; ENC_ORDER=(); ENC_SLOTS=(); ENC_START=()
    fi
}

# Map every drive to a device / array / role
match_drives() {
    local i dev disk
    for ((i = 0; i < NDRIVES; i++)); do
        dev="${D_DEV[i]}"
        if [[ "$dev" == "-" ]]; then dev=$(lookup_dev "${D_WWN[i]}" "${D_SERIAL[i]}"); D_DEV[i]="$dev"; fi
        [[ "$dev" == "-" ]] && continue
        DEV_SEEN[$dev]=1
        D_ARRAY[i]="${DEV_ARRAY[$dev]:--}"
        D_ROLE[i]="${DEV_ROLE[$dev]:--}"
    done
    # Disks not behind the HBA (boot drives, onboard SATA, NVMe) or the whole system when no HBA
    local pos=0
    for disk in "${DISKS[@]}"; do
        [[ -n "${DEV_SEEN[$disk]:-}" ]] && continue
        if [[ "$BACKEND" == "none" ]]; then
            add_drive 0 0 "$pos" "${DEV_MODEL[$disk]}" "${DEV_SERIAL[$disk]}" "${DEV_FW[$disk]}" \
                      "${DEV_SIZE[$disk]}" "Present" "${DEV_WWN[$disk]}"
            pos=$((pos + 1))
        else
            add_drive "-" "-" "-" "${DEV_MODEL[$disk]}" "${DEV_SERIAL[$disk]}" "${DEV_FW[$disk]}" \
                      "${DEV_SIZE[$disk]}" "Present" "${DEV_WWN[$disk]}"
        fi
        i=$((NDRIVES - 1))
        D_DEV[i]="$disk"; D_ARRAY[i]="${DEV_ARRAY[$disk]:--}"; D_ROLE[i]="${DEV_ROLE[$disk]:--}"
    done
    if [[ "$BACKEND" == "none" ]] && (( pos > 0 )); then add_enclosure 0 0 "$pos" 0; fi
}

# ------------------------------------------------------------------------------
# mdadm
# ------------------------------------------------------------------------------
parent_disk() {
    local d="$1"
    if [[ "$d" =~ ^(/dev/nvme[0-9]+n[0-9]+)p[0-9]+$ ]]; then d="${BASH_REMATCH[1]}"
    elif [[ "$d" =~ ^(/dev/(sd|vd|xvd|hd)[a-z]+)[0-9]+$ ]]; then d="${BASH_REMATCH[1]}"
    fi
    printf '%s' "$d"
}

build_md_map() {
    [[ -r "$MDSTAT_FILE" ]] || return 0
    mapfile -t MD_LIST < <(awk '/^md[^ ]* *:/ {print $1}' "$MDSTAT_FILE" | sort -uV)
    ((${#MD_LIST[@]})) || return 0
    if ! command -v mdadm >/dev/null 2>&1; then warn "mdadm not found; RAID details unavailable"; MD_LIST=(); return 0; fi
    local md info name dev role disk
    for md in "${MD_LIST[@]}"; do
        info=$(run_priv mdadm --detail "/dev/$md" 2>/dev/null || true)
        MD_DETAIL[$md]="$info"
        name=$(awk -F' : ' '/^ *Name :/{print $2; exit}' <<<"$info")
        name="${name%% (*}"; name="${name##*:}"; name="${name// /}"
        MD_NAME[$md]="${name:-$md}"
        while read -r role dev; do
            disk=$(parent_disk "$dev")
            if [[ -n "${DEV_ARRAY[$disk]:-}" && ",${DEV_ARRAY[$disk]}," != *",${MD_NAME[$md]},"* ]]; then
                DEV_ARRAY[$disk]+=",${MD_NAME[$md]}"
            else
                DEV_ARRAY[$disk]="${MD_NAME[$md]}"
            fi
            # Worst role wins when a disk has partitions in several arrays
            case "${DEV_ROLE[$disk]:-}:$role" in
                faulty:*|*:faulty) DEV_ROLE[$disk]="faulty" ;;
                rebuilding:*|*:rebuilding) DEV_ROLE[$disk]="rebuilding" ;;
                active:*|*:active) DEV_ROLE[$disk]="active" ;;
                *) DEV_ROLE[$disk]="$role" ;;
            esac
        done < <(awk 'NF >= 5 && $1 ~ /^[0-9-]+$/ && $NF ~ /^\/dev\// {
                    r = "active"
                    if ($0 ~ /faulty/) r = "faulty"; else if ($0 ~ /rebuilding/) r = "rebuilding"; else if ($0 ~ /spare/) r = "spare"
                    print r, $NF }' <<<"$info")
    done
}

# ------------------------------------------------------------------------------
# SMART
# ------------------------------------------------------------------------------
HAVE_SMART=0
collect_smart() {
    (( OPT_SMART )) || return 0
    if ! command -v smartctl >/dev/null 2>&1; then
        (( OPT_WIDE )) && warn "--wide requested but smartctl is not installed (apt/dnf install smartmontools)"
        return 0
    fi
    HAVE_SMART=1
    local i dev out
    for ((i = 0; i < NDRIVES; i++)); do
        dev="${D_DEV[i]}"
        [[ "$dev" == "-" ]] && continue
        out=$(run_priv smartctl -H -A "$dev" 2>/dev/null || true)
        [[ -n "$out" ]] || continue
        read -r "D_HEALTH[i]" "D_TEMP[i]" < <(awk '
            /overall-health self-assessment test result:/ { h = $NF }
            /SMART Health Status:/                        { h = $NF }
            $2 == "Temperature_Celsius" && t == ""        { t = $10 }
            $2 == "Airflow_Temperature_Cel" && t == ""    { t = $10 }
            /Current Drive Temperature:/                  { t = $4 }
            /^Temperature:/ && t == ""                    { t = $2 }
            END { if (h == "") h = "-"; else if (h != "PASSED" && h != "OK") h = "FAILED"
                  if (t == "") t = "-"; print h, t }' <<<"$out")
    done
}

# ------------------------------------------------------------------------------
# Output: drive table
# ------------------------------------------------------------------------------
print_drive_table() {
    local hdr fmt i st health temp extra_h="" sep_len=146
    fmt="%-4s %-4s %-4s %-14s %-22.22s %-20.20s %-8.8s %-7s "
    section "Drives (backend: $BACKEND${HBA_TOOL:+ via $HBA_TOOL}${CONTROLLERS[*]:+, controller(s): ${CONTROLLERS[*]}})"
    if (( HAVE_SMART )); then extra_h+=$(printf '%-7s ' "Health"); sep_len=$((sep_len + 8)); fi
    if (( HAVE_SMART && OPT_WIDE )); then extra_h+=$(printf '%-5s ' "Temp"); sep_len=$((sep_len + 6)); fi
    hdr=$(printf "$fmt" "Ctl" "Encl" "Slot" "Device" "Model" "Serial" "FW" "SizeTB")
    printf '%s%s%-20s %s%-16s %-10s%s\n' "$BOLD" "$hdr" "State" "$extra_h" "Array" "Role" "$RESET"
    repeat_char "-" "$sep_len"; echo
    if (( NDRIVES == 0 )); then echo " (no drives found)"; return; fi
    for ((i = 0; i < NDRIVES; i++)); do
        printf "$fmt" "${D_CTRL[i]}" "${D_ENCL[i]}" "${D_SLOT[i]}" "${D_DEV[i]}" "${D_MODEL[i]}" \
               "${D_SERIAL[i]}" "${D_FW[i]}" "${D_SIZE[i]}"
        st=$(printf '%-20.20s' "${D_STATE[i]}"); color_state "$st" "${D_STATE[i]}"; printf ' '
        if (( HAVE_SMART )); then
            health=$(printf '%-7s' "${D_HEALTH[i]}")
            if [[ "${D_HEALTH[i]}" == "-" ]]; then printf '%s ' "$health"; else color_state "$health" "${D_HEALTH[i]}"; printf ' '; fi
        fi
        if (( HAVE_SMART && OPT_WIDE )); then
            temp="${D_TEMP[i]}"; [[ "$temp" != "-" ]] && temp+="C"
            if (( USE_COLOR )) && is_uint "${D_TEMP[i]}" && (( D_TEMP[i] >= 50 )); then
                printf '%s%-5s%s ' "$FG_RED" "$temp" "$RESET"
            else
                printf '%-5s ' "$temp"
            fi
        fi
        printf '%-16s ' "${D_ARRAY[i]}"
        st=$(printf '%-10s' "${D_ROLE[i]}"); color_state "$st" "${D_ROLE[i]/spare/}"; echo
    done
}

# ------------------------------------------------------------------------------
# Output: bay visualization
# ------------------------------------------------------------------------------
bay_status() {  # index -> single letter code
    local i=$1 s="${D_STATE[$1],,}" r="${D_ROLE[$1]}"
    if [[ "$r" == "faulty" || "$s" =~ fail|offl|ubad|unconfigured\ bad|missing|msng|faulty ]]; then echo F
    elif [[ "$r" == "rebuilding" || "$s" =~ rbld|rebuild ]]; then echo B
    elif [[ "$r" == "spare" || "$s" =~ hot\ spare|hsp|\(ghs\)|\(dhs\) ]]; then echo S
    elif [[ "$r" == "active" || "$s" =~ optimal|\(opt\)|^online ]]; then echo R
    else echo P
    fi
}

print_bay_viz() {
    local key ctrl encl nslots start maxslot bays cols rows w i slot code cell row_str
    local -A slot_idx=()
    for ((i = 0; i < NDRIVES; i++)); do
        [[ "${D_SLOT[i]}" == "-" ]] && continue
        slot_idx["${D_CTRL[i]}:${D_ENCL[i]}:${D_SLOT[i]}"]=$i
    done

    if ((${#ENC_ORDER[@]} == 0)); then
        section "Drive Bay Layout"
        echo " No enclosure/bay information available."
        return
    fi

    for key in "${ENC_ORDER[@]}"; do
        ctrl="${key%%:*}"; encl="${key#*:}"
        nslots="${ENC_SLOTS[$key]:-0}"; start="${ENC_START[$key]:-0}"
        is_uint "$start" || start=0
        maxslot=-1
        for ((i = 0; i < NDRIVES; i++)); do
            if [[ "${D_CTRL[i]}:${D_ENCL[i]}" == "$key" ]] && is_uint "${D_SLOT[i]}" && (( D_SLOT[i] > maxslot )); then
                maxslot=${D_SLOT[i]}
            fi
        done
        (( maxslot < 0 )) && [[ "$nslots" == "0" ]] && continue   # enclosure with no drives and no slot info

        if [[ -n "$OPT_BAYS" ]]; then bays=$OPT_BAYS
        elif is_uint "$nslots" && (( nslots > 0 )); then bays=$nslots
        else bays=$(( maxslot - start + 1 )); (( bays < 8 )) && bays=8
        fi
        # never hide a populated slot
        (( maxslot - start + 1 > bays )) && bays=$(( maxslot - start + 1 ))

        if [[ -n "$OPT_COLS" ]]; then cols=$OPT_COLS
        elif (( bays <= 8 )); then cols=$(( (bays + 1) / 2 ))
        else rows=$(( (bays + 11) / 12 )); cols=$(( (bays + rows - 1) / rows ))
        fi
        (( cols > bays )) && cols=$bays
        rows=$(( (bays + cols - 1) / cols ))

        w=${#start}; (( ${#maxslot} > w )) && w=${#maxslot}; (( ${#bays} > w )) && w=${#bays}
        local last=$(( start + bays - 1 )); (( ${#last} > w )) && w=${#last}
        local cellw=$(( w + 2 )); (( ! USE_COLOR )) && cellw=$(( w + 4 ))
        local inner=$(( cols * cellw + (cols - 1) + 2 ))

        local title="Drive Bay Layout — "
        case "$BACKEND" in
            none) title+="positional (no enclosure mapping), $bays disk(s)" ;;
            ses)  title+="SES enclosure $encl ($bays bays, ${rows}x$cols)" ;;
            *)    title+="controller $ctrl, enclosure $encl ($bays bays, ${rows}x$cols, slots $start-$last)" ;;
        esac
        section "$title"

        printf '  %s%s%s\n' "$BOX_TL" "$(repeat_char "$BOX_H" "$inner")" "$BOX_TR"
        local r c
        for ((r = 0; r < rows; r++)); do
            row_str=" "
            for ((c = 0; c < cols; c++)); do
                slot=$(( start + r * cols + c ))
                (( c > 0 )) && row_str+=" "
                if (( slot > last )); then row_str+=$(repeat_char " " "$cellw"); continue; fi
                i="${slot_idx[$key:$slot]:-}"
                if [[ -n "$i" ]]; then code=$(bay_status "$i"); else code="."; fi
                local label; label=$(printf '%0*d' "$w" "$slot")
                if (( USE_COLOR )); then
                    case "$code" in
                        R) cell="${BOLD}${BG_GREEN}${FG_BLACK}[$label]${RESET}" ;;
                        S) cell="${BOLD}${BG_MAGENTA}${FG_BLACK}[$label]${RESET}" ;;
                        B) cell="${BOLD}${BG_BLUE}${FG_WHITE}[$label]${RESET}" ;;
                        F) cell="${BOLD}${BG_RED}${FG_WHITE}[$label]${RESET}" ;;
                        P) cell="${BOLD}${BG_YELLOW}${FG_BLACK}[$label]${RESET}" ;;
                        *) cell="${FG_CYAN}[$label]${RESET}" ;;
                    esac
                else
                    cell="[$label:$code]"
                fi
                row_str+="$cell"
            done
            printf '  %s%s %s\n' "$BOX_V" "$row_str" "$BOX_V"
        done
        printf '  %s%s%s\n' "$BOX_BL" "$(repeat_char "$BOX_H" "$inner")" "$BOX_BR"
    done

    echo
    if (( USE_COLOR )); then
        printf ' Legend: %s[N]%s RAID member  %s[N]%s Hot spare  %s[N]%s Rebuilding  %s[N]%s Failed  %s[N]%s Populated (non-RAID)  %s[N]%s Empty\n' \
            "${BOLD}${BG_GREEN}${FG_BLACK}" "$RESET" "${BOLD}${BG_MAGENTA}${FG_BLACK}" "$RESET" \
            "${BOLD}${BG_BLUE}${FG_WHITE}" "$RESET" "${BOLD}${BG_RED}${FG_WHITE}" "$RESET" \
            "${BOLD}${BG_YELLOW}${FG_BLACK}" "$RESET" "$FG_CYAN" "$RESET"
    else
        echo " Legend: R=RAID member  S=Hot spare  B=Rebuilding  F=Failed  P=Populated (non-RAID)  .=Empty"
    fi
}

# ------------------------------------------------------------------------------
# Output: RAID summary
# ------------------------------------------------------------------------------
md_fields() {  # md -> level|size_gb|state|active|raid|failed
    awk -F' : ' '
        /Raid Level :/     { lvl = $2 }
        /Array Size :/     { split($2, a, " "); sz = sprintf("%.1f", a[1] / 1048576) }
        /^ *State :/       { st = $2 }
        /Active Devices :/ { act = $2 }
        /Raid Devices :/   { rd = $2 }
        /Failed Devices :/ { fd = $2 }
        END { gsub(/ +$/, "", st); printf "%s|%s|%s|%s|%s|%s\n", lvl, (sz == "" ? "-" : sz), st, act, rd, fd }
    ' <<<"${MD_DETAIL[$1]}"
}

md_progress() {
    awk -v md="$1" '
        $1 == md { inblk = 1; next }
        inblk && /^[ \t]*$/ { exit }
        inblk && /^md/ { exit }
        inblk && match($0, /(recovery|resync|reshape|check) *= *[0-9.]+%/) { s = substr($0, RSTART, RLENGTH); gsub(/ /, "", s); sub(/=/, " ", s); print s; exit }
        inblk && match($0, /resync=(DELAYED|PENDING)/) { print substr($0, RSTART, RLENGTH); exit }
    ' "$MDSTAT_FILE"
}

md_mount() {
    local md="$1" mp usage
    mp=$(lsblk -nro MOUNTPOINT "/dev/$md" 2>/dev/null | awk 'NF && $0 != "[SWAP]"' | head -n1 || true)
    if [[ -z "$mp" ]] && lsblk -nro MOUNTPOINT "/dev/$md" 2>/dev/null | grep -q '^\[SWAP\]$'; then echo "swap"; return; fi
    if [[ -z "$mp" ]]; then echo "unmounted"; return; fi
    mp=$(printf '%b' "$mp")  # lsblk escapes spaces as \x20
    usage=$(df -hP "$mp" 2>/dev/null | awk 'NR == 2 {printf "%s/%s %s", $3, $2, $5}' || true)
    echo "$mp${usage:+ ($usage)}"
}

print_raid_summary() {
    section "RAID Array Summary (mdadm)"
    if ((${#MD_LIST[@]} == 0)); then echo " No mdadm arrays found."; return; fi
    local fmt="%-14s %-8s %-9s " md level size st act rd fd state prog members spares mnt line
    printf '%s'"$fmt"'%-28s %-24s %-14s %s%s\n' "$BOLD" "Array" "Level" "SizeGiB" "State" "Members" "HotSpare" "Mount/Usage" "$RESET"
    repeat_char "-" 125; echo
    for md in "${MD_LIST[@]}"; do
        IFS='|' read -r level size st act rd fd < <(md_fields "$md")
        local lst="${st,,}"
        if [[ "$lst" == *fail* || -z "$st" && -z "$level" ]]; then state="FAILED"
        elif [[ "$lst" == *inactive* ]]; then state="inactive"
        elif { is_uint "$fd" && (( fd > 0 )); } || [[ "$lst" == *degraded* ]] || \
             { is_uint "$act" && is_uint "$rd" && (( act < rd )); }; then
            state="degraded"; is_uint "$fd" && (( fd > 0 )) && state+=" ($fd failed)"
        else state="${st%%,*}"; state="${state:-unknown}"
        fi
        prog=$(md_progress "$md"); [[ -n "$prog" ]] && state+=" [$prog]"

        members=(); spares=()
        while read -r role dev; do
            case "$role" in
                spare) spares+=("${dev#/dev/}") ;;
                faulty) members+=("${dev#/dev/}(F)") ;;
                rebuilding) members+=("${dev#/dev/}(R)") ;;
                *) members+=("${dev#/dev/}") ;;
            esac
        done < <(awk 'NF >= 5 && $1 ~ /^[0-9-]+$/ && $NF ~ /^\/dev\// {
                    r = "active"
                    if ($0 ~ /faulty/) r = "faulty"; else if ($0 ~ /rebuilding/) r = "rebuilding"; else if ($0 ~ /spare/) r = "spare"
                    print r, $NF }' <<<"${MD_DETAIL[$md]}")
        mnt=$(md_mount "$md")

        local name="${MD_NAME[$md]}"; [[ "$name" != "$md" ]] && name="$name ($md)"
        local sp="${spares[*]:-}"; sp="${sp:--}"
        local -a lines=()
        local j chunk=""
        for ((j = 0; j < ${#members[@]}; j++)); do
            chunk+="${members[j]} "
            if (( (j + 1) % 4 == 0 )); then lines+=("$chunk"); chunk=""; fi
        done
        [[ -n "$chunk" ]] && lines+=("$chunk")
        ((${#lines[@]})) || lines=("-")

        printf "$fmt" "$name" "$level" "$size"
        line=$(printf '%-28s' "$state"); color_state "$line" "$state"
        printf ' %-24s %-14s %s\n' "${lines[0]}" "$sp" "$mnt"
        for ((j = 1; j < ${#lines[@]}; j++)); do
            printf "$fmt"'%-28s %-24s\n' "" "" "" "" "${lines[j]}"
        done
    done
}

# ------------------------------------------------------------------------------
# Output: JSON
# ------------------------------------------------------------------------------
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/\\t}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"
    printf '"%s"' "$s"
}
json_val() { if [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; then printf '%s' "$1"; elif [[ "$1" == "-" || -z "$1" ]]; then printf 'null'; else json_str "$1"; fi; }

print_json() {
    local i sep="" md level size st act rd fd
    printf '{\n  "version": %s,\n  "host": %s,\n  "backend": %s,\n  "tool": %s,\n  "controllers": [' \
        "$(json_str "$VERSION")" "$(json_str "$(hostname 2>/dev/null || echo unknown)")" \
        "$(json_str "$BACKEND")" "$(json_val "$HBA_TOOL")"
    for i in "${CONTROLLERS[@]}"; do printf '%s%s' "$sep" "$i"; sep=", "; done
    printf '],\n  "drives": ['
    sep=""
    for ((i = 0; i < NDRIVES; i++)); do
        printf '%s\n    {"controller": %s, "enclosure": %s, "slot": %s, "device": %s, "model": %s, "serial": %s, ' \
            "$sep" "$(json_val "${D_CTRL[i]}")" "$(json_val "${D_ENCL[i]}")" "$(json_val "${D_SLOT[i]}")" \
            "$(json_val "${D_DEV[i]}")" "$(json_val "${D_MODEL[i]}")" "$(json_str "${D_SERIAL[i]}")"
        printf '"firmware": %s, "size_tb": %s, "state": %s, "wwn": %s, "array": %s, "role": %s, "health": %s, "temperature_c": %s}' \
            "$(json_str "${D_FW[i]}")" "$(json_val "${D_SIZE[i]}")" "$(json_val "${D_STATE[i]}")" \
            "$(json_val "${D_WWN[i]}")" "$(json_val "${D_ARRAY[i]}")" "$(json_val "${D_ROLE[i]}")" \
            "$(json_val "${D_HEALTH[i]}")" "$(json_val "${D_TEMP[i]}")"
        sep=","
    done
    printf '\n  ],\n  "arrays": ['
    sep=""
    for md in "${MD_LIST[@]}"; do
        IFS='|' read -r level size st act rd fd < <(md_fields "$md")
        printf '%s\n    {"device": %s, "name": %s, "level": %s, "size_gib": %s, "state": %s, "active_devices": %s, "raid_devices": %s, "failed_devices": %s, "progress": %s}' \
            "$sep" "$(json_str "/dev/$md")" "$(json_str "${MD_NAME[$md]}")" "$(json_val "$level")" "$(json_val "$size")" \
            "$(json_val "$st")" "$(json_val "$act")" "$(json_val "$rd")" "$(json_val "$fd")" "$(json_val "$(md_progress "$md")")"
        sep=","
    done
    printf '\n  ]\n}\n'
}

# ------------------------------------------------------------------------------
# Dry run: executes NOTHING. Only uses `command -v`, file tests, reads
# $MDSTAT_FILE and lists $SYSFS_ENCLOSURE. Prints what a real run would do.
# ------------------------------------------------------------------------------
tool_status() {  # name purpose -> one formatted line; returns 0 if usable
    local name="$1" purpose="$2" path status rc=1
    path=$(command -v "$name" 2>/dev/null || true)
    if [[ -z "$path" ]]; then status="missing"; path="-"
    elif [[ "$path" == /* && ! -x "$path" ]]; then status="NOT EXECUTABLE"
    else status="ok"; rc=0
    fi
    printf '  %-11s %-15s %-36s %s\n' "$name" "$status" "$path" "$purpose"
    return $rc
}

dry_run_report() {
    local p="${SUDO[*]}${SUDO[*]:+ }" t first="" storcli_tool="" md_list=() n_ses=0
    echo "$PROG $VERSION — DRY RUN (no commands executed, no files written)"
    echo
    echo "Environment"
    if (( EUID == 0 )); then echo "  Running as root; privileged commands run directly"
    elif ((${#SUDO[@]})); then echo "  Running as ${USER:-uid $EUID}; privileged commands run via: sudo (may prompt for a password)"
    else echo "  Running as uid $EUID without sudo; HBA, mdadm and SMART queries will likely fail"
    fi
    if [[ -r "$MDSTAT_FILE" ]]; then
        mapfile -t md_list < <(awk '/^md[^ ]* *:/ {print $1}' "$MDSTAT_FILE" | sort -uV)
        echo "  $MDSTAT_FILE: ${#md_list[@]} md array(s)${md_list[*]:+: ${md_list[*]}}"
    else
        echo "  $MDSTAT_FILE: not readable (no md driver loaded?)"
    fi
    local ses_entries=()
    mapfile -t ses_entries < <(compgen -G "$SYSFS_ENCLOSURE/*" || true)
    n_ses=${#ses_entries[@]}
    echo "  $SYSFS_ENCLOSURE: $n_ses SES enclosure(s)"
    echo
    echo "Tools"
    printf '  %-11s %-15s %-36s %s\n' "TOOL" "STATUS" "PATH" "USED FOR"
    for t in sas3ircu sas2ircu; do
        if tool_status "$t" "LSI SAS3/SAS2 HBA backend" && [[ -z "$first" ]]; then first="$t"; fi
    done
    for t in storcli64 storcli perccli64 perccli; do
        if tool_status "$t" "MegaRAID / tri-mode HBA backend" && [[ -z "$storcli_tool" ]]; then storcli_tool="$t"; fi
    done
    tool_status lsblk    "disk discovery (REQUIRED)" || true
    tool_status udevadm  "WWN / serial matching"     || true
    tool_status mdadm    "RAID membership & state"   || true
    tool_status smartctl "SMART health / temperature" || true
    tool_status sudo     "privilege escalation"      || true
    echo
    echo "Backend selection (--backend $OPT_BACKEND)"
    case "$OPT_BACKEND" in
        auto)
            echo "  Tried in order, first one that reports a controller wins:"
            echo "    sas3ircu -> sas2ircu -> storcli/perccli -> ses ($n_ses found) -> none"
            if [[ -n "$first" ]]; then echo "  Would try first: $first"
            elif [[ -n "$storcli_tool" ]]; then echo "  Would try first: $storcli_tool"
            elif (( n_ses )); then echo "  Would use: ses (kernel enclosure slots)"
            else echo "  Would use: none (positional list, no physical bay mapping)"
            fi ;;
        storcli) echo "  Forced: storcli via ${storcli_tool:-<not installed: real run would abort>}" ;;
        *)       echo "  Forced: $OPT_BACKEND" ;;
    esac
    echo
    echo "Commands a real run may execute (all read-only queries; backends stop at the first that finds a controller)"
    local c="${OPT_CONTROLLER:-<N>}" each=""
    [[ -n "$OPT_CONTROLLER" ]] || each="   (for each controller)"
    if [[ "$OPT_BACKEND" =~ ^(auto|sas3ircu|sas2ircu)$ ]]; then
        for t in sas3ircu sas2ircu; do
            [[ "$OPT_BACKEND" == auto || "$OPT_BACKEND" == "$t" ]] || continue
            command -v "$t" >/dev/null 2>&1 || continue
            echo "  ${p}$t LIST"
            echo "  ${p}$t $c display$each"
        done
    fi
    if [[ "$OPT_BACKEND" =~ ^(auto|storcli)$ && -n "$storcli_tool" ]]; then
        echo "  ${p}$storcli_tool show ctrlcount"
        echo "  ${p}$storcli_tool /c$c/eall show$each"
        echo "  ${p}$storcli_tool /c$c/eall/sall show all$each"
        echo "  ${p}$storcli_tool /c$c/sall show all   (only if the previous returns nothing)"
    fi
    if [[ "$OPT_BACKEND" =~ ^(auto|ses)$ ]] && (( n_ses )); then
        echo "  (reads files under $SYSFS_ENCLOSURE — no commands)"
    fi
    echo "  lsblk -dnpo NAME,TYPE"
    command -v udevadm >/dev/null 2>&1 && echo "  udevadm info --query=property --name=<disk>   (for each disk)"
    echo "  lsblk -dnbo SIZE <disk>                       (for each disk)"
    if ((${#md_list[@]})) && command -v mdadm >/dev/null 2>&1; then
        for t in "${md_list[@]}"; do echo "  ${p}mdadm --detail /dev/$t"; done
        if (( OPT_RAID && ! OPT_JSON )); then
            echo "  lsblk -nro MOUNTPOINT /dev/<md>; df -hP <mountpoint>   (for each array)"
        fi
    fi
    if (( OPT_SMART )) && command -v smartctl >/dev/null 2>&1; then
        echo "  ${p}smartctl -H -A <disk>                    (for each bay-matched disk; reads status only, starts no tests)"
    fi
    (( OPT_JSON )) && echo "  hostname"
    echo
    echo "Nothing is ever written: no files, no temp files, no config, no HBA/RAID/SMART changes."
    echo "Re-run without --dry-run (optionally with --trace) to perform the queries above."
    command -v lsblk >/dev/null 2>&1 || { warn "lsblk is missing — a real run would abort"; return 1; }
    return 0
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    exec 3>&2
    parse_args "$@"
    setup_colors
    setup_sudo
    if (( OPT_DRY_RUN )); then dry_run_report; return; fi

    command -v lsblk >/dev/null 2>&1 || die "lsblk (util-linux) is required"

    detect_backend
    if [[ "$BACKEND" =~ ^(sas3ircu|sas2ircu|storcli)$ ]] && ((${#CONTROLLERS[@]} == 0)); then detect_controllers; fi
    [[ "$BACKEND" == "ses" ]] && detect_controllers
    if [[ "$BACKEND" =~ ^(sas3ircu|sas2ircu|storcli)$ ]] && ((${#CONTROLLERS[@]} == 0)); then
        warn "$HBA_TOOL found no controllers; showing disks positionally"
        BACKEND="none"
    fi
    if [[ "$BACKEND" == "none" ]]; then
        (( OPT_JSON )) || warn "no supported SAS HBA or SES enclosure detected; bay positions are not physical slots"
    fi

    build_wwn_cache
    build_md_map
    case "$BACKEND" in
        sas3ircu|sas2ircu) collect_ircu ;;
        storcli)           collect_storcli ;;
        ses)               collect_ses ;;
    esac
    match_drives
    collect_smart

    if (( OPT_JSON )); then print_json; return 0; fi
    print_drive_table
    (( OPT_VIZ ))  && print_bay_viz
    (( OPT_RAID )) && print_raid_summary
    echo
    return 0
}

main "$@"
