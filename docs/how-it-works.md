# How this actually works

## The chain

```
 iPad (Moonlight, aspect-fit)          <- the only component that decides "bars or not"
        ^  H.264/HEVC at stream aspect
 Sunshine (host)  --encodes what it captured, it does NOT change the output mode
        ^  imported DRM plane buffers (kmsgrab)
 KWin/Wayland compositor  --scans out 1920x1334 on DP-4
        ^  mode list comes from the connector's EDID
 HDMI dummy plug on DP-4  --EDID overridden at runtime by this repo
```

Every arrow is a place where geometry can get mangled, so it helps to know the rules:

* **Moonlight never stretches.** It aspect-fits the decoded frame into the display and fills
  the remainder with black. No client setting on iOS changes that (Android has
  Stretch/Zoom; iOS does not), and its "Resolution" presets are all 16:9, so it cannot even
  *ask* for an iPad aspect.
* **Sunshine on Linux cannot change the display mode** (`dd_*` config keys are Windows-only).
  It captures whatever the connector is scanning out, so the mode must already be correct on
  the host.
* **A mode must exist in the connector's EDID** to be selectable. KDE/Wayland has no
  `xrandr --newmode`, and a dummy plug's EDID is fixed in firmware — hence the override.

Therefore: `stream_aspect == panel_aspect` is the only requirement, and it is satisfied by
giving the dummy output a mode with the right aspect ratio.

## Example: iPad Air 11" (M3)

Panel: 2360x1640 → 2360/1640 = **1.4390**.

Picking a mode (width must be a multiple of 8 because VESA CVT works in 8-pixel cells):

```
h = 1334          (1334 is fine, only the width granularity matters)
1920 / 1334 = 1.4389   -> 0.01 % off => <0.2 px of filler
```

`cvt 1920 1334 60` gives the timings used in the EDID:

```
1920x1334@59.95   pixel clock 216.25 MHz
h: 1920 (active) 2056 (sync start) 2264 (sync end) 2608 (total)
v: 1334          1337              1347            1383
-hsync +vsync
```

216 MHz fits comfortably in HDMI 1.4 (~340 MHz TMDS limit) and DP alternate mode, which is
what USB-C→HDMI bridges and dummy plugs handle. Going to native 2360x1640 costs ~328 MHz —
usually fine, but past the point where cheap bridges get picky.

## The EDID blob

`edid/*.bin` is a bare 128-byte base block, no CEA extension:

| bytes | content |
|---|---|
| 0–7 | header `00 FF FF FF FF FF FF 00` |
| 8–9 | manufacturer `XMD` |
| 18–19 | EDID 1.4 |
| 20 | `0xA2`: **digital input, 8 bit/channel**, HDMI-a |
| 23 | gamma 2.2 |
| 24 | `0x0E`: RGB colour, sRGB, **preferred timing present** |
| 25–34 | sRGB chromaticity |
| 35–53 | no established / standard timings |
| 54–125 | **four detailed timing descriptors** (preferred first) |
| 127 | checksum |

"Preferred timing" is what makes the compositor pick it by default after a hotplug.

Declaring **8-bit** input is deliberate: KWin then scans out plain 8-bit buffers, which is
also the format Sunshine's KMS import handles best (see the DCC note below).

## Why `edid_override` and not `drm.edid_firmware=`

```
/sys/kernel/debug/dri/<pci-dev>/<CONNECTOR>/edid_override
```

Since 6.12 the DRM core exposes a per-connector override in debugfs. Advantages:

* per connector (your laptop panel keeps its real EDID),
* runtime — no reboot, no cmdline, no initramfs rebuild,
* instantly revertable by writing an empty blob.

The classic alternative, `drm.edid_firmware=DP-4:edid/foo.bin` (kernel cmdline or
`options drm edid_firmware=...` in `/etc/modprobe.d`), is only read during boot-time probes;
if `drm`/`amdgpu` live in the initramfs you must also add the blob to `FILES=` and rebuild
it. It also applies to the whole boot, not to one connector.

### amdgpu caches the detected sink

Writing the override alone is not enough: amdgpu/DC keeps the sink (and its mode list) from
detection time. You need a re-detect, i.e. one of:

```bash
echo 1 > /sys/kernel/debug/dri/*/DP-4/trigger_hotplug    # what this repo uses
echo off > .../DP-4/force; sleep 1; echo on > .../DP-4/force; echo detect > .../DP-4/force
```

Writing to `/sys/class/drm/card1-DP-4/status` may return `EINVAL` depending on driver state;
the hotplug trigger is the reliable one. `dp4-edid-apply.sh` does the override write and the
hotplug poke, and only when the current blob differs (so it is safe to run repeatedly).

## Persistence

Three layers, because the state lives in three volatile places:

| layer | volatile because | solved by |
|---|---|---|
| `edid_override` | debugfs, gone on reboot and on connector re-detection | `dp4-edid.service` (`WantedBy=graphical.target`) + `90-dp4-edid.rules` (udev `HOTPLUG` → `SYSTEMD_WANTS`) |
| chosen mode | stored per-EDID by KWin in `~/.config/kwinoutputconfig.json`; a re-detected connector may fall back to the preferred mode | preferred timing in the blob is already the wanted mode; Sunshine `prep-cmd` re-asserts it per session |
| Sunshine capture size | Sunshine reads the plane geometry when a session starts | reconnect Moonlight after a mode change, or let the `prep-cmd` run first |

The udev rule matters for hardware that drops off the bus (some USB-C/HDMI expansion cards
reset periodically): every reset forgets the override, and the rule restores it.

## Sunshine side

```ini
# ~/.config/sunshine/sunshine.conf
output_name = DP-4
```

Sunshine then maps DP-4 to kmsgrab and imports the scanout plane each frame
(`Screencasting with KMS`, `Mapped 'DP-4' to kmsgrab monitor index 0` in the log).

The plane format matters. Verified working state looks like:

```
plane 154 crtc=387 PRIMARY fb 478 -> 1920x1334  format=AR30  modifier=0x200000010401b04
```

`0x200000010401b04` is the plain AMD DCC modifier, which imports fine. If KWin instead picks
the **DCC-retile** variant (`...1046704`), Sunshine's import fails and you get a black picture
with a perfectly working cursor (the cursor plane is linear `AR24` and imports fine). That is
a KWin allocation choice, fixed with:

```ini
# ~/.config/systemd/user/plasma-kwin_wayland.service.d/50-sunshine-kmsgrab.conf
[Service]
Environment=KWIN_DRM_USE_MODIFIERS=0
Environment=KWIN_DRM_PREFER_COLOR_DEPTH=8
```

Requires a compositor restart (log out/in). This is unrelated to the aspect problem, but it
produces the same "black screen" symptom, so it is worth ruling out first.

## Verifying each stage

```bash
# connector + mode list (kernel's view)
modetest -M amdgpu -c | grep -A20 '^432'          # 432 = DP-4 connector id on this box

# what is actually being scanned out right now
modetest -M amdgpu -p | grep -A2 '^3'

# what EDID the kernel serves
sudo edid-decode /sys/class/drm/card1-DP-4/edid | grep -E 'Manufacturer|DTD'

# what KWin thinks
kscreen-doctor -o | grep -A6 DP-4

# what Sunshine captured
grep -E '\[wayland\] (Resolution|Logical size)|Mapped' ~/.config/sunshine/sunshine.log | tail -5
```
