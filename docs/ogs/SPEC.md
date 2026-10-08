# OGS (online-go.com) app — team spec & contracts

This is the shared contract for the OGS feature. Each workstream owns specific files and must implement the interfaces below exactly, so the pieces fit together when merged. If you need to change a contract, say so in your final report — don't silently diverge.

Read `CLAUDE.md` first (runtime architecture, simulator, device facts).

## Goal

App id `ogs`, title **"Go (OGS)"**. Scope:

1. **Sign in.** OGS uses OAuth2 with the resource-owner *password* grant.
   - The user registers an application once at https://online-go.com/oauth2/applications/: client type "Public" (or confidential with a secret), authorization grant type "Resource owner password-based".
   - On the Kindle they enter: client id, client secret (optional), username and password.
   - We store the access and refresh tokens, never the password.
2. **My games list.** Active games, "your move" first; correspondence and live.
3. **Game screen.**
   - The board is 9×9, 13×13 or 19×19 (any size up to 25 should work).
   - Tap an intersection to place a pending stone, then tap again (or a Confirm button) to submit it.
   - Pass, resign, clocks, captures, last-move marker, opponent info.
4. **Stone removal (scoring) phase.**
   - Tap groups to toggle dead/alive; this sends `removed_stones/set`.
   - Show territory and the provisional score.
   - Accept or reject (resume play).
5. **Challenges.**
   - Accept or decline incoming challenges.
   - Challenge a friend by username (board size, ranked or unranked, color, time control: a few presets including correspondence).
   - Play a bot: pick size, speed and ranked; challenge any online bot whose config accepts that (see "Bots" below).
   - Automatch/seek is **out of scope** for now.
6. **Live updates** over the OGS realtime WebSocket. When the socket is down, the game list still works over REST, and opening a game reconnects.

## OGS protocol facts (verified from online-go/goban `src/engine/GobanSocket.ts`, `protocol/*.ts`, and ymattw/googs)

### REST (base `https://online-go.com`)

**Auth**

- `POST /oauth2/token/` (form-encoded):
  - Password login: `grant_type=password&client_id=..&client_secret=..&username=..&password=..`
  - Refresh: `grant_type=refresh_token&refresh_token=..&client_id=..&client_secret=..`
  - Returns `{access_token, refresh_token, expires_in, token_type:"Bearer", scope}`.
  - Access tokens last about 30 days; refresh when fewer than 7 days are left.
- Every API call sends `Authorization: Bearer <access_token>`.

**Account and games**

- `GET /api/v1/me` returns `{id, username, ranking, ...}`.
- `GET /api/v1/ui/config` returns `{user_jwt, user:{id, username}, ...}`. The `user_jwt` is what the socket `authenticate` message needs.
- `GET /api/v1/ui/overview` returns `{active_games:[{id, name, width, height, black:{id,username,ranking}, white:{...}, json:{...gamedata...}, ...}], challenges:[...]}`.
  - `active_games[i].json` is a gamedata object (see below) and includes `clock.current_player`.
- `GET /api/v1/games/{id}` returns the game record. `gamedata` is at `.gamedata`.

**Challenges**

- `GET /api/v1/me/challenges` lists incoming and outgoing challenges.
  - Accept: `POST /api/v1/me/challenges/{id}/accept` (JSON body `{}`).
  - Decline: `DELETE /api/v1/me/challenges/{id}`.
- Look up a player with `GET /api/v1/players?username=<name>`, which returns `{results:[{id, username, ranking}]}`.
- Challenge a player with `POST /api/v1/players/{player_id}/challenge`. The body is JSON:

  ```json
  {"initialized":false,"min_ranking":-1000,"max_ranking":1000,
   "challenger_color":"automatic"|"black"|"white",
   "game":{"name":"Friendly match","rules":"japanese","ranked":false,"width":19,"height":19,
           "handicap":0,"komi_auto":"automatic","disable_analysis":false,"pause_on_weekends":true,
           "private":false,"rengo":false,
           "time_control":"fischer","time_control_parameters":{"system":"fischer","speed":"live",
              "initial_time":600,"time_increment":30,"max_time":1200,"pause_on_weekends":false,
              "time_control":"fischer"}}}
  ```

  Correspondence uses `"speed":"correspondence"` with `initial_time` and `max_time` of days×86400 and `time_increment` of 86400.
- These JSON endpoints need `Content-Type: application/json`. `core/net.lua` defaults to form encoding, so pass the header.

**Bots** (from online-go.com `src/lib/bots.ts`, `src/views/Play/QuickMatch.tsx`, `SPEED_OPTIONS.ts`, `ChallengeModal.tsx`)

- The server pushes `["active-bots", {"<id>": {id, username, ranking, ui_class:"bot", config}}]` to every socket; the latest list replaces the previous one.
- `config._config_version` is 0 (no settings published), 1 or 2. v1/v2 fields: `allowed_board_sizes` (list, number, `"all"` or `"square"`; `[0]` = any), `allow_ranked`, `allow_unranked`, `allowed_rank_range` (`["30k","9d"]`), `allow_ranked_handicap`, `allow_unranked_handicap`, `decline_new_challenges`, `hidden`, and `allowed_{blitz,rapid,live,correspondence}_settings` = `{fischer:{initial_time_range, max_time_range, time_increment_range}, byoyomi:{...}, simple:{...}}`.
  - v1 has no `initial_time_range`: its `max_time_range` limits the **initial** time. v1 bots have no rapid settings; the server files rapid games under live.
  - Upstream `getAcceptableTimeSetting` rejects unranked games when `allow_unranked` is **true** (inverted check); we use the intended logic.
- Presets (Fischer `initial+increment, max`), the same as OGS's Play page:

  | Size | blitz | rapid | live | correspondence |
  | --- | --- | --- | --- | --- |
  | 9×9 | 30s+5s, 5m | 2m+7s, 20m | 3m+10s, 30m | 3d+1d, 7d |
  | 13×13 | 30s+5s, 5m | 3m+7s, 30m | 5m+10s, 30m | 3d+1d, 7d |
  | 19×19 | 30s+5s, 5m | 5m+7s, 50m | 10m+10s, 60m | 3d+1d, 7d |

- Challenge with `POST /api/v1/players/{bot_id}/challenge` (same body as above, `speed` = the preset's category). The reply is `{challenge:<id>, game:<id>}`.
- Then, like the web client: send `game/connect {game_id}` and `challenge/keepalive {challenge_id, game_id}` every second. The bot accepting shows up as `game/<id>/gamedata`; declining as a socket `notification` with `type:"gameOfferRejected"`, `game_id` and `message`. Cancel with `DELETE /api/v1/me/challenges/{id}`.

### Realtime socket

- URL: `wss://online-go.com/`. This is a **plain WebSocket, not socket.io**; the old `socket.io/?EIO=3` endpoint is legacy and must not be used.
- Text frames carry JSON arrays.
  - Client to server: `[command, data]` or `[command, data, request_id]` when expecting a reply.
  - Server to client: `[event_name, data]`, or `[request_id, data, error]` as a reply.
- Right after connecting, send:
  `["authenticate", {"jwt": user_jwt, "device_id": "<stable random id>", "user_agent": "KUAL Tabletop Apps", "language": "en"}]`
- Keepalive: every 20 s send `["net/ping", {"client": now_ms, "drift": 0, "latency": 0}]`. The server answers with `net/pong`.
- Commands sent to the server:

  | Command | Data |
  | --- | --- |
  | `game/connect` | `{game_id, chat:false}` |
  | `game/disconnect` | `{game_id}` |
  | `game/move` | `{game_id, move:"dd"}`. The move is a 2-letter SGF-style coordinate, x then y, `a` = 0, origin top-left. Pass is `".."`. |
  | `game/resign` | `{game_id}` |
  | `game/removed_stones/set` | `{game_id, removed:true\|false, stones:"aabbcc"}` |
  | `game/removed_stones/accept` | `{game_id, stones:"<all removed, concatenated pairs>", strict_seki_mode:false}` |
  | `game/removed_stones/reject` | `{game_id}` |
  | `challenge/keepalive` | `{challenge_id, game_id}`, every second while waiting for a challenged bot |

- Events received for a connected game:

  | Event | Data |
  | --- | --- |
  | `game/<id>/gamedata` | Full state (below). Sent on connect and on major changes. |
  | `game/<id>/move` | `{game_id, move_number, move:[x, y, time_ms]}`. Pass is x = y = -1. |
  | `game/<id>/clock` | GameClock (below) |
  | `game/<id>/phase` | `"play"` \| `"stone removal"` \| `"finished"` |
  | `game/<id>/removed_stones` | `{removed, stones, all_removed}` |
  | `game/<id>/removed_stones_accepted` | `{player_id, stones, players, phase, score, winner, outcome, end_time}` |
  | `game/<id>/error` | `"message"` |

- **gamedata**: `{game_id, width, height, phase, moves:[[x,y,t],...], initial_state:{black:"ddpp", white:""}, initial_player:"black"|"white", handicap, free_handicap_placement, komi, rules, players:{black:{id,username,rank}, white:{...}}, clock:GameClock, removed:"aabb", score?, winner?, outcome?, time_control:{...}}`
  - **Fixed handicap**: the stones are in `initial_state.black` and `initial_player` is "white".
  - **Free handicap** (`free_handicap_placement:true`): the first `handicap` moves are all black, with no turn alternation until they are placed.
- **GameClock**: `{game_id, current_player:<player id>, black_player_id, white_player_id, last_move:<ms epoch>, expiration:<ms epoch>, now?:<ms epoch>, paused_since?, black_time, white_time}`
  - `black_time` and `white_time` are either a number (seconds) or an object `{thinking_time (s), periods?, period_time?, skip_bonus?}`.
  - The time the current player has left is about `thinking_time - (now - last_move)/1000`. A simple approximation is fine.

## Module contracts

### 1. `lua/apps/lib/go.lua` (workstream A)

Pure Lua, with no UI dependencies. Board index `i = y*size + x` (0-based x, y). Colors: `go.EMPTY=0, go.BLACK=1, go.WHITE=2`.

- `go.new(size [, height])`: a new empty Game with `g.w`, `g.h`, `g.board[i]`, `g.turn = BLACK`, `g.moves = {}`, `g.captures = {[1]=0,[2]=0}` (stones captured *by* that color), and `g.ko` (forbidden index or nil).
- `g:copy()`
- `g:at(x, y)`
- `g:legal(x, y)` returns `ok, reason`, where reason is `"occupied" | "suicide" | "ko" | "offboard"`.
- `g:play(x, y)` returns `ok, reason_or_captured_list`. `x == -1` is a pass. It plays for `g.turn`, appends `{x=,y=,color=}` to `g.moves`, sets `g.last`, and switches the turn.
- `g:place(x, y, color)` places a stone (with captures) without switching the turn or recording a move. It is used for initial state and handicap.
- `g:group(x, y)` returns a list of indices and the liberty count.
- `go.sgf(x, y)` returns `"dd"` (`".."` for a pass). `go.from_sgf(s)` returns `x, y` (`-1, -1` for `".."` or `""`).
- `go.parse_points(str)` returns a set `{[i]=true}` from concatenated pairs, given `w`.
  - Signature: `go.parse_points(str, w)`.
  - Its inverse is `go.points_string(set, w)`, which emits pairs in sorted index order.
- `go.from_gamedata(gd)` builds a Game from OGS gamedata. It handles `initial_state`, `initial_player`, free and fixed handicap, and moves (including passes), and sets `g.last` = `{x,y}` of the last move. It also sets `g.komi`, `g.rules` and `g.phase`.
- `go.score(g, dead_set)` returns `{black=, white=, territory = {[i]=1|2}, dame = {[i]=true}, details = {...}}`.
  - Japanese/korean rules use territory scoring: territory plus prisoners plus dead stones.
  - Chinese and aga use area scoring: stones plus territory.
  - Komi goes to white.
  - Dead stones count as captured and their points become the other side's territory.
- `go.star_points(size)` returns a list of indices (hoshi for 9, 13 and 19, else empty).
- `go.toggle_group_dead(g, dead_set, x, y)` toggles the whole group at (x, y), or the empty point. It returns `changed_indices, now_dead(bool)`.

### 2. `lua/apps/lib/goboard.lua` (workstream A)

- `goboard.new{ on_tap = function(x, y) end, on_hold = function(x, y) end }` returns a Board.
- `b:draw(ctx, g, x, y, size, ov)` draws the wood-free e-ink board:
  - grid, star points, coordinates (optional `ov.coords`)
  - stones: black is filled; white is white with a dark outline
  - `ov.last` gets a last-move marker
  - `ov.pending` = `{x,y,color}` shows a ghost stone with a hatched or ring style
  - `ov.dead` is a set; those stones get an × or a faded look
  - `ov.territory` maps index to color and shows small squares
  - `ov.hint` is optional text

  It registers one `ctx:hit` over the board that maps the tap to the nearest intersection and calls `on_tap(x, y)` or `on_hold(x, y)`. It stores `b.geom` and also exposes `b:point_xy(x, y)` (screen centre of an intersection; tests use it).

### 3. `lua/core/ws.lua` (workstream B)

- `ws.connect(url, opts)`, where `url` is `ws://` or `wss://` and `opts = {headers={}, on_message=fn(text), on_close=fn(reason), timeout=s}`. It returns `conn` or `nil, err`.
  - The handshake is blocking: HTTP/1.1 Upgrade, 16-byte random base64 key, verify `101` and `Sec-WebSocket-Accept` (SHA-1 plus base64, written in pure Lua with the `bit` library).
  - Afterwards the socket is non-blocking.
- `conn:send(text)` sends a masked text frame, which RFC 6455 requires from clients. It returns `true` or `nil, err`.
- `conn:pump()` reads what is available, reassembles fragments, answers ping with pong, handles the close frame, and calls `on_message` per complete text message. It returns `true` if bytes arrived.
- `conn:getfd()`, `conn:close(reason)`, `conn.closed`, `conn.last_data` (ms). These make `conn` usable with `ui.add_stream(conn)` exactly like `net.Stream`.
- Reuse the TCP+TLS connect code from `core/net.lua`. Expose it there as `net.connect_socket(parsed_url, timeout)` (refactor, no behavior change), so `EINK_NET_REDIRECT` keeps working for `ws://`/`wss://` too: map `wss://host/path` to `<redirect>/host/path` with the scheme switched to `ws`.

### 4. `lua/apps/ogs/api.lua` (workstream B)

Configuration comes from the environment: `OGS_BASE` (default `https://online-go.com`) and `OGS_WS` (default `wss://online-go.com/`). The tests point them at the mock.

Credentials live in `store` namespace `"ogs"`: `{client_id, client_secret, access_token, refresh_token, expires_at, user_id, username, device_id}`.

**Auth and REST**

- `api.load()` returns true if there's a saved access token.
- `api.login(client_id, client_secret, username, password)` returns true or nil, err. It also fills `user_id` and `username` from `/api/v1/me`.
- `api.logout()`
- `api.ensure_token()` refreshes when needed.
- `api.me()`
- `api.overview()` returns `{games = {GameSummary...}, challenges = {...}}`.
  - GameSummary: `{id, name, width, height, black={id,username,rank}, white=..., my_color = 1|2, my_turn = bool, phase, speed = "live"|"correspondence"|"blitz"..., opponent = {id, username, rank}}`.
  - Sort with my turn first.
- `api.game(id)` returns the gamedata table.
- `api.challenges()` returns a normalized incoming list `{id, from={username,rank}, width, height, ranked, time_desc}`.
- `api.accept_challenge(id)` and `api.decline_challenge(id)`.
- `api.find_player(username)` returns `{id, username, rank}` or nil, err.
- `api.challenge_player(player_id, opts)`, where `opts = {size=19|13|9, ranked=bool, color="automatic"|"black"|"white", speed="blitz"|"rapid"|"live"|"correspondence", main_time=s, increment=s, max_time=s}`.
- `api.bots()` returns the online bots `{id, username, ranking, config}` weakest first, or nil before the first `active-bots`.
- `api.bot_check(bot, {size, speed, ranked, rank})` returns the clock to offer `{speed, initial, increment, max}`, or nil and a short reason.
- `api.BOT_SPEEDS`, `api.BOT_PRESETS[size][speed] = {initial, increment, max}`; `RT:keepalive(challenge_id, game_id)`.
- `api.rank_string(ranking)` turns 30 into `"1d"`; OGS uses ranking < 30 for kyu: `30 - r` k, `r - 29` d.

**Realtime**

- `api.realtime()` returns an RT singleton: `rt:connect()` fetches the JWT, opens the socket, sends `authenticate`, and starts a 20 s ping timer via `ui.every`. It registers the socket with `ui.add_stream`.
  - `rt:on(event_name, fn)` and `rt:off(event_name, fn)`: generic subscribe. The event name is the full name, such as `"game/123/move"`.
  - `rt:game_connect(id)`, `rt:game_disconnect(id)`, `rt:move(id, x, y)` (x = -1 to pass), `rt:resign(id)`, `rt:removed_set(id, removed, stones_str)`, `rt:removed_accept(id, stones_str)`, `rt:removed_reject(id)`.
  - `rt.connected` (bool). `rt:close()`.
  - Reconnect with backoff (2 s, 5 s, 15 s) if the socket drops while any game is connected, and re-send `game/connect` for connected games after re-authenticating.
- `tests/mock_ogs.py` (workstream B) is a stdlib-only fake OGS that implements everything above. It needs a WebSocket server written with `socket`/`hashlib`/`base64`, since there's no pip in CI.
  - Accounts: token `ogs_test_token`; login with client_id `test-client`, username `kindle`, password `hunter2`.
  - Two active games:
    - game 1001: 9×9 correspondence, my turn as black.
    - game 1002: 19×19 live, opponent's turn, with me as white.
  - One incoming challenge.
  - Scripted opponent: after the client plays in game 1001, the mock replies with a move about 0.5 s later. When the client passes twice in a row in 1001, it enters "stone removal". The mock then marks a group dead and, after the client accepts, sends `removed_stones_accepted` with a score and phase `"finished"`.

### 5. `lua/apps/ogs/app.lua` (workstream C)

- `M.new()` returns the root screen, following the pattern of `apps/lichess/app.lua` (token check, then Lobby or Login).
- **Login screen**: fields for client id, client secret, username and password, using `core.keyboard`; help text explains registering the OAuth app. The password is never stored.
- **Lobby**: user and rank, an "online" dot, the games list (`ctx:list`, your-turn bold, opponent and rank, board size, speed), incoming challenges with Accept/Decline, buttons "Play a bot" and "Challenge a friend", ⟲ (refresh) in the header, and a sign-out link.
- **GameScreen(id)**: built on `goboard`.
  - Player bars with clocks (`ui.redraw_quiet` ticking), captures and whose turn it is.
  - Two-step move: the first tap sets a pending stone, a second tap on the same point or **Confirm** submits it.
  - Pass (with confirm), Resign (with confirm), Flip-colors view not needed.
  - On `phase == "stone removal"`: tapping a group calls `rt:removed_set`, territory and score from `go.score` are shown, and Accept/Reject are offered. `finished` shows the result.
  - `kindle.prevent_screensaver(true)` is on for live games only.
- **ChallengeScreen**: username field, board-size segmented control (9/13/19), speed presets (Live 10m+30s, Live 20m+30s, Correspondence 1 day, 3 days), color, ranked toggle.
- **BotScreen**: board size, speed (Blitz/Rapid/Live/Corresp.), ranked toggle, and the bot list: playable bots first with "Play ›", the rest with the reason. **BotWaitScreen** keeps the challenge alive, opens the game on its gamedata, shows the decline message, and withdraws the challenge on Cancel/back or after 90 s.
- Register the app in `apps/registry.lua` (icon: a small 3×3 grid section with one black and one white stone), and add a `menu.json` entry, "Go (OGS)", after Lichess.
- Until B's real API exists, develop against a **stub**: `tests/ogs_stub_api.lua` with the same functions returning canned data, injected in sim scripts via `package.loaded["apps.ogs.api"] = require("ogs_stub_api")` (`tests/` is on the sim package path).

### 6. Integration & QA (workstream D, after A–C merge)

- End-to-end sim scripts against `tests/mock_ogs.py`: login, lobby, open game 1001, play, opponent reply, pass twice, removal, accept, finished. Also accept a challenge and send a challenge, and play a bot: the mock's `active-bots` has kata-bot (accepts), gnugo-9x9 (v1 config), refuser (declines), legacy-bot (no config) and sleepy-bot (never answers, for Cancel).
- Review all new code against this spec and `CLAUDE.md`, and fix integration bugs.
- Update `README.md` (OGS setup section), `CLAUDE.md` (OGS notes and new device facts) and `THIRD_PARTY_NOTICES.md`; the protocol was learned from goban (Apache-2.0) and googs (MIT), but no code was copied, so a "references" note is enough.

## Ground rules for every workstream

- **Only edit the files you own.** Shared files (`core/ui.lua`, `core/net.lua`, `registry.lua`, `menu.json`, docs) are owned as listed above. B may refactor `net.lua` as described.
- **Ports.** Use `WEB_PORT=<your port>` and `SIM_OUT=/tmp/sim_<you>` for `tests/run_all.sh`. Give mock servers a port in your range: A 8710–8719, B 8720–8729, C 8730–8739, D 8740–8749.
- **Run `tests/run_all.sh`** (with your `WEB_PORT`/`SIM_OUT`) before finishing; all existing apps must still pass. Add your own test scripts under `tests/`.
- **Look at your rendered frames** (PGM to PNG with PIL) for any UI you draw, at 1072×1448, and spot-check 600×800.
- **Commit** to your worktree branch with a clear message ending with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01PnCzttke26ELppC3vXPsdQ
  ```
