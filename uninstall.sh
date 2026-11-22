#!/bin/bash
# Remove everything install.sh created and drop the live EDID override.
# usage: sudo ./uninstall.sh
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }

rm -f /etc/udev/rules.d/90-dp4-edid.rules
systemctl disable --now dp4-edid.service 2>/dev/null || true
rm -f /etc/systemd/system/dp4-edid.service /usr/local/bin/dp4-edid-apply.sh /etc/dp4-edid.conf
rm -rf /usr/local/share/dp4-edid /usr/lib/firmware/edid
systemctl daemon-reload
udevadm control --reload-rules

# clear the live override: the connector keeps whatever we wrote until it is cleared
for f in /sys/kernel/debug/dri/*/*/edid_override; do
    [ -w "$f" ] && printf '' > "$f" && echo "cleared $f"
done
for f in /sys/kernel/debug/dri/*/*/trigger_hotplug; do
    [ -w "$f" ] && echo 1 > "$f"
done

echo "uninstalled. Re-pick a stock mode as your user, e.g."
echo "   kscreen-doctor output.DP-4.mode.1920x1080@60"
