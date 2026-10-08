# KUAL Tabletop Apps

A suite of touch apps for jailbroken Kindles, launched from KUAL:

- **Lichess**: play rapid, classical and correspondence games against people, plus any time control against Stockfish or friends. It uses the official Board API.
- **Life Counter**: a Magic: The Gathering life counter for 2–6 players. Panels are rotated to face each seat, and it tracks poison, commander damage and tax, energy and experience. It also has dice, a coin flip and a random first player.
- **Ports of [CrossPoint Apps](https://github.com/zakerytclarke/crosspoint-reader-apps)** (MIT):
  - **Chess**: full rules, with pass-and-play or a built-in engine.
  - **Sudoku**: puzzles have a unique solution, with notes and a mistake check.
  - **Dice & 8-Ball**: D6, an arrow spinner, D20, Magic 8-Ball and a coin flip.
  - **Calculator**
  - **Clock**: digital, analog or flip styles.
  - **Weather**: forecasts from Open-Meteo.
  - **Wikipedia**
  - **RSS & Reddit**
  - **DuckDuckGo**

  Every port that reads text uses one paginated reader, and articles can be saved for offline reading or exported to your Kindle documents.

Everything is written in Lua and runs on the **LuaJIT that ships with KOReader**, so there is nothing else to install.

## Requirements

- A jailbroken Kindle with **KUAL** and **KOReader** installed at `/mnt/us/koreader`. This was built and tested for the Paperwhite 3 (7th gen) on 5.16.2.1.1.
- Wi-Fi, for Lichess, Weather, Wikipedia, RSS and DuckDuckGo.

## Install

1. Download this repository (Code → Download ZIP) and unzip it.
2. Connect the Kindle over USB and copy the `extension/einkapps` folder into the Kindle's `extensions` folder, so you end up with `extensions/einkapps/config.xml` on the Kindle.
3. Eject the Kindle, open **KUAL** and pick **Tabletop Apps → App launcher**. Each app also has its own menu entry.

To leave an app, tap **‹** in the top-left corner. To exit from the launcher, tap **✕**. The Kindle home screen comes back afterwards.

## Lichess setup

1. On a phone or computer, go to <https://lichess.org/account/oauth/token/create>.
2. Create a token with these scopes:
   - **Play games with the board API** (`board:play`)
   - **Read incoming challenges** (`challenge:read`)
   - **Create, accept, decline challenges** (`challenge:write`)
3. Get the token onto the Kindle in one of two ways:
   - Type it in the app.
   - Save it as `extensions/einkapps/data/lichess_token.txt` over USB.

Lichess limits Board API seeks to rapid, classical and correspondence time controls. Blitz is allowed against the computer and in direct challenges. Engine assistance is against Lichess rules.

## Life counter controls

- Tap the left or right half of a panel to subtract or add 1. Hold to subtract or add 5.
- Tap the strip at the bottom of a panel to open poison, commander damage and the other counters. You can also rename the player or rotate their panel from there.
- The round **☰** button opens dice, history, restart and new game.
- The game is saved as you go, and the screensaver is held off while a game is open.

## Troubleshooting

- **Taps land in the wrong place.** Open **Settings → Touch test**. If the crosshairs are mirrored or swapped, flip the touch toggles in Settings, then restart the app.
- **Too much ghosting, or too much flashing.** Change "Refreshes between flashes" in Settings.
- **HTTPS errors about certificates.** Usually the Kindle's clock is wrong; connect Wi-Fi so it can sync. As a last resort, Settings has "Skip HTTPS certificate checks".
- **Something crashed.** The log is at `extensions/einkapps/data/log.txt`, and you can also read it from **Settings → View log**. If the screen is ever stuck, hold the power button for about 40 seconds to restart the Kindle.
- **Firmware updates.** Don't update past 5.16.2.1.1, and consider installing renameotabin to block automatic updates.

## How it works

- `bin/run.sh` pauses the Kindle UI the same way `koreader.sh` does: it disables pillow and stops `awesome`. It then runs `luajit lua/main.lua <app>` and restores the UI on exit.
- **Drawing.** Each frame is drawn into an offscreen 8-bit buffer. Only the rectangles that changed are written to `/dev/fb0`, and KOReader's `fbink -s` refreshes just that part of the e-ink panel.
- **Touch.** The touchscreen is read straight from evdev and grabbed, so the Kindle UI underneath ignores it. A small gesture recognizer turns it into taps, holds and swipes.
- **Fonts and pieces.** Fonts (DejaVu, Poppins) and the Lichess "cburnett" chess pieces are pre-rendered by `tools/build_assets.py`.
- **Networking.** HTTPS uses KOReader's LuaSocket and LuaSec, with a bundled Mozilla CA list for certificate checks.

### Writing your own app

Add `lua/apps/myapp.lua`:

```lua
local ui = require("core.ui")
local M = {}
function M.new()
    local scr = { n = 0 }
    function scr:render(ctx)
        local top = ctx:header("My app")
        ctx:button(ui.M, top + 40, ctx.W - 2 * ui.M, ui.BTN_H, "Tapped " .. self.n,
            function() self.n = self.n + 1; ui.redraw() end, { style = "solid" })
    end
    return scr
end
return M
```

Then register it:

- Add an entry to `lua/apps/registry.lua`.
- Optionally add a line to `menu.json`.

The repository includes a desktop simulator for scripted tests (`tests/sim.sh`, `tests/run_all.sh`). It needs a local LuaJIT, LuaSocket and LuaSec.

## Credits & licenses

The app suite's own code is MIT-licensed; see [LICENSE](LICENSE).

The calculator, dice, sudoku, chess, clock, weather, Wikipedia, RSS and DuckDuckGo apps are ports of [CrossPoint Apps](https://github.com/zakerytclarke/crosspoint-reader-apps) by zakerytclarke and contributors. CrossPoint Apps is itself a fork of [CrossPoint Reader](https://github.com/crosspoint-reader/crosspoint-reader) by Dave Allie and is MIT-licensed. Thank you to them for the original apps and designs.

Other credits:

- **Chess pieces:** the cburnett set by Colin M.L. Burnett, CC BY-SA 3.0, via Lichess.
- **Fonts:** DejaVu (Bitstream Vera license) and Poppins (SIL OFL 1.1).
- **CA bundle:** Mozilla, via certifi, MPL 2.0.

Full texts are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [licenses/](licenses/).
