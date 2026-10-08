-- Fake of lua/apps/ogs/api.lua for simulator tests of the OGS screens.
-- Same interface as the SPEC (section 4); canned data, and an RT object that
-- simulates server events with ui.after. Inject before the app module loads:
--   package.loaded["apps.ogs.api"] = require("ogs_stub_api")
local ui = require("core.ui")
local sys = require("core.sys")
local go = require("apps.lib.go")

local api = {}
api.calls = {}          -- log of calls, for test assertions
api.fail_moves = false  -- make rt:move fail (tests optimistic revert)
api.reply_delay = 300

local ME = { id = 42, username = "kindle", ranking = 25 }
local logged_in = true

local function log(name, ...)
    api.calls[#api.calls + 1] = { name, ... }
end

function api.rank_string(r)
    if type(r) ~= "number" then return r and tostring(r) or "?" end
    r = math.floor(r)
    if r < 30 then return (30 - r) .. "k" end
    return (r - 29) .. "d"
end

-- Canned games ----------------------------------------------------------------------
local now = sys.now()
local function P(id, name, ranking) return { id = id, username = name, rank = ranking } end

local games = {
    [1001] = {
        game_id = 1001, game_name = "Friendly match", width = 9, height = 9, phase = "play",
        moves = { { 4, 4, 1000 }, { 2, 6, 1000 }, { 6, 2, 1000 }, { 6, 6, 1000 }, { 2, 2, 1000 }, { 5, 6, 1000 } },
        initial_state = { black = "", white = "" }, initial_player = "black", handicap = 0,
        free_handicap_placement = false, komi = 6.5, rules = "japanese",
        players = { black = P(42, "kindle", 25), white = P(7, "sensei", 33) },
        time_control = { system = "fischer", speed = "correspondence", initial_time = 259200,
            time_increment = 86400, max_time = 604800 },
        clock = { game_id = 1001, current_player = 42, black_player_id = 42, white_player_id = 7,
            last_move = now - 3600 * 1000, now = now,
            black_time = { thinking_time = 2 * 86400 + 5 * 3600 }, white_time = { thinking_time = 3 * 86400 } },
        removed = "",
    },
    [1002] = {
        game_id = 1002, game_name = "Live game", width = 19, height = 19, phase = "play",
        moves = { { 15, 3, 1 }, { 3, 15, 1 }, { 16, 15, 1 }, { 3, 3, 1 }, { 2, 13, 1 }, { 13, 16, 1 }, { 9, 9, 1 }, { 15, 15, 1 } },
        initial_state = { black = "", white = "" }, initial_player = "black", handicap = 0,
        free_handicap_placement = false, komi = 6.5, rules = "chinese",
        players = { black = P(9, "tengen_toppa", 31), white = P(42, "kindle", 25) },
        time_control = { system = "byoyomi", speed = "live", main_time = 600, period_time = 30, periods = 5 },
        clock = { game_id = 1002, current_player = 9, black_player_id = 9, white_player_id = 42,
            last_move = now - 4000, now = now,
            black_time = { thinking_time = 412, periods = 5, period_time = 30 },
            white_time = { thinking_time = 538, periods = 5, period_time = 30 } },
        removed = "",
    },
}

local challenges = {
    { id = 555, from = { username = "hikaru_fan", rank = "3k" }, width = 13, height = 13, ranked = true,
        time_desc = "Live 10m + 30s" },
}

local function color_of(gd, pid)
    if gd.players.black.id == pid then return 1 end
    if gd.players.white.id == pid then return 2 end
end

local function summary(gd)
    local g = go.from_gamedata(gd)
    local my = color_of(gd, ME.id)
    local opp = my == 1 and gd.players.white or gd.players.black
    local function pl(p) return { id = p.id, username = p.username, rank = api.rank_string(p.rank) } end
    return {
        id = gd.game_id, name = gd.game_name, width = gd.width, height = gd.height,
        black = pl(gd.players.black), white = pl(gd.players.white), my_color = my,
        my_turn = gd.phase == "play" and g.turn == my or (gd.phase == "stone removal"),
        phase = gd.phase, speed = gd.time_control.speed, opponent = pl(opp),
    }
end

-- Auth / REST --------------------------------------------------------------------------
function api.load() return logged_in end
function api.login(cid, secret, user, pw)
    log("login", cid, user)
    if cid == "test-client" and user == "kindle" and pw == "hunter2" then
        logged_in = true
        return true
    end
    return nil, "invalid_grant: Invalid credentials given."
end
function api.logout() logged_in = false; log("logout") end
function api.ensure_token() return logged_in or nil, not logged_in and "not signed in" or nil end
function api.me() if not logged_in then return nil, "401 Unauthorized" end return { id = ME.id, username = ME.username, ranking = ME.ranking } end

function api.overview()
    log("overview")
    local list = {}
    for _, gd in pairs(games) do
        if gd.phase ~= "finished" then list[#list + 1] = summary(gd) end
    end
    table.sort(list, function(a, b)
        if a.my_turn ~= b.my_turn then return a.my_turn end
        return a.id < b.id
    end)
    return { games = list, challenges = challenges }
end

function api.game(id)
    log("game", id)
    local gd = games[tonumber(id)]
    if not gd then return nil, "404 Not Found" end
    return gd
end

function api.challenges() log("challenges"); return challenges end

function api.accept_challenge(id)
    log("accept_challenge", id)
    for i, c in ipairs(challenges) do
        if c.id == id then
            table.remove(challenges, i)
            games[1003] = {
                game_id = 1003, game_name = "Challenge", width = 13, height = 13, phase = "play",
                moves = {}, initial_state = { black = "", white = "" }, initial_player = "black",
                handicap = 0, komi = 6.5, rules = "japanese",
                players = { black = P(42, "kindle", 25), white = P(11, "hikaru_fan", 27) },
                time_control = { system = "fischer", speed = "live", initial_time = 600, time_increment = 30 },
                clock = { game_id = 1003, current_player = 42, black_player_id = 42, white_player_id = 11,
                    last_move = sys.now(), now = sys.now(), black_time = 600, white_time = 600 },
                removed = "",
            }
            return { game = 1003 }
        end
    end
    return nil, "challenge not found"
end

function api.decline_challenge(id)
    log("decline_challenge", id)
    for i, c in ipairs(challenges) do
        if c.id == id then table.remove(challenges, i); return true end
    end
    return nil, "challenge not found"
end

function api.find_player(name)
    log("find_player", name)
    if name == "nobody" then return nil, "No player named " .. name end
    return { id = 77, username = name, rank = "1d" }
end

function api.challenge_player(pid, opts)
    log("challenge_player", pid, opts)
    api.last_challenge = { player_id = pid, opts = opts }
    return { challenge = 9001, game = 9002 }
end

-- Realtime --------------------------------------------------------------------------------
local RT = { connected = false, listeners = {}, games = {} }
RT.__index = RT

function api.realtime() return RT end

function RT:emit(name, data)
    local ls = self.listeners[name]
    if not ls then return end
    local copy = {}
    for i, fn in ipairs(ls) do copy[i] = fn end
    for _, fn in ipairs(copy) do fn(data) end
end
local function later(ms, name, data)
    ui.after(ms, function() RT:emit(name, type(data) == "function" and data() or data) end)
end

function RT:connect()
    log("rt_connect")
    if api.fail_connect then return nil, "connection refused" end
    self.connected = true
    return true
end
function RT:close() log("rt_close"); self.connected = false; self.games = {} end
function RT:on(name, fn)
    self.listeners[name] = self.listeners[name] or {}
    table.insert(self.listeners[name], fn)
end
function RT:off(name, fn)
    local ls = self.listeners[name]
    if not ls then return end
    for i = #ls, 1, -1 do if ls[i] == fn then table.remove(ls, i) end end
end

function RT:game_connect(id)
    log("game_connect", id)
    self.games[id] = true
    local gd = games[tonumber(id)]
    if gd then later(50, "game/" .. id .. "/gamedata", gd) end
    return true
end
function RT:game_disconnect(id) log("game_disconnect", id); self.games[id] = nil; return true end

local function push_clock(gd, ms)
    local g = go.from_gamedata(gd)
    local c = gd.clock
    c.current_player = g.turn == 1 and gd.players.black.id or gd.players.white.id
    c.last_move = sys.now(); c.now = sys.now()
    later(ms or 30, "game/" .. gd.game_id .. "/clock", c)
end

local function set_phase(gd, phase, ms)
    gd.phase = phase
    later(ms, "game/" .. gd.game_id .. "/phase", phase)
end

local function add_move(gd, x, y, ms)
    gd.moves[#gd.moves + 1] = { x, y, 1000 }
    local n = #gd.moves
    later(ms, "game/" .. gd.game_id .. "/move", { game_id = gd.game_id, move_number = n, move = { x, y, 1000 } })
end

function RT:move(id, x, y)
    log("move", id, x, y)
    if api.fail_moves then return nil, "socket closed" end
    local gd = games[tonumber(id)]
    if not gd then return nil, "no game" end
    local g = go.from_gamedata(gd)
    if x ~= -1 then
        local ok, why = g:legal(x, y)
        if not ok then later(40, "game/" .. id .. "/error", "Illegal move: " .. why); return true end
    end
    add_move(gd, x, y, 20)
    push_clock(gd)
    -- scripted opponent
    if x == -1 then
        ui.after(api.reply_delay, function()
            add_move(gd, -1, -1, 0)
            set_phase(gd, "stone removal", 120)
            -- opponent marks a group dead
            ui.after(400, function()
                local g2 = go.from_gamedata(gd)
                local dead = {}
                local target
                for i = 0, g2.w * g2.h - 1 do
                    if g2.board[i] == 2 and not target then
                        local list = g2:group(i % g2.w, math.floor(i / g2.w))
                        if #list == 1 then target = i end
                    end
                end
                if target then
                    go.toggle_group_dead(g2, dead, target % g2.w, math.floor(target / g2.w))
                    local s = go.points_string(dead, g2.w)
                    gd.removed = s
                    RT:emit("game/" .. id .. "/removed_stones", { removed = true, stones = s, all_removed = s })
                end
            end)
        end)
    else
        ui.after(api.reply_delay, function()
            local g2 = go.from_gamedata(gd)
            for _, p in ipairs({ { 6, 4 }, { 2, 4 }, { 4, 6 }, { 4, 2 }, { 7, 7 }, { 1, 1 }, { 7, 1 }, { 1, 7 } }) do
                if g2:legal(p[1], p[2]) then
                    add_move(gd, p[1], p[2], 0)
                    push_clock(gd, 10)
                    return
                end
            end
            add_move(gd, -1, -1, 0)
        end)
    end
    return true
end

function RT:resign(id)
    log("resign", id)
    local gd = games[tonumber(id)]
    local my = color_of(gd, ME.id)
    gd.winner = my == 1 and gd.players.white.id or gd.players.black.id
    gd.outcome = "Resignation"
    set_phase(gd, "finished", 200)
    later(260, "game/" .. id .. "/gamedata", gd)
    return true
end

function RT:removed_set(id, removed, stones)
    log("removed_set", id, removed, stones)
    local gd = games[tonumber(id)]
    local set = go.parse_points(gd.removed or "", gd.width)
    for i in pairs(go.parse_points(stones, gd.width)) do set[i] = removed or nil end
    gd.removed = go.points_string(set, gd.width)
    later(60, "game/" .. id .. "/removed_stones", { removed = removed, stones = stones, all_removed = gd.removed })
    return true
end

function RT:removed_accept(id, stones)
    log("removed_accept", id, stones)
    local gd = games[tonumber(id)]
    later(60, "game/" .. id .. "/removed_stones_accepted", { player_id = ME.id, stones = stones, phase = "stone removal" })
    ui.after(api.reply_delay + 200, function()
        local g = go.from_gamedata(gd)
        local sc = go.score(g, go.parse_points(stones, gd.width))
        local bw = sc.black > sc.white and 1 or 2
        gd.winner = bw == 1 and gd.players.black.id or gd.players.white.id
        gd.outcome = string.format("%g points", math.abs(sc.black - sc.white))
        gd.score = { black = { total = sc.black }, white = { total = sc.white } }
        gd.phase = "finished"
        RT:emit("game/" .. id .. "/removed_stones_accepted", { player_id = 7, stones = stones, phase = "finished",
            score = gd.score, winner = gd.winner, outcome = gd.outcome, end_time = os.time() })
        RT:emit("game/" .. id .. "/phase", "finished")
    end)
    return true
end

function RT:removed_reject(id)
    log("removed_reject", id)
    local gd = games[tonumber(id)]
    gd.removed = ""
    set_phase(gd, "play", 60)
    return true
end

api.games = games
api.ME = ME
return api
