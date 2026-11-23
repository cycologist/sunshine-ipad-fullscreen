# Troubleshooting

Symptom → cause → fix. Start with the fastest check: what is the host actually scanning out?

```bash
modetest -M amdgpu -p | grep -A2 '^3'      # crtc id from modetest -c
```

## Bars, in every combination

| what you see | meaning |
|---|---|
| bars top/bottom only | stream is *wider* than the panel (e.g. 16:9 on a 1.44 panel) |
| bars left/right only | stream is *taller* than the panel (e.g. 4:3 on a 1.44 panel) |
| bars on **all four** sides | the frame reached the client letterboxed inside a 16:9 canvas *and* the canvas is letterboxed on the panel — usually a **stale capture**: Sunshine kept the old mode from session start |
| thin bars (few px) on two sides | aspect rounding — pick a width (multiple of 8) that matches the panel ratio better, or use `--native` |

Fix for a stale capture: change the mode **first**, then (re)connect Moonlight. Or let the
Sunshine `prep-cmd` do it (`examples/apps.json.example`):

```json
"prep-cmd": [ { "do": "kscreen-doctor output.DP-4.mode.1920x1334@60", "undo": "" } ]
```

Confirm what the client really received with Moonlight's performance overlay
(*Show performance stats*): `Video: 1920x1334` means the host geometry arrived intact.

## `kscreen-doctor: Output mode 1920x1334@60 not found`

The mode is not in KWin's list yet:

```bash
sudo /usr/local/bin/dp4-edid-apply.sh                       # re-write override + hotplug
sudo edid-decode /sys/class/drm/card1-DP-4/edid | grep DTD  # is our blob there?
kscreen-doctor -o | grep -A6 DP-4                           # what KWin sees
```

If the EDID is ours but KWin still has no mode: toggle the output
(`kscreen-doctor output.DP-4.disable output.DP-4.enable`) or restart the compositor
(`systemctl --user restart plasma-kwin_wayland`, which logs you out).

## Black screen, cursor works fine

Textbook KWin DCC-retile buffer that Sunshine cannot import:

```bash
modetest -M amdgpu -p | grep -A2 '^3'   # look for modifier=0x200000010467b04 (bad)
```

Fix (needs compositor restart):

```ini
# ~/.config/systemd/user/plasma-kwin_wayland.service.d/50-sunshine-kmsgrab.conf
[Service]
Environment=KWIN_DRM_USE_MODIFIERS=0
Environment=KWIN_DRM_PREFER_COLOR_DEPTH=8
```

`0x200000010401b04` (plain DCC) and `0x0` (linear) import fine.

## Touch/mouse moves the pointer on the wrong screen (or not at all)

Two independent traps on KDE Wayland, both visible in `sunshine.log`:

1. **Wrong scale.** If KWin gave the output a fractional scale, Sunshine reports the
   *logical* size (`source=1536x1067`) while the pointer device's absolute space is the
   desktop. Absolute injection then lands proportionally — touches from the iPad activate
   windows on the laptop panel instead of the streamed output.
   Fix: `kscreen-doctor output.DP-4.scale.1` (logical size must equal the mode size).
2. **Non-zero offset.** Sunshine's absolute mouse path hands out viewport-relative
   coordinates (`viewport=1736,0`), so the streamed output has to sit at the desktop origin:
   `kscreen-doctor output.DP-4.position.0,0`. With DP-4 at `0,0` and scale 1, touch maps
   pixel-perfect.

Also verify Sunshine can actually inject: the `libvirtualhid*` devices must be readable by
the compositor's user (`event*` nodes are `root:input 0660` with no ACL by default — the
compositor opens seat devices through logind and cannot do that for uinput devices):

```bash
# /etc/udev/rules.d/91-libvirtualhid-input.rules
SUBSYSTEM=="input", ATTRS{name}=="libvirtualhid*", MODE="0660", GROUP="input", TAG+="uaccess"
ACTION=="add|change", SUBSYSTEM=="input", ATTRS{name}=="libvirtualhid*", RUN+="/usr/bin/setfacl -m u:$USER:rw /dev/%k"
```

Note that with absolute touch the pointer can never leave the streamed output — for a
pointer that roams across both screens use the client's relative-mouse/trackpad mode.

## Output vanished / went black after the EDID change

KWin disabled the connector because the mode it had stored no longer exists:

```bash
kscreen-doctor output.DP-4.enable
kscreen-doctor output.DP-4.mode.1920x1334@60
```

## `dp4-edid.service` is failed with `start-limit-hit`

The udev rule and the applier can feed each other: the applier pokes
`trigger_hotplug`, which is a DRM *change* event, which restarts the unit, which pokes
again. Fixes present in the current version, worth checking if you hand-edited anything:

* udev rule matches only `ACTION=="add"` (card creation / re-enumeration), not `"change"`,
* the applier writes **one** connector path and exits - DRM exposes the same connector twice
  (`dri/1/DP-4` and `dri/0000:c1:00.0/DP-4`), writing both doubles the hotplug poke,
* `flock` serialises overlapping runs,
* the unit sets `StartLimitIntervalSec=0`.

Recovery: `sudo systemctl reset-failed dp4-edid && sudo systemctl start dp4-edid`.

## The connector gets renamed (DP-4 → DP-1 …)

Connector numbering depends on probe order. If the dummy plug moves, the override, the
`sunshine.conf` `output_name` and the `prep-cmd` all point at the wrong name. Check with
`kscreen-doctor -o` / `ls /sys/class/drm/` and update:

```bash
sudo edit /etc/dp4-edid.conf        # CONNECTOR=...
sudo systemctl restart dp4-edid
```

## "usb 1-1: USB disconnect" every few minutes, stream dies

Not an EDID problem — a hardware/USB problem (common on USB-C/HDMI expansion cards, e.g.
Framework's). Mitigations, in order:

1. disable autosuspend for the card:
   ```udev
   # /etc/udev/rules.d/50-hdmi-card-power.rules
   ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="32ac", ATTR{idProduct}=="0002", ATTR{power/control}="on"
   ```
2. update the card firmware, reseat it, try another bay;
3. this repo's udev rule re-applies the EDID after each reset, so at least the modes come
   back — but a reset mid-stream still interrupts the session.

Watch for it with:

```bash
journalctl -k -f | grep -E 'usb .*disconnect|ucsi_acpi'
```

## Colour looks washed out / wrong range

Sunshine logs the negotiated colour config at session start:

```
Info: Color coding: SDR (Rec. 601)
Info: Color depth: 8-bit
Info: Color range: MPEG
```

`MPEG` = limited range. For a desktop it is nicer to have full range; that follows the EDID
(HDMI VSDB / CEA extension). The blobs generated here have no CEA extension, so most drivers
treat the sink as RGB full range. If you still see crushed blacks, force the range in the
client, or add a VSDB extension to the EDID.

## Performance / quality

* 1920x1334 at Sunshine's default ~7 Mbps is visibly soft: use **20–30 Mbps**.
* `hevc_vulkan` on AMD (RADV) is fine at 1334p60; if frames drop, try `h264_vulkan`.
* 4:4:4 chroma helps text enormously (`YUV 4:4:4` in Moonlight, costs bitrate).

## Nothing on the iPad but the host looks perfect

Check, in this order:

1. `modetest` plane shows the right size and no DCC-retile modifier,
2. Sunshine log shows `Mapped '<CONN>' to kmsgrab monitor index N` for the *right* monitor,
3. the mode is what you think (`kscreen-doctor -o`),
4. reconnect the session after any mode change.
