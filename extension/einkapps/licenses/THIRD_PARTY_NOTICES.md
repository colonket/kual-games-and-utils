# Third-party notices

KUAL Tabletop Apps' own code is MIT-licensed (see `LICENSE`). It builds on the work below, whose licenses still apply to those parts.

## CrossPoint Apps / CrossPoint Reader (MIT)

These apps are Lua ports of apps from [CrossPoint Apps](https://github.com/zakerytclarke/crosspoint-reader-apps) by zakerytclarke and contributors, which is a fork of [CrossPoint Reader](https://github.com/crosspoint-reader/crosspoint-reader):

- calculator
- dice & 8-ball
- sudoku
- chess
- clock
- weather
- Wikipedia
- RSS & Reddit
- DuckDuckGo

The behaviour and app designs follow the originals. A few pieces of data were taken over directly:

- the weather city list (`extension/einkapps/assets/cities.json`, extracted by `tools/build_assets.py`)
- the Magic 8-Ball responses
- the default RSS feeds

The original license is reproduced in [`licenses/CrossPoint-MIT.txt`](licenses/CrossPoint-MIT.txt). Copyright (c) 2025 Dave Allie.

## Chess pieces — cburnett set (CC BY-SA 3.0)

By Colin M.L. Burnett, taken from [Lichess](https://github.com/lichess-org/lila/tree/master/public/piece/cburnett). The pieces are rasterized into `extension/einkapps/assets/pieces/cburnett.epc`, which is distributed under the same license. See [`licenses/cburnett-pieces.txt`](licenses/cburnett-pieces.txt).

## Fonts

The `.efn` files in `extension/einkapps/assets/fonts/` are pre-rendered bitmaps of these fonts:

- **DejaVu Sans / DejaVu Serif**: Bitstream Vera and DejaVu licenses. See [`licenses/DejaVu-LICENSE.txt`](licenses/DejaVu-LICENSE.txt).
- **Poppins Bold**, used for large numerals: Copyright 2020 The Poppins Project Authors, SIL Open Font License 1.1. See [`licenses/Poppins-OFL.txt`](licenses/Poppins-OFL.txt).

## CA certificates (MPL 2.0)

`extension/einkapps/assets/cacert.pem` is the Mozilla CA bundle as packaged by [certifi](https://github.com/certifi/python-certifi). See [`licenses/certifi-MPL.txt`](licenses/certifi-MPL.txt).

## Runtime dependencies (not included)

The apps run on software that ships with [KOReader](https://github.com/koreader/koreader) (AGPL-3.0) and is used as-is from the Kindle:

- LuaJIT
- LuaSocket
- LuaSec
- FBInk

None of it is redistributed here.
