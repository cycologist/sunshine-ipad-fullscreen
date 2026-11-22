#!/bin/bash
# Install a custom EDID for one DRM connector and keep it applied across reboots and
# hotplug events (e.g. a flaky USB-C/HDMI expansion card resetting on the bus).
#
# usage: sudo ./install.sh [edid.bin] [CONNECTOR]
#        defaults: edid/custom.bin (or edid/ipad-air-11.bin), CONNECTOR=DP-4
#
# Touches no bootloader, no kernel command line, no modprobe config: it only writes
# /sys/kernel/debug/dri/<card>/<CONNECTOR>/edid_override at runtime, plus a systemd
# oneshot + udev rule that repeat that write when needed.
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOB="${1:-}"
if [ -z "$BLOB" ]; then
    for c in "$HERE/edid/custom.bin" "$HERE/edid/ipad-air-11.bin"; do
        [ -r "$c" ] && { BLOB="$c"; break; }
    done
fi
[ -n "$BLOB" ] && [ -r "$BLOB" ] || { echo "no EDID blob found; run ./make-edid.sh first" >&2; exit 1; }
CONN="${2:-DP-4}"

size=$(stat -c%s "$BLOB")
[ "$size" = 128 ] || { echo "$BLOB is $size bytes, expected 128 (base EDID block)" >&2; exit 1; }

install -D -m 644 "$BLOB" "/usr/local/share/dp4-edid/$(basename "$BLOB")"
install -d -m 755 /usr/lib/firmware/edid
install -m 644 "$BLOB" "/usr/lib/firmware/edid/$(basename "$BLOB")"

cat > /etc/dp4-edid.conf <<EOF
# written by dp4-edid install.sh
CONNECTOR=$CONN
BLOB=/usr/local/share/dp4-edid/$(basename "$BLOB")
EOF
chmod 644 /etc/dp4-edid.conf

cat > /usr/local/bin/dp4-edid-apply.sh <<'EOS'
#!/bin/bash
# Idempotently apply the configured EDID to the configured DRM connector via debugfs.
# Safe to run at any time: does nothing when the override is already in place.
. /etc/dp4-edid.conf
[ -r "$BLOB" ] || exit 0
for _ in $(seq 1 20); do
    found=0
    for d in /sys/kernel/debug/dri/*/"$CONNECTOR"; do
        [ -d "$d" ] || continue
        found=1
        [ -w "$d/edid_override" ] || continue
        if ! cmp -s "$d/edid_override" "$BLOB" 2>/dev/null; then
            cat "$BLOB" > "$d/edid_override" || continue
            echo 1 > "$d/trigger_hotplug" 2>/dev/null || true
            logger -t dp4-edid "applied $(basename "$BLOB") to $d"
        fi
    done
    [ "$found" = 1 ] && exit 0
    sleep 1
done
logger -t dp4-edid "connector $CONNECTOR not found; nothing applied"
exit 0
EOS
chmod 755 /usr/local/bin/dp4-edid-apply.sh

cat > /etc/systemd/system/dp4-edid.service <<EOS
[Unit]
Description=Custom EDID for $CONN (dp4-edid)
After=sys-kernel-debug.mount systemd-udevd.service
Wants=sys-kernel-debug.mount

[Service]
Type=oneshot
ExecStart=/usr/local/bin/dp4-edid-apply.sh

[Install]
WantedBy=graphical.target
EOS

cat > /etc/udev/rules.d/90-dp4-edid.rules <<EOS
# Re-apply the $CONN EDID override whenever the connector is (re-)detected.
ACTION=="add|change", SUBSYSTEM=="drm", KERNEL=="card*", ENV{HOTPLUG}=="1", TAG+="systemd", ENV{SYSTEMD_WANTS}+="dp4-edid.service"
EOS

systemctl daemon-reload
systemctl enable dp4-edid.service >/dev/null
systemctl start dp4-edid.service || true
udevadm control --reload-rules
udevadm trigger --subsystem-match=drm
sleep 1

echo "== dp4-edid.service =="
systemctl status --no-pager --lines=2 dp4-edid.service | sed 's/^/   /' || true
echo
echo "== EDID now served for $CONN =="
for f in /sys/class/drm/card*-"$CONN"/edid; do
    [ -r "$f" ] && edid-decode "$f" 2>/dev/null | grep -E "Manufacturer|DTD [0-9]" | sed 's/^/   /'
done
echo
echo "== modes =="
modetest -M amdgpu -c 2>/dev/null | grep -E "^ +#[0-9]+ +(1920x1[0-9]{3}|1600x1200)" \
    | awk '{print "   "$2" @"$3}' | sort -u -V | head -8
echo
echo "Now select the mode (as your user, not root):"
echo "   kscreen-doctor output.$CONN.mode.<W>x<H>@60     # see DTD above"
