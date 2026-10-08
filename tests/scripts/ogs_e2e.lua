-- End-to-end: the REAL OGS app (api.lua + go.lua + goboard.lua, no stubs)
-- against tests/mock_ogs.py over HTTP and the realtime WebSocket.
-- Run via tests/ogs_e2e.sh (starts the mock, sets OGS_BASE/OGS_WS or
-- EINK_NET_REDIRECT, starts the simulator in the launcher).
local S = require("simlib")
local ui = require("core.ui")
local input = require("core.input")
local net = require("core.net")
local json = require("core.json")
local registry = require("apps.registry")

-- Catch globals leaked by app code from here on.
local leaked = {}
setmetatable(_G, { __newindex = function(t, k, v) leaked[#leaked + 1] = tostring(k); rawset(t, k, v) end })

local ROOT = os.getenv("EINK_APPS_ROOT")
os.remove(ROOT .. "/data/ogs.json")
os.remove(ROOT .. "/data/ogs_prefs.json")
local BASE = os.getenv("OGS_BASE") or "https://online-go.com" -- EINK_NET_REDIRECT maps the latter to the mock

local function mock(method, path)
    local r, err = net.request({ method = method, url = BASE .. path, body = method == "POST" and "" or nil })
    assert(r, "mock request failed: " .. tostring(err))
    return json.decode(r.body)
end
local function state() return mock("GET", "/_mock/state") end
local function ws_count(cmd, gid)
    local n = 0
    for _, m in ipairs(state().ws_log) do
        if m[1] == cmd and (gid == nil or (type(m[2]) == "table" and m[2].game_id == gid)) then n = n + 1 end
    end
    return n
end
local function read(path)
    local f = io.open(path, "r")
    if not f then return "" end
    local s = f:read("*a"); f:close(); return s
end

local function top() return ui.top() end
local function rt() return require("apps.ogs.api").realtime() end
local function at(x, y) local g = top().g; return g.board[y * g.w + x] end
local function tap_pt(x, y)
    return function()
        if ui.rt.dirty then ui.render_now() end
        local px, py = top().board:point_xy(x, y)
        input.inject({ type = "tap", x = px, y = py })
    end
end
local function settle(ms) return S.wait(ms or 150) end
local function clear_toast() return function() ui.rt.toast_msg = nil; ui.redraw() end end
local box = {}   -- values carried between steps (globals would trip the leak check)

-- Type on core.keyboard: letters directly, digits and '-' via the 123 page.
local function type_text(str)
    local steps = {}
    for ch in str:gmatch(".") do
        if ch:match("[a-z]") then
            steps[#steps + 1] = S.tap_text(ch)
        else
            steps[#steps + 1] = S.tap_text("123")
            steps[#steps + 1] = S.tap_text(ch)
            steps[#steps + 1] = S.tap_text("ABC")
        end
    end
    steps[#steps + 1] = S.tap_text("DONE")
    return steps
end

local W1001 -- remembered across steps
local base_connects

local script = {
    -- launcher
    S.wait(100),
    S.snap("00_home"),
    S.check(function() return #registry.apps == 13 end, "launcher has 13 apps"),
    S.tap_text("Go (OGS)"),
    S.wait_until(function() return top().submit ~= nil end, 3000),
    S.snap("01_login"),
    -- sign in through the keyboard
    S.tap_text("Tap to type…", 1),         -- client id
    type_text("test-client"),
    S.tap_text("Tap to type…", 2),         -- username (secret stays empty)
    type_text("kindle"),
    S.tap_text("Tap to type…", 2),         -- password
    type_text("wrong"),
    S.snap("02_login_filled"),
    S.tap_text("Sign in"),
    S.check(function() return top().msg ~= nil and top().password == "" end, "bad password: error shown, password cleared"),
    S.snap("03_login_error"),
    S.tap_text("Tap to type…", 2),
    type_text("hunter2"),
    S.tap_text("Sign in"),
    S.wait_until(function() return top().games ~= nil end, 5000),
    settle(),
    S.snap("04_lobby"),
    S.check(function()
        local ids = {}
        for _, g in ipairs(top().games) do ids[#ids + 1] = g.id end
        return #ids == 2 and ids[1] == 1001 and ids[2] == 1002
    end, "lobby: 1001 (my turn) then 1002"),
    S.check(function() local c = top().challenges; return #c == 1 and c[1].id == 3001 and c[1].from.username == "challenger" end,
        "lobby: challenge 3001 from challenger"),
    S.check(function() return rt().connected end, "realtime socket up"),
    S.check(function()
        local saved = read(ROOT .. "/data/ogs.json")
        return saved:find("ogs_test_token", 1, true) and not saved:find("hunter2", 1, true)
            and not read(ROOT .. "/data/log.txt"):find("hunter2", 1, true)
    end, "token saved, password neither saved nor logged"),

    -- game 1001: 9x9, my move as black
    S.tap_text("▶ opponent (4k)"),
    S.wait_until(function() return top().id == 1001 and top().g ~= nil and rt().games[1001] end, 5000),
    settle(300),
    S.snap("05_game1001"),
    S.check(function() return top().my_color == 1 and top():my_turn() and top().nmoves == 4 end, "1001: my turn as black, 4 moves"),
    S.check(function() return top().gd.players.black.username == "kindle" end, "gamedata from the real api"),
    tap_pt(4, 4),
    S.check(function() local p = top().pending; return p and p.x == 4 and p.y == 4 and at(4, 4) == 0 end, "pending stone at E5"),
    S.snap("06_pending"),
    S.tap_text("Confirm E5"),
    S.wait_until(function() return top().nmoves == 6 and top().sent == nil end, 5000),
    settle(),
    S.snap("07_reply"),
    S.check(function() return at(4, 4) == 1 and at(5, 5) == 2 end, "my stone + opponent reply (F4) over the socket"),
    S.check(function() return #state().games["1001"].moves == 6 end, "mock agrees: 6 moves"),
    -- pass, opponent answers with a stone
    S.tap_text("Pass"),
    S.snap("08_pass_confirm"),
    S.tap_text("Pass"),
    S.wait_until(function() return top().nmoves == 8 and top().sent == nil end, 5000),
    S.check(function() return top():my_turn() and top().phase == "play" end, "opponent replied to the first pass"),
    -- second pass, opponent passes -> stone removal, opponent marks a group
    S.tap_text("Pass"),
    S.tap_text("Pass"),
    S.wait_until(function() return top().phase == "stone removal" and next(top().dead) ~= nil end, 5000),
    settle(),
    S.snap("09_removal"),
    S.check(function() return top().dead[5 * 9 + 3] == true end, "opponent marked D4 group dead"),
    tap_pt(4, 4),
    S.wait_until(function() return state().games["1001"].removed:find("ee", 1, true) ~= nil end, 3000),
    settle(),
    S.snap("10_removal_toggled"),
    S.check(function() return top().dead[4 * 9 + 4] == true end, "E5 marked dead locally"),
    S.check(function()
        local sc = top():local_score()
        local _, sub = top():status_lines()
        return sc and sub:find(string.format("Black %g · White %g", sc.black, sc.white), 1, true) ~= nil
    end, "status text shows go.score totals"),
    S.tap_text("Accept score"),
    S.wait_until(function() return top().phase == "finished" and top().result ~= nil end, 5000),
    settle(300),
    S.snap("11_finished"),
    S.check(function() return top():result_text() == "You won by 7.5 points" end, "result: You won by 7.5 points"),
    S.check(function() local _, sub = top():status_lines(); return sub == "Black 41 · White 33.5" end, "server score shown"),
    S.check(function() return state().games["1001"].phase == "finished" end, "mock: 1001 finished"),
    S.tap_text("Back to games"),
    S.wait_until(function() return top().games ~= nil and #top().games == 1 end, 5000),
    settle(),
    S.snap("12_lobby_after"),

    -- accept challenge 3001 -> game 1003 (13x13, I'm white, opponent opens)
    S.tap_text("Accept"),
    S.wait_until(function() return top().id == 1003 and top().g ~= nil and top().nmoves == 1 end, 5000),
    settle(300),
    S.snap("13_game1003"),
    S.check(function() return top().g.w == 13 and top().my_color == 2 and top():my_turn() end, "1003: 13x13, white, my turn"),
    tap_pt(9, 9), tap_pt(9, 9),                 -- second tap on the same point submits
    S.wait_until(function() return top().nmoves == 3 and top().sent == nil end, 5000),
    S.check(function() return at(9, 9) == 2 end, "my move in 1003"),
    S.tap_text("Resign"),
    S.tap_text("Resign"),
    S.wait_until(function() return top().phase == "finished" and top().result ~= nil end, 5000),
    settle(),
    S.snap("14_resigned"),
    S.check(function() return top():result_text() == "You lost by resignation" end, "resign result"),
    S.tap_text("Back to games"),
    S.wait_until(function() return top().games ~= nil end, 5000),

    -- challenge a friend
    S.tap_text("Challenge a friend"),
    S.tap_text("Tap to type…"),
    type_text("friend"),
    S.tap_text("13×13"), S.tap_text("Corresp. 1 day"),
    S.snap("15_challenge"),
    S.tap_text("Send challenge"),
    S.wait_until(function() return top().games ~= nil end, 5000),
    S.check(function()
        local c = state().last_challenge
        local gm = c and c.body.game
        return c and c.player_id == 888 and gm.width == 13 and gm.time_control_parameters.speed == "correspondence"
            and gm.time_control_parameters.initial_time == 86400
    end, "challenge sent to friend (888): 13x13 correspondence 1 day"),
    settle(),
    S.snap("16_challenge_sent"),
    clear_toast(),

    -- play a bot: the list arrives over the socket; each bot's config decides what it takes
    S.tap_text("Play a bot"),
    S.wait_until(function() return S.find_hit("kata-bot (9d)") ~= nil end, 5000),
    settle(),
    S.snap("16b_bots"),
    S.check(function()
        local b = require("apps.ogs.api").bots()
        return #b == 5 and b[1].username == "legacy-bot" and b[4].username == "sleepy-bot" and b[5].username == "kata-bot"
    end, "bot list from active-bots, weakest first"),
    S.check(function()
        local api = require("apps.ogs.api")
        local by = {}
        for _, b in ipairs(api.bots()) do by[b.username] = b end
        local function why(name, o) return select(2, api.bot_check(by[name], o)) end
        local rapid = api.bot_check(by["gnugo-9x9"], { size = 9, speed = "rapid", ranked = false })
        return why("legacy-bot", { size = 9, speed = "live", ranked = false }) == "Hasn't published its settings"
            and why("gnugo-9x9", { size = 13, speed = "live", ranked = false }) == "Doesn't play 13×13"
            and why("gnugo-9x9", { size = 9, speed = "live", ranked = true }) == "Unranked games only"
            and why("gnugo-9x9", { size = 9, speed = "blitz", ranked = false }) == "Doesn't play this clock"
            and rapid and rapid.speed == "live"
            and why("kata-bot", { size = 9, speed = "live", ranked = false, rank = 40 }) == "Only plays 30k–9d"
            and api.bot_check(by["kata-bot"], { size = 19, speed = "correspondence", ranked = true }) ~= nil
    end, "bot_check: no config, board size, ranked, missing clock, v1 rapid->live, rank range"),
    S.check(function() return S.find_hit("gnugo-9x9") ~= nil and S.find_hit("legacy-bot") == nil end,
        "9x9 live: gnugo playable, legacy-bot listed but not tappable"),
    S.tap_text("13×13"),
    S.check(function() return S.find_hit("gnugo-9x9") == nil and S.find_hit("kata-bot") ~= nil end,
        "13x13 hides gnugo's Play"),
    S.tap_text("9×9"),
    -- a bot that declines: back on the bot list with an explanation
    S.tap_text("refuser"),
    S.wait_until(function() return top().overlay == true end, 5000),
    settle(),
    S.snap("16c_bot_declined"),
    S.check(function()
        return rt().handlers["notification"] == nil and ui.rt.stack[#ui.rt.stack - 1].play ~= nil
    end, "declined: wait screen gone, its handlers removed"),
    S.tap_text("OK"),
    -- a bot that never answers: Cancel withdraws the challenge and stops the keepalives
    S.tap_text("sleepy-bot"),
    S.wait_until(function() return S.find_hit("Cancel challenge") ~= nil end, 5000),
    S.wait(1500),
    S.snap("16c2_bot_waiting"),
    function() box.sleepy = state().last_challenge.challenge end,
    S.check(function()
        local n = 0
        for _, m in ipairs(state().ws_log) do if m[1] == "challenge/keepalive" and m[2].challenge_id == box.sleepy then n = n + 1 end end
        return n >= 2
    end, "keepalive repeats while waiting"),
    S.tap_text("Cancel challenge"),
    S.wait_until(function() return top().play ~= nil end, 5000),
    S.check(function()
        for _, id in ipairs(state().challenges) do if id == box.sleepy then return false end end
        return rt().handlers["notification"] == nil
    end, "cancel: challenge withdrawn on the server, handlers removed"),
    function()
        box.keepalives = 0
        for _, m in ipairs(state().ws_log) do if m[1] == "challenge/keepalive" then box.keepalives = box.keepalives + 1 end end
    end,
    S.wait(1500),
    S.check(function()
        local n = 0
        for _, m in ipairs(state().ws_log) do if m[1] == "challenge/keepalive" then n = n + 1 end end
        return n == box.keepalives
    end, "cancel: keepalives stopped"),
    -- a bot that accepts: the game opens by itself
    S.tap_text("kata-bot"),
    S.wait_until(function() return top().gd ~= nil and top().gd.players.white.username == "kata-bot" end, 5000),
    settle(300),
    S.snap("16d_bot_game"),
    S.check(function()
        local c = state().last_challenge
        local gm = c.body.game
        local tcp = gm.time_control_parameters
        return c.player_id == 1201 and gm.width == 9 and gm.ranked == false and tcp.speed == "live"
            and tcp.initial_time == 180 and tcp.time_increment == 10 and tcp.max_time == 1800
    end, "bot challenge uses OGS's 9x9 live preset (3m+10s, max 30m)"),
    S.check(function() return ws_count("challenge/keepalive") >= 1 end, "challenge kept alive over the socket"),
    S.check(function() return top():my_turn() and top().my_color == 1 end, "my move as black against the bot"),
    tap_pt(4, 4),
    S.tap_text("Confirm E5"),
    S.wait_until(function() return top().nmoves == 2 and top().sent == nil end, 5000),
    settle(),
    S.snap("16e_bot_reply"),
    S.check(function() return at(4, 4) == 1 and at(6, 2) == 2 end, "the bot answers over the socket"),
    S.tap_text("☰"),
    S.tap_text("Back to games"),
    S.wait_until(function() return top().games ~= nil and S.find_hit("kata-bot") ~= nil end, 5000),
    S.check(function() return rt().handlers["notification"] == nil and rt().handlers["active-bots"]
        and #rt().handlers["active-bots"] == 1 end, "bot screens left no handlers behind"),

    -- game 1002: live 19x19, opponent to move; a move arrives live
    S.tap_text("opponent (4k)"),
    S.wait_until(function() return top().id == 1002 and top().g ~= nil and rt().games[1002] end, 5000),
    settle(300),
    S.check(function() return top().my_color == 2 and not top():my_turn() end, "1002: waiting for opponent"),
    function() base_connects = ws_count("game/connect", 1002); mock("POST", "/_mock/opponent_move/1002") end,
    S.wait_until(function() return top().nmoves == 5 and top():my_turn() end, 5000),
    settle(),
    S.snap("17_game1002_live"),
    S.check(function() return at(16, 3) == 1 end, "opponent's live move (R16) shown"),
    -- socket drops: RT reconnects by itself and rejoins exactly once
    function() mock("POST", "/_mock/drop") end,
    S.wait_until(function() return not rt().connected end, 3000),
    S.snap("18_offline"),
    S.check(function() return top().offline ~= nil end, "game shows offline"),
    S.wait_until(function() return rt().connected and top().offline == nil end, 8000),
    S.wait_until(function() return ws_count("game/connect", 1002) == base_connects + 1 end, 3000),
    -- wake from sleep: one fresh socket, one game/connect, one set of handlers
    function() top():on_wake() end,
    S.wait(1800),
    S.wait_until(function() return rt().connected end, 5000),
    S.wait(300),
    S.check(function() return ws_count("game/connect", 1002) == base_connects + 2 end, "wake: exactly one re-join"),
    S.check(function()
        local l = rt().handlers["game/1002/move"]
        return l and #l == 1 and #(rt().handlers["rt/connected"] or {}) == 1
    end, "no duplicate subscriptions"),
    tap_pt(9, 9),
    S.tap_text("Confirm K10"),
    S.wait_until(function() return top().nmoves == 6 and top().sent == nil end, 5000),
    S.check(function() return #state().games["1002"].moves == 6 end, "move after reconnects reaches the server"),
    settle(),
    S.snap("19_game1002_after"),
    -- leave: game disconnected, RT closed with the lobby, no timers left behind
    S.tap_text("☰"),
    S.tap_text("Back to games"),
    S.wait_until(function() return top().games ~= nil end, 5000),
    S.check(function() return rt().games[1002] == nil end, "left game dropped from RT"),
    S.tap_text("back"),
    S.wait(100),
    S.check(function() return not rt().connected and rt().ping_timer == nil and next(rt().games) == nil end,
        "leaving OGS closes the socket"),
    S.check(function()
        for _, t in pairs(ui.rt.timers) do
            if t.owner ~= nil and t.owner ~= ui.top() then
                io.stderr:write("timer owner left: ", tostring(t.owner.render and (t.owner.id or t.owner.title or "screen") or t.owner), " every=", tostring(t.every), "\n")
                return false
            end
        end
        return true
    end, "no screen-owned timers left"),
    S.check(function() return #leaked == 0 end, "no leaked globals"),
    S.snap("20_home_again"),
}

-- flatten nested step lists (type_text)
local out = {}
local function add(t)
    if type(t) == "table" and type(t[1]) ~= "string" then
        for _, x in ipairs(t) do add(x) end
    else
        out[#out + 1] = t
    end
end
for _, st in ipairs(script) do add(st) end
return out
