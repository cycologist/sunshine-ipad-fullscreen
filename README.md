# Full-screen Moonlight on an iPad (Sunshine + Linux)

Kill the black bars when streaming a Linux/KDE-Wayland desktop to an iPad over
[Sunshine](https://github.com/LizardByte/Sunshine) + [Moonlight](https://moonlight-stream.org).

Moonlight **never stretches**: it always preserves the stream's aspect ratio and fills the
rest of the panel with black. That means the only way to fill an iPad edge-to-edge is to
make the *host output* have exactly the iPad panel's aspect ratio — and if you stream a
"dummy plug" output (headless second screen), the plug's EDID usually only offers 16:9
modes. This repo gives that single connector a synthetic EDID at runtime, so proper modes
appear (e.g. `1920x1334` for a 2360x1640 iPad Air).

No bootloader edits, no kernel command line, no display driver patching: one debugfs write
per DRM connector, re-applied at boot and on hotplug by a systemd unit + udev rule.

## The aspect math

Moonlight letterboxes when `stream_aspect != panel_aspect`. iPad panels are not 16:9, so:

| host mode | aspect | iPad Air 11"/13", iPad 10/11 (2360x1640 = **1.439**) | iPad mini 6/7 (2266x1488 = **1.523**) | iPad Pro 12.9", Air 13" (4:3 = **1.333**) |
|---|---|---|---|---|
| 1920x1080 | 1.778 | bars top/bottom ~9.5 % | bars top/bottom ~15 % | bars top/bottom ~14 % |
| 1600x1200 | 1.333 | bars left/right ~8 % | bars left/right ~12 % | **fills** |
| **1920x1334** | **1.439** | **fills** | bars left/right ~5 % | bars left/right ~7 % |
| **1920x1264** | **1.519** | bars top/bottom ~5 % | **fills** | bars left/right ~12 % |

Rule of thumb: `width / height = panel_width / panel_height`, with a width that is a
multiple of 8 (VESA CVT granularity). Keeping the height near 1080 keeps the pixel clock
(~216 MHz at 1920x1334) inside HDMI 1.4 / DP-alt-mode budgets for USB-C→HDMI bridges and
dummy plugs.

## Quick start

```bash
git clone https://github.com/cycologist/sunshine-ipad-fullscreen
cd sunshine-ipad-fullscreen

# 1. pick (or build) an EDID whose preferred mode matches YOUR iPad's aspect
./make-edid.sh ipad-air-11          # -> edid/custom.bin (prebuilt edid/ipad-air-11.bin also included)

# 2. install it for a connector (default DP-4) - one root command
sudo ./install.sh edid/custom.bin DP-4

# 3. switch the output to the new mode, unscaled, at the origin
kscreen-doctor output.DP-4.scale.1 output.DP-4.position.0,0 output.DP-4.mode.1920x1334@60
```

Reconnect Moonlight: the iPad is filled, no bars.

Presets (`./make-edid.sh --list`):

| preset | iPad models | generated mode |
|---|---|---|
| `ipad-air-11` | iPad Air 11" M2/M3, iPad 10/11 | 1920x1334 (1.439) |
| `ipad-mini` | iPad mini 6/7 | 1920x1264 (1.519) |
| `ipad-pro-11-m4` | iPad Pro 11" M4 (2420x1668) | 1920x1324 (1.450) |
| `ipad-4x3` | iPad Pro 12.9", Air 13", iPad 9 (4:3) | 1920x1440 (1.333) |
| native | any | pass `--native` to use the panel resolution itself (~328 MHz for 2360x1640) |

Every generated EDID also carries `1600x1200` and `1920x1080` as fallback modes, so you can
always `kscreen-doctor` back to something safe.

## What `install.sh` does

| path | purpose |
|---|---|
| `/usr/local/share/dp4/<blob>.bin` | the EDID blob |
| `/usr/local/bin/dp4-edid-apply.sh` | idempotent: writes the blob to `/sys/kernel/debug/dri/*/<CONN>/edid_override`, then pokes `trigger_hotplug` |
| `/etc/systemd/system/dp4-edid.service` | oneshot, `WantedBy=graphical.target`, `After=sys-kernel-debug.mount` → applied at every boot |
| `/etc/udev/rules.d/90-dp4-edid.rules` | re-applies when the DRM card is (re-)created, so a flaky USB-C/HDMI expansion card that re-enumerates doesn't lose the modes |

Verify:

```bash
systemctl status dp4-edid                          # oneshot, status=0/SUCCESS
sudo edid-decode /sys/class/drm/card1-DP-4/edid    # should show DTD 1: 1920x1334
kscreen-doctor -o | grep -A3 DP-4                  # enabled, connected, 1920x1334
```

## Why the host side and not Moonlight?

* Moonlight's "Resolution" list is 16:9 only (720p/1080p/1440p/4K) — it cannot request an
  iPad aspect, and on iOS there is no stretch/fill option. Aspect-fit is the whole story.
* Sunshine on Linux **cannot change the output mode** (that's Windows-only `dd_*` config):
  it captures whatever the connector is scanning out. So the mode/EDID must be fixed on
  the host.
* KDE/Wayland offers no `xrandr --newmode`, and a dummy plug's EDID is fixed, so the only
  lever is a per-connector EDID override — which is exactly what Linux exposes in
  `/sys/kernel/debug/dri/.../edid_override`.

See **[docs/how-it-works.md](docs/how-it-works.md)** for the EDID/CVT details and the
capture pipeline, and **[docs/troubleshooting.md](docs/troubleshooting.md)** for black
screens, HDMI-card resets, HDR/bitrate and STUN/pairing notes.

## Requirements

* Linux host, KDE Plasma 6 / KWin Wayland (mode switching via `kscreen-doctor`)
* Sunshine capturing a connector through KMS (`output_name = DP-4`), i.e. typically an HDMI
  "dummy plug" on a headless second output
* Kernel with per-connector `edid_override` debugfs (6.12+; tested on 7.x)
* `python3` + `libxcvt`/`cvt` + `edid-decode` — only needed to *generate* EDIDs, not to
  install one

## Files

```
README.md              this file
gen_edid.py            build a valid 128-byte EDID for any WxH@R (CVT timings via libxcvt)
make-edid.sh           preset wrapper around gen_edid.py
install.sh             install + enable the systemd unit and udev rule
uninstall.sh           clean revert
edid/ipad-air-11.bin   prebuilt for 2360x1640 panels (preferred 1920x1334@60)
docs/                  how it works, troubleshooting
examples/              sunshine.conf / apps.json snippets
```

## Gotchas worth knowing

* **KWin scanout format**: if Sunshine shows a black screen with a working cursor, KWin is
  probably handing out a DCC-retile `AR30` buffer that Sunshine's kmsgrab cannot import.
  See `docs/troubleshooting.md` (`KWIN_DRM_USE_MODIFIERS=0`).
* The override is *volatile* (debugfs) — that's why there's a service + udev rule.
  `install.sh` makes it survive reboots and connector re-detection.
* Bitrate: 1920x1334 at Sunshine's default 7 Mbps is soft; 20–30 Mbps looks much better.
* **Scale must be 1 and the streamed output should sit at `0,0`.** A new EDID identity makes
  KWin treat the output as a brand-new monitor, and it may give it a fractional scale (seen:
  1.25). The logical size then no longer equals the mode size (1920x1334 → 1536x1067), and
  Sunshine's absolute touch/mouse mapping lands on the wrong screen because it works in
  desktop coordinates. Fix: `kscreen-doctor output.DP-4.scale.1 output.DP-4.position.0,0`.
* If the panel aspect and your chosen mode are subtly off, you get thin bars on two sides —
  that's a rounding issue, adjust the width (multiple of 8) until
  `width/height` matches `panel_width/panel_height`.

## License

MIT — see [LICENSE](LICENSE).
