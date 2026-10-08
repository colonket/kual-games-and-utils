#!/usr/bin/env python3
"""Bake fonts, chess pieces and data files for the Kindle app suite.

The Kindle side is plain LuaJIT with no FreeType or SVG support, so every
glyph and sprite is pre-rendered here into small binary files.

Font file (.efn), little endian:
    b'EFN1'
    u16 px, i16 ascent, i16 descent, u16 reserved, u32 nglyphs
    nglyphs x (u32 cp, i16 adv, i16 xoff, i16 yoff, u16 w, u16 h, u16 pad, u32 off)
    glyph bitmaps, 4 bits per pixel (coverage 0..15), rows padded to a byte
  xoff/yoff place the bitmap's top-left relative to the pen at the baseline.

Piece file (.epc):
    b'EPC1' u16 size, then 12 sprites (wK wQ wR wB wN wP bK bQ bR bB bN bP),
    each size*size*2 bytes of (gray, alpha).
"""
import json
import os
import re
import struct
import subprocess
import sys

from fontTools.ttLib import TTFont
from PIL import Image, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "extension", "einkapps", "assets")
# Sources. Override any of these with an environment variable of the same name.
# ASSETS_SRC is the folder holding checkouts of lila (Lichess), python-certifi
# and crosspoint-reader-apps, plus the svg2raw helper.
SRC = os.environ.get("ASSETS_SRC", os.path.expanduser("~/assets-src"))
DEJAVU = os.environ.get("DEJAVU", "/usr/share/fonts/truetype/dejavu/")
POPPINS = os.environ.get("POPPINS", "/usr/share/fonts/truetype/google-fonts/Poppins-Bold.ttf")
PIECES_SVG = os.environ.get("PIECES_SVG", os.path.join(SRC, "lila/public/piece/cburnett/"))
SVG2RAW = os.environ.get("SVG2RAW", os.path.join(SRC, "svg2raw"))
CROSSPOINT = os.environ.get("CROSSPOINT", os.path.join(SRC, "crosspoint-reader-apps/"))
CACERT = os.environ.get("CACERT", os.path.join(SRC, "python-certifi/certifi/cacert.pem"))


def rng(a, b):
    return list(range(a, b + 1))


ICONS = (
    rng(0x2654, 0x265F) + rng(0x2680, 0x2685) + rng(0x2600, 0x2606)
    + rng(0x2660, 0x2667) + [0x2713, 0x2714, 0x2715, 0x2717, 0x2718]
    + rng(0x2190, 0x2195) + [0x21BA, 0x21BB, 0x21E6, 0x21E8, 0x2699, 0x2630,
                             0x2302, 0x2318, 0x2316, 0x25B2, 0x25BC, 0x25C0,
                             0x25B6, 0x25CF, 0x25CB, 0x25A0, 0x25A1, 0x2620,
                             0x2622, 0x26A1, 0x2691, 0x2690, 0x2694, 0x231A,
                             0x23F0, 0x2328, 0x2709, 0x270E, 0x2726, 0x2730,
                             0x2766, 0x2042, 0x221E, 0x2212, 0x00D7, 0x00F7,
                             0x00B1, 0x2022, 0x2026, 0x2014, 0x2013, 0x00B0,
                             0x21E7, 0x232B, 0x2744, 0x2261, 0x2614, 0x23CE,
                             0x27F2, 0x2139, 0x2B05, 0x2B06, 0x2B07, 0x27A1,
                             0x2328, 0x267B, 0x2295]
    + rng(0x2010, 0x203A) + rng(0x2600, 0x2620)
)
UI = rng(0x20, 0x7E) + rng(0xA0, 0xFF) + ICONS
TEXT = (
    rng(0x20, 0x7E) + rng(0xA0, 0x24F) + rng(0x2B0, 0x2FF)
    + rng(0x370, 0x3FF) + rng(0x400, 0x4FF) + rng(0x1E00, 0x1EFF)
    + rng(0x2010, 0x205E) + rng(0x20A0, 0x20BF) + rng(0x2100, 0x2153)
    + rng(0x2190, 0x21FF) + rng(0x2200, 0x22FF) + rng(0x25A0, 0x25FF)
    + ICONS + [0xFFFD] + rng(0xFB00, 0xFB06)
)
DIGITS = [ord(c) for c in "0123456789+-:/.,% ()AMPDRWLX"] + [0x2212]

FAMILIES = {
    # name: (ttf, [(px, charset)])
    "sans": (DEJAVU + "DejaVuSans.ttf",
             [(s, TEXT) for s in (20, 24, 28, 32, 36, 42, 48)]
             + [(s, UI) for s in (56, 72, 96, 128)]),
    "bold": (DEJAVU + "DejaVuSans-Bold.ttf",
             [(s, UI) for s in (24, 30, 36, 44, 56, 72, 96)]),
    "serif": (DEJAVU + "DejaVuSerif.ttf",
              [(s, TEXT) for s in (26, 30, 34, 38, 44, 52)]),
    "serifb": (DEJAVU + "DejaVuSerif-Bold.ttf",
               [(s, TEXT) for s in (34, 44, 56)]),
    "num": (POPPINS, [(s, DIGITS) for s in (72, 100, 140, 180, 240, 320, 420)]),
}


def bake_font(name, path, px, charset):
    cmap = TTFont(path).getBestCmap()
    font = ImageFont.truetype(path, px)
    ascent, descent = font.getmetrics()
    glyphs = []
    blob = bytearray()
    for cp in sorted(set(charset)):
        if cp not in cmap and cp != 0x20:
            continue
        ch = chr(cp)
        adv = int(round(font.getlength(ch)))
        bbox = font.getbbox(ch, anchor="ls")
        if bbox[2] <= bbox[0] or bbox[3] <= bbox[1]:
            glyphs.append((cp, adv, 0, 0, 0, 0, len(blob)))
            continue
        im, (ox, oy) = font.getmask2(ch, mode="L", anchor="ls")
        w, h = im.size
        img = Image.frombytes("L", (w, h), bytes(im))
        # Trim fully transparent borders that getmask2 sometimes leaves
        bb = img.getbbox()
        if bb is None:
            glyphs.append((cp, adv, 0, 0, 0, 0, len(blob)))
            continue
        img = img.crop(bb)
        ox += bb[0]
        oy += bb[1]
        w, h = img.size
        px_data = img.tobytes()
        off = len(blob)
        rowbytes = (w + 1) // 2
        for y in range(h):
            row = px_data[y * w:(y + 1) * w]
            packed = bytearray(rowbytes)
            for x in range(w):
                v = (row[x] * 15 + 127) // 255
                if x & 1:
                    packed[x >> 1] |= v
                else:
                    packed[x >> 1] |= v << 4
            blob += packed
        glyphs.append((cp, adv, ox, oy, w, h, off))
    out = bytearray(b"EFN1")
    out += struct.pack("<HhhHI", px, ascent, descent, 0, len(glyphs))
    for g in glyphs:
        out += struct.pack("<IhhhHH2xI", *g)
    out += blob
    fn = os.path.join(OUT, "fonts", "%s_%d.efn" % (name, px))
    with open(fn, "wb") as f:
        f.write(out)
    return len(glyphs), len(out)


def bake_pieces(size=192):
    order = ["wK", "wQ", "wR", "wB", "wN", "wP", "bK", "bQ", "bR", "bB", "bN", "bP"]
    out = bytearray(b"EPC1") + struct.pack("<H", size)
    tmp = "/tmp/piece.rgba"
    for p in order:
        subprocess.check_call([SVG2RAW, PIECES_SVG + p + ".svg", str(size), tmp])
        rgba = open(tmp, "rb").read()
        im = Image.frombytes("RGBA", (size, size), rgba)
        # nanosvg emits premultiplied-looking edges on black; un-premultiply
        r, g, b, a = im.split()
        gray = Image.merge("RGB", (r, g, b)).convert("L")
        gp = gray.tobytes()
        ap = a.tobytes()
        buf = bytearray(size * size * 2)
        for i in range(size * size):
            buf[2 * i] = gp[i]
            buf[2 * i + 1] = ap[i]
        out += buf
    with open(os.path.join(OUT, "pieces", "cburnett.epc"), "wb") as f:
        f.write(out)


def extract_cities():
    src = open(CROSSPOINT + "src/activities/weather/WeatherActivity.cpp").read()
    cities = []
    for m in re.finditer(r'\{"([^"]+)",\s*(-?[\d.]+),\s*(-?[\d.]+)\}', src):
        cities.append({"name": m.group(1), "lat": float(m.group(2)), "lon": float(m.group(3))})
    with open(os.path.join(OUT, "cities.json"), "w") as f:
        json.dump(cities, f, separators=(",", ":"))
    return len(cities)


def main():
    os.makedirs(os.path.join(OUT, "fonts"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "pieces"), exist_ok=True)
    total = 0
    for name, (path, sizes) in FAMILIES.items():
        for px, cs in sizes:
            n, b = bake_font(name, path, px, cs)
            total += b
            print("font %-7s %3dpx %5d glyphs %8d bytes" % (name, px, n, b))
    print("fonts total %.1f MB" % (total / 1e6))
    bake_pieces()
    print("pieces ok")
    print("cities", extract_cities())
    import shutil
    shutil.copy(CACERT, os.path.join(OUT, "cacert.pem"))
    print("cacert ok")


if __name__ == "__main__":
    main()
