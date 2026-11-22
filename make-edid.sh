#!/bin/bash
# Build an EDID blob whose preferred mode matches an iPad panel's aspect ratio.
#
#   ./make-edid.sh --list
#   ./make-edid.sh ipad-air-11 [--native] [out.bin]
#   ./make-edid.sh 1920x1334 [out.bin]        # arbitrary WxH (=2.5 identical to preset)
#   ./make-edid.sh 1920 1334 60 [out.bin]     # explicit W H refresh
#
# Output defaults to edid/custom.bin. Every blob also gets 1600x1200 and 1920x1080 as
# fallback modes (unless they equal the preferred mode), so a bad pick is never fatal:
# you can always `kscreen-doctor output.<CONN>.mode.1920x1080@60`.
set -euo pipefail
cd "$(dirname "$0")"

declare -A PANEL=(
    [ipad-air-11]="2360x1640"      # iPad Air 11" M2/M3, iPad 10/11
    [ipad-mini]="2266x1488"        # iPad mini 6/7
    [ipad-pro-11-m4]="2420x1668"   # iPad Pro 11" M4
    [ipad-4x3]="2048x1536"         # iPad Pro 12.9", Air 13", iPad 9 (exactly 4:3)
)
declare -A STREAM=(
    [ipad-air-11]="1920x1334"      # 1.4389
    [ipad-mini]="1920x1264"        # 1.5190
    [ipad-pro-11-m4]="1920x1324"   # 1.4502
    [ipad-4x3]="1920x1440"         # 1.3333
)

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[ $# -ge 1 ] || usage 1
case "$1" in -h|--help|help) usage 0 ;; --list)
    printf '%-16s %-12s %-12s %s\n' preset stream panel model
    printf '%-16s %-12s %-12s %s\n' ipad-air-11 1920x1334 2360x1640 'iPad Air 11" M2/M3, iPad 10/11'
    printf '%-16s %-12s %-12s %s\n' ipad-mini 1920x1264 2266x1488 'iPad mini 6/7'
    printf '%-16s %-12s %-12s %s\n' ipad-pro-11-m4 1920x1324 2420x1668 'iPad Pro 11" M4'
    printf '%-16s %-12s %-12s %s\n' ipad-4x3 1920x1440 2048x1536 'iPad Pro 12.9", Air 13", iPad 9'
    echo
    echo "add --native to use the panel resolution itself (pixel-perfect, higher clock)"
    exit 0 ;;
esac

native=0
args=()
for a in "$@"; do
    case "$a" in --native) native=1 ;; *) args+=("$a") ;; esac
done
set -- "${args[@]}"
refresh=60
out=""

if [ -n "${STREAM[$1]:-}" ]; then
    preset="$1"; shift
    if [ "$native" = 1 ]; then
        pw=${PANEL[$preset]%x*}; ph=${PANEL[$preset]#*x}
        w=$(( (pw + 4) / 8 * 8 ))                       # nearest multiple of 8
        h=$(( (w * ph + pw / 2) / pw ))                 # same aspect, integer height
        target=("$w" "$h")
    else
        target=(${STREAM[$preset]//x/ })
    fi
    out="${1:-edid/custom.bin}"
elif [ $# -ge 2 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
    refresh="${3:-60}"; target=("$1" "$2")
    out="${4:-edid/custom.bin}"
elif [[ "$1" =~ ^[0-9]+x[0-9]+$ ]]; then
    target=(${1//x/ }); out="${2:-edid/custom.bin}"
else
    echo "unknown preset/geometry: $1" >&2; usage 1
fi

w=${target[0]} h=${target[1]}
[ $(( w % 8 )) -eq 0 ] || { echo "width must be a multiple of 8 (CVT granularity); $w is not" >&2; exit 1; }

extras=()
for e in 1600x1200 1920x1080; do
    [ "$e" = "${w}x${h}" ] || extras+=("$e")
done

mkdir -p "$(dirname "$out")"
python3 gen_edid.py "$w" "$h" "$refresh" "$out" "${extras[@]}"
echo
echo "installed nothing yet - next:"
echo "  sudo ./install.sh $out <CONNECTOR>          # e.g. DP-4"
echo "  kscreen-doctor output.<CONNECTOR>.mode.${w}x${h}@${refresh}"
