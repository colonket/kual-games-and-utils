#!/usr/bin/env python3
"""Turn simulator frames into the README screenshots in docs/screenshots/.

usage: tools/screenshots.py [SIM_OUT]     (default /tmp/sim_all, as in tests/test_all.sh)

Run tests/test_all.sh first; it writes PGM frames to ${SIM_OUT}_*. The frames
are exactly what the app draws on the e-ink panel. Each one is scaled down 2x
(box filter) and written as an 8-bit grayscale PNG. Standard library only.
"""
import os, struct, sys, zlib

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
DEST = os.path.join(ROOT, "docs", "screenshots")

# output name -> frame, relative to the test_all.sh output prefix
SHOTS = {
    "launcher":   "_home/home.pgm",
    "lichess":    "_li/05_after_reply.pgm",
    "go":         "_ogs_ui/15_game19.pgm",
    "go_scoring": "_ogs_ui/08_removal.pgm",
    "mtg":        "_mtg/m2_4p.pgm",
    "chess":      "_apps/chess/chess_local.pgm",
    "sudoku":     "_apps/sudoku/sudoku_new.pgm",
    "dice":       "_apps/dice/dice_d20.pgm",
    "calculator": "_apps/calculator/calculator.pgm",
    "clock":      "_apps/clock/clock_flip.pgm",
    "weather":    "_apps/weather/weather.pgm",
    "wikipedia":  "_apps/wikipedia/wiki_page1.pgm",
    "rss":        "_apps/rss/rss_reddit.pgm",
    "duckduckgo": "_apps/duckduckgo/ddg_keyboard.pgm",
    "settings":   "_apps/settings/settings.pgm",
}


def read_pgm(path):
    data = open(path, "rb").read()
    magic, dims, maxval, px = data.split(b"\n", 3)
    assert magic == b"P5" and maxval == b"255", path
    w, h = map(int, dims.split())
    return w, h, px


def half(w, h, px):
    W, H = w // 2, h // 2
    out = bytearray(W * H)
    for y in range(H):
        r0, r1 = 2 * y * w, (2 * y + 1) * w
        for x in range(W):
            i = 2 * x
            out[y * W + x] = (px[r0 + i] + px[r0 + i + 1] + px[r1 + i] + px[r1 + i + 1] + 2) // 4
    return W, H, bytes(out)


def write_png(path, w, h, px):
    def chunk(tag, body):
        return struct.pack(">I", len(body)) + tag + body + struct.pack(">I", zlib.crc32(tag + body) & 0xFFFFFFFF)
    raw = b"".join(b"\0" + px[y * w:(y + 1) * w] for y in range(h))
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main():
    prefix = sys.argv[1] if len(sys.argv) > 1 else "/tmp/sim_all"
    os.makedirs(DEST, exist_ok=True)
    missing = 0
    for name, rel in SHOTS.items():
        src = prefix + rel
        if not os.path.exists(src):
            print("missing", src)
            missing += 1
            continue
        out = os.path.join(DEST, name + ".png")
        write_png(out, *half(*read_pgm(src)))
        print("wrote", os.path.relpath(out, ROOT))
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
