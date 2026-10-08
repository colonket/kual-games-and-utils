-- apps/ogs/api.lua against tests/mock_ogs.py (run via tests/ogs_test.sh).
-- Drives the realtime socket through ui.add_stream / ui.every / ui.after by
-- pumping ui.rt.streams and ui.rt.timers the same way ui.run does.
local sys = require("core.sys")
local net = require("core.net")
local json = require("core.json")
local store = require("core.store")
local ui = require("core.ui")

local BASE = assert(os.getenv("OGS_BASE"), "OGS_BASE not set")
store.init(assert(os.getenv("OGS_TEST_DATA"), "OGS_TEST_DATA not set"))
local api = require("apps.ogs.api")
api.RECONNECT_MS = { 400, 800, 1200 }

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 io.stderr:write("ok: ", msg, "\n")
    else failed = failed + 1 io.stderr:write("FAIL: ", msg, "\n") end
    return cond
end

local function mock(method, path)
    local r = net.request({ method = method, url = BASE .. path })
    return r and json.decode(r.body)
end

-- One iteration of ui.run's stream + timer handling.
local function step()
    local fds = {}
    for st in pairs(ui.rt.streams) do
        local fd = st:getfd()
        if fd then fds[#fds + 1] = fd end
    end
    sys.poll(fds, 10)
    for st in pairs(ui.rt.streams) do
        if st.closed then ui.rt.streams[st] = nil else
            local ok, err = pcall(st.pump, st)
            if not ok then
                io.stderr:write("stream error: ", tostring(err), "\n")
                pcall(st.close, st, "error")
                ui.rt.streams[st] = nil
            end
        end
    end
    local now, due = sys.now(), {}
    for id, t in pairs(ui.rt.timers) do if t.at <= now then due[#due + 1] = { id, t } end end
    for _, d in ipairs(due) do
        local id, t = d[1], d[2]
        if ui.rt.timers[id] == t then
            if t.every then t.at = now + t.every else ui.rt.timers[id] = nil end
            t.fn()
        end
    end
end

local function run_until(pred, ms)
    local deadline = sys.now() + (ms or 5000)
    while sys.now() < deadline do
        if pred() then return true end
        step()
    end
    return pred()
end

assert(mock("POST", "/_mock/reset"), "mock_ogs not reachable at " .. BASE)

-- Auth -------------------------------------------------------------------------------
check(api.load() == false, "no token initially")
local dev = api.cfg.device_id
check(type(dev) == "string" and #dev == 32, "device_id generated")
local ok, err = api.login("test-client", "", "kindle", "wrong")
check(not ok and err, "bad password rejected: " .. tostring(err))
ok, err = api.login("test-client", "", "kindle", "hunter2")
check(ok, "login: " .. tostring(err))
check(api.cfg.user_id == 501 and api.cfg.username == "kindle", "user filled from /me")
local raw = sys.read_file(store.dir() .. "/ogs.json") or ""
check(raw:find("ogs_test_token", 1, true) and not raw:find("hunter2", 1, true), "token stored, password not")
check(raw:find("ogs_refresh_token", 1, true) and raw:find("expires_at", 1, true), "refresh token + expiry stored")
api.cfg = nil
check(api.load() == true and api.cfg.device_id == dev, "load() finds token; device_id stable")

-- Ranks
check(api.rank_string(30) == "1d" and api.rank_string(29) == "1k" and api.rank_string(23.4) == "7k"
    and api.rank_string(31.5) == "2d" and api.rank_string(nil) == "?", "rank_string")

-- REST -------------------------------------------------------------------------------
local ov, oerr = api.overview()
check(ov, "overview: " .. tostring(oerr))
if ov then
    local g1, g2 = ov.games[1], ov.games[2]
    check(#ov.games == 2 and g1.id == 1001 and g2.id == 1002, "two games, my turn first")
    check(g1.my_turn == true and g1.my_color == 1 and g1.speed == "correspondence"
        and g1.width == 9 and g1.phase == "play", "1001 summary")
    check(g1.opponent.username == "opponent" and g1.opponent.rank == "4k" and g1.black.rank == "7k", "1001 players/ranks")
    check(g2.my_turn == false and g2.my_color == 2 and g2.speed == "live" and g2.width == 19, "1002 summary")
    check(#ov.challenges == 1 and ov.challenges[1].from.username == "challenger", "overview challenges")
end
local gd = api.game(1001)
check(gd and gd.width == 9 and #gd.moves == 4 and gd.players.black.id == 501, "game(1001) gamedata")
local chs = api.challenges()
check(chs and #chs == 1, "one incoming challenge")
if chs and chs[1] then
    local c = chs[1]
    check(c.id == 3001 and c.from.rank == "2k" and c.width == 13 and c.ranked == false, "challenge normalized")
    check(c.time_desc == "20m+30s", "challenge time_desc from JSON-string params: " .. tostring(c.time_desc))
end
local p = api.find_player("Friend")
check(p and p.id == 888 and p.username == "friend" and p.rank == "10k", "find_player")
local np, nerr = api.find_player("nobody-here")
check(np == nil and nerr, "unknown player: " .. tostring(nerr))
local res, cerr = api.challenge_player(888, { size = 9, ranked = false, color = "black",
    speed = "correspondence", main_time = 3 * 86400 })
check(type(res) == "table" and res.challenge, "challenge_player: " .. tostring(cerr))
local st = mock("GET", "/_mock/state")
local body = st and st.last_challenge and st.last_challenge.body
check(body and body.challenger_color == "black" and body.game.width == 9 and body.game.ranked == false
    and body.game.time_control_parameters.speed == "correspondence"
    and body.game.time_control_parameters.initial_time == 259200
    and body.game.time_control_parameters.max_time == 259200
    and body.game.time_control_parameters.time_increment == 86400, "challenge body as JSON")
local live = api.build_challenge({ size = 19, speed = "live", main_time = 600, increment = 30 })
check(live.game.time_control_parameters.max_time == 1200 and live.min_ranking == -1000, "live challenge body")
chs = api.challenges()
check(chs and #chs == 1, "outgoing challenge not listed as incoming")
local acc, aerr = api.accept_challenge(3001)
check(acc, "accept_challenge: " .. tostring(aerr))
chs = api.challenges()
check(chs and #chs == 0, "challenge gone after accept")
ov = api.overview()
check(ov and #ov.games == 3, "accepted challenge shows up as a game")
local dres, derr = api.decline_challenge(424242)
check(dres == nil and derr, "decline unknown challenge errors: " .. tostring(derr))

-- token refresh: server forgets the token -> 401 -> refresh -> retry
mock("POST", "/_mock/expire")
local me, merr = api.me()
check(me and me.id == 501, "401 triggers refresh + retry: " .. tostring(merr))
api.cfg.expires_at = os.time() + 3600
check(api.ensure_token() and api.cfg.expires_at > os.time() + 20 * 86400, "ensure_token refreshes near expiry")

-- Realtime ---------------------------------------------------------------------------
local rt = api.realtime()
check(api.realtime() == rt, "realtime() is a singleton")
local events = {}
local function on_any(data, name) events[#events + 1] = { name = name, data = data } end
rt:on("*", on_any)
local function last(name, from)
    for i = #events, from or 1, -1 do if events[i].name == name then return events[i].data, i end end
end
local function wait_event(name, pred, ms, from)
    local found
    run_until(function()
        for i = from or 1, #events do
            local e = events[i]
            if e.name == name and (not pred or pred(e.data)) then found = e.data return true end
        end
    end, ms)
    return found
end

ok, err = rt:connect()
check(ok and rt.connected, "rt:connect: " .. tostring(err))
check(ui.rt.streams[rt.conn] == true, "socket registered with ui.add_stream")
check(rt.ping_timer and ui.rt.timers[rt.ping_timer] and ui.rt.timers[rt.ping_timer].every == 20000, "20 s ping timer")
local connected_evt = false
rt:on("rt/connected", function() connected_evt = true end)

local mark = #events + 1
rt:_ping()
check(wait_event("net/pong", nil, 3000, mark), "net/ping answered by net/pong")

-- per-event subscription + off
local moves_seen = 0
local function on_move() moves_seen = moves_seen + 1 end
rt:on("game/1001/move", on_move)

mark = #events + 1
rt:game_connect(1001)
local g = wait_event("game/1001/gamedata", nil, 3000, mark)
check(g and g.phase == "play" and #g.moves == 4, "gamedata on game_connect")
local clk = wait_event("game/1001/clock", nil, 3000, mark)
check(clk and clk.current_player == 501, "clock: my turn")

mark = #events + 1
rt:move(1001, 4, 2)
local m1 = wait_event("game/1001/move", function(d) return d.move_number == 5 end, 3000, mark)
check(m1 and m1.move[1] == 4 and m1.move[2] == 2, "my move echoed")
local m2 = wait_event("game/1001/move", function(d) return d.move_number == 6 end, 3000, mark)
check(m2 and m2.move[1] == 4 and m2.move[2] == 4, "opponent replies")

mark = #events + 1
rt:move(1001, -1)
local p1 = wait_event("game/1001/move", function(d) return d.move_number == 7 end, 3000, mark)
check(p1 and p1.move[1] == -1 and p1.move[2] == -1, "pass sent as '..'")
check(wait_event("game/1001/move", function(d) return d.move_number == 8 and d.move[1] >= 0 end, 3000, mark),
    "opponent answers first pass with a move")
mark = #events + 1
rt:move(1001, -1)
check(wait_event("game/1001/move", function(d) return d.move_number == 10 and d.move[1] == -1 end, 3000, mark),
    "opponent passes after my second pass")
check(wait_event("game/1001/phase", function(d) return d == "stone removal" end, 3000, mark), "phase -> stone removal")
local rs = wait_event("game/1001/removed_stones", nil, 3000, mark)
check(rs and rs.removed == true and #rs.all_removed >= 2, "opponent marks dead stones: " .. tostring(rs and rs.all_removed))
local dead = rs and rs.all_removed or ""

mark = #events + 1
rt:removed_set(1001, true, "cc")
local rs2 = wait_event("game/1001/removed_stones", nil, 3000, mark)
check(rs2 and rs2.all_removed:find("cc") , "removed_set adds stones")
mark = #events + 1
rt:removed_set(1001, false, "cc")
local rs3 = wait_event("game/1001/removed_stones", nil, 3000, mark)
check(rs3 and rs3.all_removed == dead, "removed_set false restores")

mark = #events + 1
rt:removed_accept(1001, dead)
local acc2 = wait_event("game/1001/removed_stones_accepted", nil, 3000, mark)
check(acc2 and acc2.phase == "finished" and acc2.winner == 501 and acc2.score, "removed_stones_accepted")
check(wait_event("game/1001/phase", function(d) return d == "finished" end, 3000, mark), "phase -> finished")
local fin = wait_event("game/1001/gamedata", function(d) return d.phase == "finished" end, 3000, mark)
check(fin and fin.outcome == "7.5 points", "final gamedata with outcome")
check(moves_seen == 6, "rt:on per-game handler saw 6 moves (" .. moves_seen .. ")")
rt:off("game/1001/move", on_move)
check(rt.handlers["game/1001/move"] == nil, "rt:off removes handler")

-- error event for an out-of-turn move
mark = #events + 1
rt:game_connect(1002)
check(wait_event("game/1002/gamedata", nil, 3000, mark), "connect 1002")
rt:move(1002, 9, 9)
local e = wait_event("game/1002/error", nil, 3000, mark)
check(e and tostring(e):find("turn"), "out-of-turn error event: " .. tostring(e))
rt:game_disconnect(1001)
check(rt.games[1001] == nil and rt.games[1002], "game_disconnect forgets the game")

-- reconnect after the socket drops: re-auth + re-send game/connect
mark = #events + 1
local nlog = #(mock("GET", "/_mock/state").ws_log)
connected_evt = false
mock("POST", "/_mock/drop")
check(wait_event("rt/disconnected", nil, 3000, mark), "rt/disconnected on drop")
check(not rt.connected, "rt.connected false while down")
check(run_until(function() return connected_evt end, 5000), "reconnected with backoff")
check(wait_event("game/1002/gamedata", nil, 3000, mark), "game 1002 re-connected after reconnect")
local wl = mock("GET", "/_mock/state").ws_log
local saw_auth, saw_connect
for i = nlog + 1, #wl do
    if wl[i][1] == "authenticate" and wl[i][2].jwt == "jwt-kindle-501" and wl[i][2].device_id == dev then saw_auth = true end
    if wl[i][1] == "game/connect" and wl[i][2].game_id == 1002 then saw_connect = true end
end
check(saw_auth and saw_connect, "re-sent authenticate (with device_id) and game/connect")

-- resign
mark = #events + 1
rt:resign(1002)
local fd = wait_event("game/1002/gamedata", function(d) return d.phase == "finished" end, 3000, mark)
check(fd and fd.outcome == "Resignation" and fd.winner == 777, "resign finishes the game")

-- close: no reconnect afterwards
rt:close()
check(not rt.connected and next(ui.rt.streams) == nil, "close removes stream")
check(rt.ping_timer == nil and next(ui.rt.timers) == nil, "close cancels timers")
connected_evt = false
run_until(function() return false end, 800)
check(not connected_evt, "no reconnect after close")
check(rt:move(1002, 1, 1) == nil, "commands fail while offline")

api.logout()
api.cfg = nil
check(api.load() == false and api.cfg.device_id == dev, "logout clears tokens, keeps device_id")

io.stderr:write(string.format("ogs api tests: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
