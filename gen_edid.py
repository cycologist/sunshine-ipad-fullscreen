#!/usr/bin/env python3
"""Generate a minimal 128-byte EDID (base block) whose preferred mode is WxH@R.

Timings come from libxcvt's `cvt` (real VESA CVT numbers), the block is checksummed
and verified with edid-decode.  Digital 8-bit input is declared on purpose: KWin then
scans out plain 8-bit buffers, which Sunshine's KMS capture imports without trouble.

usage: gen_edid.py <width> <height> <refresh> <out.bin> [extra WxH ...]
example (iPad Air 11" M3 / iPad 10,11 = 2360x1640 = 1.439):
    gen_edid.py 1920 1334 60 edid-ipad.bin 1920x1264 1600x1200 1920x1080
"""
import re
import subprocess
import sys


def cvt_mode(w, h, r):
    out = subprocess.run(["cvt", str(w), str(h), str(r)],
                         capture_output=True, text=True, check=True).stdout
    m = re.search(r"Modeline\s+\"[^\"]+\"\s+([0-9.]+)\s+"
                  r"(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+"
                  r"(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(\S+)", out)
    if not m:
        raise RuntimeError("cannot parse cvt output for %dx%d@%d:\n%s" % (w, h, r, out))
    return dict(clk=float(m.group(1)),
                hd=int(m.group(2)), hs=int(m.group(3)), hse=int(m.group(4)), ht=int(m.group(5)),
                vd=int(m.group(6)), vs=int(m.group(7)), vse=int(m.group(8)), vt=int(m.group(9)),
                hpol="+" if m.group(10) == "+hsync" else "-",
                vpol="+" if m.group(11) == "+vsync" else "-")


def dtd(m):
    """18-byte detailed timing descriptor."""
    clk10k = round(m["clk"] * 100)
    hb = m["ht"] - m["hd"]
    vb = m["vt"] - m["vd"]
    hso, hsw = m["hs"] - m["hd"], m["hse"] - m["hs"]
    vso, vsw = m["vs"] - m["vd"], m["vse"] - m["vs"]
    b = bytearray(18)
    b[0], b[1] = clk10k & 0xFF, (clk10k >> 8) & 0xFF
    b[2], b[3] = m["hd"] & 0xFF, hb & 0xFF
    b[4] = ((m["hd"] >> 8) & 0x0F) << 4 | ((hb >> 8) & 0x0F)
    b[5], b[6] = m["vd"] & 0xFF, vb & 0xFF
    b[7] = ((m["vd"] >> 8) & 0x0F) << 4 | ((vb >> 8) & 0x0F)
    b[8], b[9] = hso & 0xFF, hsw & 0xFF
    b[10] = ((vso & 0x0F) << 4) | (vsw & 0x0F)
    b[11] = (((hso >> 8) & 0x03) << 6 | ((hsw >> 8) & 0x03) << 4 |
             ((vso >> 4) & 0x03) << 2 | ((vsw >> 4) & 0x03))
    b[12], b[13] = 30, 23        # physical size in mm (cosmetic)
    b[14] = b[15] = b[16] = 0
    b[17] = 0x18 | (0x04 if m["vpol"] == "+" else 0) | (0x02 if m["hpol"] == "+" else 0)
    return bytes(b)


def build(w, h, r, extras):
    e = bytearray(128)
    e[0:8] = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])
    e[8], e[9] = 0x61, 0xA4        # manufacturer "XMD"
    e[10], e[11] = 0x34, 0x12      # product code
    e[12] = 0x01                   # serial
    e[16], e[17] = 0x01, 0x24      # week 1, year 2026
    e[18], e[19] = 0x01, 0x04      # EDID 1.4
    e[20] = 0x80 | 0x20 | 0x02     # digital input, 8 bit/channel, HDMI-a
    e[21], e[22] = 30, 23          # cm
    e[23] = 120                    # gamma 2.2
    e[24] = 0x0E                   # RGB colour, sRGB, preferred timing present
    e[25:35] = bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])
    e[35:38] = bytes([0, 0, 0])    # no established timings
    e[38:54] = bytes([0x01, 0x01] * 8)
    modes = [cvt_mode(w, h, r)] + [cvt_mode(*x) for x in extras]
    for i, m in enumerate(modes[:4]):
        e[54 + 18 * i:54 + 18 * (i + 1)] = dtd(m)
    e[126] = 0                     # no extension blocks
    e[127] = (-sum(e[:127])) & 0xFF
    return bytes(e), modes


if __name__ == "__main__":
    if len(sys.argv) < 5:
        sys.exit(__doc__)
    w, h, r, out = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    extras = []
    for a in sys.argv[5:]:
        x, y = a.split("x")
        extras.append((int(x), int(y), r))
    data, modes = build(w, h, r, extras)
    open(out, "wb").write(data)
    for m in modes:
        print(f"  {m['hd']}x{m['vd']}@{r}  {m['clk']:.2f} MHz  "
              f"h {m['hd']}/{m['hs']}/{m['hse']}/{m['ht']}  "
              f"v {m['vd']}/{m['vs']}/{m['vse']}/{m['vt']}  {m['hpol']}{m['vpol']}")
    res = subprocess.run(["edid-decode", out], capture_output=True, text=True)
    bad = [ln for ln in res.stdout.splitlines()
           if re.search(r"fail|error|warn|corrupt", ln, re.I)]
    print(f"  -> {out}: {len(data)} bytes, edid-decode: {'clean' if not bad else bad}")
