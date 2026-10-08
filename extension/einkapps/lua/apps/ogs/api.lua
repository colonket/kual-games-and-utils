-- online-go.com (OGS) client: OAuth2 password login, REST calls and the
-- realtime WebSocket (plain JSON-array protocol, not socket.io).
-- Protocol notes: docs/ogs/SPEC.md.
local net = require("core.net")
local ws = require("core.ws")
local json = require("core.json")
local sys = require("core.sys")
local store = require("core.store")
local kindle = require("core.kindle")
local ui = require("core.ui")

local api = {}
api.base = (os.getenv("OGS_BASE") or "https://online-go.com"):gsub("/+$", "")
api.ws_url = os.getenv("OGS_WS") or "wss://online-go.com/"
api.user_agent = "KUAL Tabletop Apps"
api.REFRESH_MARGIN = 7 * 86400      -- refresh tokens with less than a week left
api.PING_MS = 20000
api.RECONNECT_MS = { 2000, 5000, 15000 }
api.MAX_RECONNECTS = 12                -- about 2.5 minutes of retries, then wait for the user
api.cfg = nil

local NS = "ogs"

local function log(msg)
    if ui.rt.root then ui.log("ogs: " .. msg) else io.stderr:write("ogs: ", msg, "\n") end
end

-- Credentials ------------------------------------------------------------------------
local function cfg()
    if not api.cfg then api.cfg = store.load(NS) end
    return api.cfg
end

local function save()
    store.save(NS, cfg())
end

local function ensure_device_id()
    local c = cfg()
    if not c.device_id or c.device_id == "" then
        local hex = ws.random_bytes(16):gsub(".", function(ch) return string.format("%02x", ch:byte()) end)
        c.device_id = hex
        save()
    end
    return c.device_id
end

function api.load()
    api.cfg = store.load(NS)
    ensure_device_id()
    return api.cfg.access_token ~= nil and api.cfg.access_token ~= ""
end

function api.user()
    local c = cfg()
    return { id = c.user_id, username = c.username }
end

function api.user_id() return cfg().user_id end

function api.ensure_online()
    if kindle.wifi_connected() then return true end
    if not kindle.ensure_wifi(nil, 25) then
        return nil, "Wi-Fi is off or not connected."
    end
    return true
end

-- Ranks ------------------------------------------------------------------------------
-- OGS ranking: < 30 is kyu (30 - r)k, >= 30 is dan (r - 29)d.
function api.rank_string(ranking)
    if type(ranking) == "table" then ranking = ranking.ranking or ranking.rank end
    ranking = tonumber(ranking)
    if not ranking then return "?" end
    local r = math.floor(ranking + 1e-9)
    if r < 30 then return math.max(1, 30 - r) .. "k" end
    return math.min(9, r - 29) .. "d"
end

local function player(p)
    if type(p) ~= "table" then return { username = "?", rank = "?" } end
    local ranking = p.ranking
    if ranking == nil then ranking = p.rank end
    return {
        id = p.id or p.player_id,
        username = p.username or "?",
        rank = (type(ranking) == "string") and ranking or api.rank_string(ranking),
    }
end
api.normalize_player = player

-- HTTP -------------------------------------------------------------------------------
local function error_text(resp)
    local body = resp.body or ""
    local d = json.decode(body)
    if type(d) == "table" then
        local m = d.error_description or d.detail or d.error or d.message
        if type(m) == "table" then
            local parts = {}
            for _, v in pairs(m) do parts[#parts + 1] = type(v) == "table" and table.concat(v, ", ") or tostring(v) end
            m = table.concat(parts, "; ")
        end
        if m then return tostring(m) end
    end
    return "HTTP " .. resp.status .. (body ~= "" and (": " .. body:sub(1, 160)) or "")
end

local function decode_body(resp)
    if resp.body == "" then return true end
    local d = json.decode(resp.body)
    if d == nil then return true end
    return d
end

-- POST /oauth2/token/ (form encoded). Updates the stored tokens.
local function token_request(form)
    local ok, oerr = api.ensure_online()
    if not ok then return nil, oerr end
    -- no_redirect: this body holds the password or refresh token; never replay it elsewhere
    local resp, err = net.request({
        method = "POST", url = api.base .. "/oauth2/token/", no_redirect = true,
        headers = { Accept = "application/json" }, body = net.form(form),
    })
    if not resp then return nil, err end
    if resp.status >= 400 then return nil, error_text(resp), resp.status end
    local d = json.decode(resp.body)
    if type(d) ~= "table" or not d.access_token then return nil, "Bad token response from OGS" end
    local c = cfg()
    c.access_token = d.access_token
    if d.refresh_token then c.refresh_token = d.refresh_token end
    c.expires_at = os.time() + (tonumber(d.expires_in) or 30 * 86400)
    save()
    return true
end

local function refresh()
    local c = cfg()
    if not c.refresh_token or c.refresh_token == "" then return nil, "Not signed in" end
    return token_request({
        grant_type = "refresh_token", refresh_token = c.refresh_token,
        client_id = c.client_id, client_secret = (c.client_secret ~= "" and c.client_secret or nil),
    })
end

-- Refresh the access token when it expires within a week.
function api.ensure_token()
    local c = cfg()
    if not c.access_token or c.access_token == "" then return nil, "Not signed in" end
    local left = (tonumber(c.expires_at) or 0) - os.time()
    if left < api.REFRESH_MARGIN and c.refresh_token then
        local ok, err = refresh()
        if not ok then
            log("token refresh failed: " .. tostring(err))
            if left <= 0 then return nil, "Session expired, please sign in again (" .. tostring(err) .. ")" end
        end
    end
    return true
end

-- Generic API call. opts: {json = true} sends `body` JSON-encoded.
-- Returns decoded JSON (true for empty bodies) or nil, err, status.
function api.call(method, path, body, opts)
    opts = opts or {}
    local ok, oerr = api.ensure_online()
    if not ok then return nil, oerr end
    if not opts.no_auth then
        local tok, terr = api.ensure_token()
        if not tok then return nil, terr end
    end
    for attempt = 1, 2 do
        local headers = { Accept = "application/json" }
        local c = cfg()
        if not opts.no_auth and c.access_token then headers.Authorization = "Bearer " .. c.access_token end
        local data
        if body ~= nil then
            if opts.json then
                data = type(body) == "string" and body or json.encode(body)
                headers["Content-Type"] = "application/json"
            else
                data = type(body) == "string" and body or net.form(body)
            end
        end
        local resp, err = net.request({ method = method, url = api.base .. path, headers = headers, body = data })
        if not resp then return nil, err end
        if resp.status == 401 and attempt == 1 and not opts.no_auth and c.refresh_token then
            local rok = refresh()
            if not rok then return nil, "OGS rejected the saved login (401). Please sign in again.", 401 end
        elseif resp.status == 401 then
            return nil, "OGS rejected the saved login (401). Please sign in again.", 401
        elseif resp.status >= 400 then
            return nil, error_text(resp), resp.status
        else
            return decode_body(resp)
        end
    end
end

-- Auth -------------------------------------------------------------------------------
function api.login(client_id, client_secret, username, password)
    local c = cfg()
    ensure_device_id()
    c.client_id = client_id
    c.client_secret = (client_secret and client_secret ~= "") and client_secret or nil
    c.access_token, c.refresh_token, c.expires_at = nil, nil, nil
    local ok, err = token_request({
        grant_type = "password", client_id = client_id, client_secret = c.client_secret,
        username = username, password = password,
    })
    if not ok then
        save()
        if err == "invalid_grant" then err = "Wrong username or password." end
        return nil, err
    end
    local me, merr = api.me()
    if type(me) ~= "table" then return nil, merr or "Couldn't load your OGS profile" end
    c.user_id = me.id
    c.username = me.username or username
    save()
    return true
end

function api.logout()
    if api._rt then api._rt:close() end
    local c = cfg()
    c.access_token, c.refresh_token, c.expires_at = nil, nil, nil
    c.user_id, c.username = nil, nil
    save()
end

-- REST -------------------------------------------------------------------------------
function api.me() return api.call("GET", "/api/v1/me") end

function api.ui_config() return api.call("GET", "/api/v1/ui/config/") end

local function decode_maybe(v)
    if type(v) == "string" then
        local d = json.decode(v)
        if type(d) == "table" then return d end
    end
    return v
end

local function fmt_secs(s)
    s = tonumber(s) or 0
    if s >= 86400 and s % 86400 == 0 then return (s / 86400) .. "d" end
    if s >= 86400 then return string.format("%.1fd", s / 86400) end
    if s >= 3600 and s % 3600 == 0 then return (s / 3600) .. "h" end
    if s >= 60 and s % 60 == 0 then return (s / 60) .. "m" end
    if s >= 60 then return math.floor(s / 60) .. "m" .. (s % 60) .. "s" end
    return s .. "s"
end
api.fmt_secs = fmt_secs

-- Human-readable time control ("10m+30s", "3d+1d", "5m+5×30s", ...)
function api.time_desc(tc)
    tc = decode_maybe(tc)
    if type(tc) ~= "table" then return tc and tostring(tc) or "" end
    local sys_ = tc.system or tc.time_control
    if sys_ == "fischer" then
        return fmt_secs(tc.initial_time) .. "+" .. fmt_secs(tc.time_increment)
    elseif sys_ == "byoyomi" then
        return fmt_secs(tc.main_time) .. "+" .. (tc.periods or 0) .. "×" .. fmt_secs(tc.period_time)
    elseif sys_ == "canadian" then
        return fmt_secs(tc.main_time) .. "+" .. fmt_secs(tc.period_time) .. "/" .. (tc.stones_per_period or 0)
    elseif sys_ == "simple" then
        return fmt_secs(tc.per_move) .. "/move"
    elseif sys_ == "absolute" then
        return fmt_secs(tc.total_time)
    elseif sys_ == "none" then
        return "no limit"
    end
    return tostring(sys_ or "")
end

local function speed_of(gd, g)
    local tc = decode_maybe(gd and gd.time_control)
    if type(tc) == "table" and tc.speed then return tc.speed end
    local tpm = tonumber((g and g.time_per_move) or (gd and gd.time_per_move))
    if tpm then
        if tpm >= 3600 then return "correspondence" end
        if tpm < 10 then return "blitz" end
        return "live"
    end
    return "correspondence"
end

-- One active_games entry -> GameSummary
function api.normalize_game(g, my_id)
    my_id = my_id or cfg().user_id
    local gd = g.json or g.gamedata or {}
    local players = gd.players or {}
    local black = player(g.black or players.black)
    local white = player(g.white or players.white)
    if not black.id and gd.black_player_id then black.id = gd.black_player_id end
    if not white.id and gd.white_player_id then white.id = gd.white_player_id end
    local my_color = (black.id ~= nil and black.id == my_id) and 1 or 2
    local clock = gd.clock or {}
    local cur = clock.current_player or g.player_to_move
    return {
        id = g.id or gd.game_id,
        name = g.name or gd.game_name or "",
        width = g.width or gd.width,
        height = g.height or gd.height,
        black = black, white = white,
        my_color = my_color,
        my_turn = cur ~= nil and cur == my_id,
        phase = gd.phase or g.phase or "play",
        speed = speed_of(gd, g),
        time_desc = api.time_desc(gd.time_control),
        opponent = my_color == 1 and white or black,
        gamedata = gd,
    }
end

-- One challenge object -> {id, from={id,username,rank}, width, height, ranked, time_desc, ...}
function api.normalize_challenge(ch)
    local game = ch.game or {}
    if type(game) ~= "table" then game = {} end
    local tcp = decode_maybe(game.time_control_parameters or ch.time_control_parameters)
    local from = ch.challenger or { id = ch.user_id, username = ch.username, ranking = ch.ranking }
    return {
        id = ch.id or ch.challenge_id,
        game_id = type(ch.game) == "table" and ch.game.id or ch.game_id,
        from = player(from),
        name = game.name or ch.name,
        width = game.width or ch.width,
        height = game.height or ch.height,
        ranked = (game.ranked or ch.ranked) and true or false,
        handicap = game.handicap or ch.handicap,
        rules = game.rules or ch.rules,
        challenger_color = ch.challenger_color or game.challenger_color,
        speed = type(tcp) == "table" and tcp.speed or nil,
        time_desc = api.time_desc(tcp or game.time_control),
    }
end

local function incoming_challenges(list, my_id)
    local out = {}
    for _, ch in ipairs(list or {}) do
        local to = ch.challenged
        local from = ch.challenger
        local incoming
        if type(to) == "table" and to.id then incoming = (to.id == my_id)
        elseif type(from) == "table" and from.id then incoming = (from.id ~= my_id)
        else incoming = true end
        if incoming then out[#out + 1] = api.normalize_challenge(ch) end
    end
    return out
end

function api.overview()
    local d, err, st = api.call("GET", "/api/v1/ui/overview")
    if type(d) ~= "table" then return nil, err or "Bad overview response", st end
    local my_id = cfg().user_id
    local games = {}
    for _, g in ipairs(d.active_games or {}) do
        games[#games + 1] = api.normalize_game(g, my_id)
    end
    table.sort(games, function(a, b)
        if a.my_turn ~= b.my_turn then return a.my_turn end
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
    end)
    return { games = games, challenges = incoming_challenges(d.challenges, my_id) }
end

function api.game(id)
    local d, err, st = api.call("GET", "/api/v1/games/" .. tostring(id))
    if type(d) ~= "table" then return nil, err or "Bad game response", st end
    local gd = d.gamedata
    if type(gd) ~= "table" then return nil, "Game " .. tostring(id) .. " has no gamedata" end
    gd.game_id = gd.game_id or d.id
    return gd
end

function api.challenges()
    local d, err, st = api.call("GET", "/api/v1/me/challenges")
    if type(d) ~= "table" then return nil, err or "Bad challenges response", st end
    local list = d.results or d
    return incoming_challenges(list, cfg().user_id)
end

function api.accept_challenge(id)
    return api.call("POST", "/api/v1/me/challenges/" .. tostring(id) .. "/accept", "{}", { json = true })
end

function api.decline_challenge(id)
    return api.call("DELETE", "/api/v1/me/challenges/" .. tostring(id))
end

function api.find_player(username)
    username = tostring(username or ""):match("^%s*(.-)%s*$")
    if username == "" then return nil, "Enter a username" end
    local d, err = api.call("GET", "/api/v1/players?username=" .. net.urlencode(username))
    if type(d) ~= "table" then return nil, err or "Player lookup failed" end
    local list = d.results or d
    local best
    for _, p in ipairs(list) do
        if type(p) == "table" and tostring(p.username):lower() == username:lower() then best = p break end
    end
    best = best or list[1]
    if type(best) ~= "table" then return nil, "No OGS player named " .. username end
    return player(best)
end

-- opts: {size=19|13|9, ranked=bool, color="automatic"|"black"|"white",
--        speed="blitz"|"rapid"|"live"|"correspondence", main_time=s, increment=s,
--        max_time=s, rules=, name=}
function api.build_challenge(opts)
    opts = opts or {}
    local size = tonumber(opts.size) or 19
    local speed = opts.speed or "live"
    local corr = speed == "correspondence"
    local main = tonumber(opts.main_time) or (corr and 3 * 86400 or 600)
    local inc = tonumber(opts.increment) or (corr and 86400 or 30)
    local max_time = tonumber(opts.max_time) or (corr and main or main * 2)
    local tcp = {
        system = "fischer", time_control = "fischer", speed = speed,
        initial_time = main, time_increment = inc, max_time = max_time,
        pause_on_weekends = corr,
    }
    return {
        initialized = false, min_ranking = -1000, max_ranking = 1000,
        challenger_color = opts.color or "automatic",
        game = {
            name = opts.name or "Friendly match", rules = opts.rules or "japanese",
            ranked = opts.ranked and true or false, width = size, height = size,
            handicap = 0, komi_auto = "automatic", disable_analysis = false,
            pause_on_weekends = corr, private = false, rengo = false,
            time_control = "fischer", time_control_parameters = tcp,
        },
    }
end

function api.challenge_player(player_id, opts)
    return api.call("POST", "/api/v1/players/" .. tostring(player_id) .. "/challenge",
        api.build_challenge(opts), { json = true })
end

-- Bots ---------------------------------------------------------------------------------
-- The server pushes ["active-bots", {<id>: {id, username, ranking, config}}] over the
-- realtime socket; each bot's config says which games it accepts. Presets are the
-- Fischer clocks from OGS's own Play page (online-go.com src/views/Play/SPEED_OPTIONS.ts),
-- so the speed we declare is one the server agrees with: {initial, increment, max}.
api.BOT_SPEEDS = { "blitz", "rapid", "live", "correspondence" }
local CORR = { 3 * 86400, 86400, 7 * 86400 }
api.BOT_PRESETS = {
    [9] = { blitz = { 30, 5, 300 }, rapid = { 120, 7, 1200 }, live = { 180, 10, 1800 }, correspondence = CORR },
    [13] = { blitz = { 30, 5, 300 }, rapid = { 180, 7, 1800 }, live = { 300, 10, 1800 }, correspondence = CORR },
    [19] = { blitz = { 30, 5, 300 }, rapid = { 300, 7, 3000 }, live = { 600, 10, 3600 }, correspondence = CORR },
}

-- Online bots sorted weakest first, or nil if the server hasn't sent the list yet.
function api.bots()
    local raw = api.realtime().bots
    if type(raw) ~= "table" then return nil end
    local out = {}
    for _, b in pairs(raw) do
        local id = type(b) == "table" and tonumber(b.id)
        local conf = type(b) == "table" and type(b.config) == "table" and b.config or {}
        if id and id > 0 and conf.hidden ~= true then
            out[#out + 1] = { id = id, username = tostring(b.username or id), ranking = tonumber(b.ranking), config = conf }
        end
    end
    table.sort(out, function(a, b)
        if (a.ranking or 0) ~= (b.ranking or 0) then return (a.ranking or 0) < (b.ranking or 0) end
        return a.username:lower() < b.username:lower()
    end)
    return out
end

-- "5k" / "1d" / "1p" -> OGS ranking number (30 = 1d, as in api.rank_string).
local function rank_number(r)
    local n, u = tostring(r or ""):match("^%s*(%d+)%s*([kKdDpP])")
    n = tonumber(n)
    if not n then return nil end
    u = u:lower()
    if u == "k" then return 30 - n elseif u == "d" then return 29 + n end
    return 36 + n
end

local function in_range(v, r)
    return type(r) == "table" and tonumber(r[1]) ~= nil and tonumber(r[2]) ~= nil and v >= r[1] and v <= r[2]
end

-- Will this bot take a game with o = {size=, speed=, ranked=, rank=<my ranking>}?
-- Returns the clock to offer {speed, initial, increment, max}, or nil and a short reason.
-- Follows getAcceptableTimeSetting() in online-go.com src/lib/bots.ts.
function api.bot_check(bot, o)
    local c = bot.config or {}
    local ver = tonumber(c._config_version) or 0
    if ver < 1 then return nil, "Hasn't published its settings" end
    if c.decline_new_challenges == true then return nil, "Not taking challenges" end
    local size, bs = o.size, c.allowed_board_sizes
    local size_ok = bs == "all" or bs == "square" or tonumber(bs) == size
    if type(bs) == "table" then
        for _, v in ipairs(bs) do if v == size or v == 0 then size_ok = true end end
    end
    if not size_ok then return nil, "Doesn't play " .. size .. "×" .. size end
    if type(c.allowed_rank_range) == "table" and o.rank then
        local lo, hi = rank_number(c.allowed_rank_range[1]), rank_number(c.allowed_rank_range[2])
        if lo and hi and (o.rank < lo or o.rank > hi) then
            return nil, "Only plays " .. tostring(c.allowed_rank_range[1]) .. "–" .. tostring(c.allowed_rank_range[2])
        end
    end
    if o.ranked and c.allow_ranked ~= true then return nil, "Unranked games only" end
    if not o.ranked and c.allow_unranked ~= true then return nil, "Ranked games only" end
    local p = (api.BOT_PRESETS[size] or api.BOT_PRESETS[19])[o.speed]
    if not p then return nil, "Unknown speed" end
    local tc = { speed = o.speed, initial = p[1], increment = p[2], max = p[3] }
    local function fits(set)
        local f = type(set) == "table" and set.fischer
        if type(f) ~= "table" then return false end
        if ver == 1 then
            -- v1 configs put the initial-time limits in max_time_range
            return in_range(tc.initial, f.max_time_range) and in_range(tc.increment, f.time_increment_range)
        end
        return in_range(tc.initial, f.initial_time_range) and in_range(tc.max, f.max_time_range)
            and in_range(tc.increment, f.time_increment_range)
    end
    if fits(c["allowed_" .. o.speed .. "_settings"]) then return tc end
    -- v1 bots have no rapid settings; the server files those games under live
    if ver == 1 and o.speed == "rapid" and fits(c.allowed_live_settings) then
        tc.speed = "live"
        return tc
    end
    return nil, "Doesn't play this clock"
end

-- Realtime ---------------------------------------------------------------------------
local RT = {}
RT.__index = RT

function api.realtime()
    if not api._rt then
        api._rt = setmetatable({
            handlers = {}, games = {}, callbacks = {}, next_id = 0,
            connected = false, tries = 0,
        }, RT)
        -- keep the latest bot list for api.bots(); screens can also listen for it
        api._rt:on("active-bots", function(data) api._rt.bots = data end)
    end
    return api._rt
end

-- Subscribe to an event ("game/123/move", ...). fn(data, event_name).
-- Local events: "rt/connected", "rt/disconnected" (data = reason), and "*"
-- receives every server event.
function RT:on(name, fn)
    local l = self.handlers[name]
    if not l then l = {} self.handlers[name] = l end
    l[#l + 1] = fn
    return fn
end

function RT:off(name, fn)
    local l = self.handlers[name]
    if not l then return end
    for i = #l, 1, -1 do
        if l[i] == fn or fn == nil then table.remove(l, i) end
    end
    if #l == 0 then self.handlers[name] = nil end
end

local function call_handler(fn, data, name)
    local ok, err = xpcall(function() fn(data, name) end, debug.traceback)
    if not ok then
        log("handler " .. tostring(name) .. ": " .. tostring(err))
        if ui.rt.root then ui.rt.errors = (ui.rt.errors or 0) + 1 end
        io.stderr:write("ogs handler error: ", tostring(err), "\n")
    end
end

function RT:emit(name, data)
    for _, key in ipairs({ name, "*" }) do
        local l = self.handlers[key]
        if l then
            local copy = { unpack(l) }
            for _, fn in ipairs(copy) do call_handler(fn, data, name) end
        end
    end
    if name ~= "*" then ui.redraw_quiet() end
end

function RT:_on_message(text)
    local d = json.decode(text)
    if type(d) ~= "table" then
        log("bad ws message: " .. text:sub(1, 120))
        return
    end
    local head = d[1]
    if type(head) == "number" then
        local cb = self.callbacks[head]
        if cb then
            self.callbacks[head] = nil
            call_handler(function() cb(d[2], d[3]) end, nil, "reply")
        end
    elseif type(head) == "string" then
        self:emit(head, d[2])
    end
end

function RT:_raw_send(cmd, data, cb)
    if not self.conn or self.conn.closed then return nil, "offline" end
    local msg
    if cb then
        self.next_id = self.next_id + 1
        self.callbacks[self.next_id] = cb
        msg = { cmd, data, self.next_id }
    else
        msg = { cmd, data }
    end
    return self.conn:send(json.encode(msg))
end

local function game_connect_msg(id)
    return { game_id = tonumber(id) or id, player_id = cfg().user_id, chat = false }
end

-- Fetch the JWT, open the socket, authenticate, start pinging.
-- opts.background: a timer-driven retry. It must not block for long, so it
-- doesn't try to switch Wi-Fi on (that waits up to 25 s).
function RT:connect(opts)
    if self.conn and not self.conn.closed and self.connected then return true end
    if self.reconnect_timer then ui.cancel(self.reconnect_timer) self.reconnect_timer = nil end
    self.closing = false
    local ok, err
    if opts and opts.background then
        ok = kindle.wifi_connected()
        err = "Wi-Fi is off or not connected."
    else
        ok, err = api.ensure_online()
    end
    if not ok then self:_schedule_reconnect() return nil, err end
    local conf, cerr = api.ui_config()
    if type(conf) ~= "table" or not conf.user_jwt then
        self:_schedule_reconnect()
        return nil, cerr or "OGS didn't return a realtime token"
    end
    if conf.user and conf.user.id and not cfg().user_id then
        cfg().user_id = conf.user.id
        save()
    end
    local conn, werr
    conn, werr = ws.connect(api.ws_url, {
        timeout = 15,
        headers = { Origin = api.base },
        on_message = function(text) if self.conn == conn then self:_on_message(text) end end,
        on_close = function(reason) self:_on_close(conn, reason) end,
    })
    if not conn then
        log("ws connect failed: " .. tostring(werr))
        self:_schedule_reconnect()
        return nil, werr
    end
    self.conn = conn
    self.callbacks = {}
    self:_raw_send("authenticate", {
        jwt = conf.user_jwt, device_id = ensure_device_id(),
        user_agent = api.user_agent, language = "en",
    })
    self.connected = true
    self.tries = 0
    self.connected_at = sys.now()
    ui.add_stream(conn)
    if not self.ping_timer then
        self.ping_timer = ui.every(api.PING_MS, function() self:_ping() end)
    end
    for id in pairs(self.games) do
        self:_raw_send("game/connect", game_connect_msg(id))
    end
    log("realtime connected")
    self:emit("rt/connected", true)
    return true
end

-- `conn` is the connection that closed, so a stale socket can't clobber a newer one.
function RT:_on_close(conn, reason)
    ui.remove_stream(conn)
    if self.conn ~= conn then return end
    local was = self.connected
    self.connected = false
    self.conn = nil
    self.callbacks = {}
    log("realtime closed: " .. tostring(reason))
    if was then self:emit("rt/disconnected", reason) end
    if not self.closing then self:_schedule_reconnect() end
end

function RT:_schedule_reconnect()
    if self.closing or self.reconnect_timer or not next(self.games) then return end
    if self.tries >= api.MAX_RECONNECTS then
        -- Give up quietly; the next user action (move, reload, wake) retries.
        if self.tries == api.MAX_RECONNECTS then
            self.tries = self.tries + 1
            log("giving up reconnecting")
            self:emit("rt/gave_up", true)
        end
        return
    end
    self.tries = self.tries + 1
    local delays = api.RECONNECT_MS
    local delay = delays[math.min(self.tries, #delays)]
    log("reconnecting in " .. delay .. " ms")
    self.reconnect_timer = ui.after(delay, function()
        self.reconnect_timer = nil
        if self.closing or self.connected then return end
        self:connect({ background = true })
    end)
end

-- Drop the current socket (it may be dead after sleep) and open a fresh one,
-- keeping the connected games: connect() re-sends game/connect for each.
-- Several screens may ask at once on wake; one fresh socket is enough.
function RT:reconnect()
    if self.connected and self.connected_at and sys.now() - self.connected_at < 1000 then return true end
    if self.reconnect_timer then ui.cancel(self.reconnect_timer) self.reconnect_timer = nil end
    local conn = self.conn
    self.conn, self.connected, self.callbacks = nil, false, {}
    if conn then
        conn:close("reconnect")   -- its on_close sees a stale conn and does nothing
        ui.remove_stream(conn)
    end
    self.tries = 0
    return self:connect()
end

function RT:_ping()
    if not self.connected or not self.conn then return end
    -- No traffic for 3 ping intervals: assume the socket is dead.
    if sys.now() - (self.conn.last_data or 0) > 3 * api.PING_MS + 5000 then
        self.conn:close("ping timeout")
        return
    end
    self:_raw_send("net/ping", { client = sys.now(), drift = 0, latency = 0 })
end

function RT:send(cmd, data, cb)
    local ok, err = self:_raw_send(cmd, data, cb)
    if not ok then
        if next(self.games) then self:_schedule_reconnect() end
        return nil, err or "offline"
    end
    return true
end

function RT:game_connect(id)
    self.games[id] = true
    if not self.connected then
        self.tries = 0
        return self:connect()
    end
    return self:send("game/connect", game_connect_msg(id))
end

function RT:game_disconnect(id)
    self.games[id] = nil
    if not self.connected then return true end
    return self:send("game/disconnect", { game_id = tonumber(id) or id })
end

local function sgf(x, y)
    if not x or x < 0 then return ".." end
    return string.char(97 + x) .. string.char(97 + y)
end
api.sgf = sgf

function RT:move(id, x, y)
    return self:send("game/move", { game_id = tonumber(id) or id, player_id = cfg().user_id, move = sgf(x, y) })
end

-- Keep an outgoing challenge alive while we wait for the opponent (OGS drops
-- live challenges that stop getting these; the web client sends one a second).
function RT:keepalive(challenge_id, game_id)
    return self:send("challenge/keepalive", { challenge_id = challenge_id, game_id = game_id })
end

function RT:resign(id)
    return self:send("game/resign", { game_id = tonumber(id) or id })
end

function RT:removed_set(id, removed, stones)
    return self:send("game/removed_stones/set", {
        game_id = tonumber(id) or id, removed = removed and true or false, stones = stones or "",
    })
end

function RT:removed_accept(id, stones)
    return self:send("game/removed_stones/accept", {
        game_id = tonumber(id) or id, stones = stones or "", strict_seki_mode = false,
    })
end

function RT:removed_reject(id)
    return self:send("game/removed_stones/reject", { game_id = tonumber(id) or id })
end

function RT:close()
    self.closing = true
    if self.ping_timer then ui.cancel(self.ping_timer) self.ping_timer = nil end
    if self.reconnect_timer then ui.cancel(self.reconnect_timer) self.reconnect_timer = nil end
    self.games = {}
    local conn = self.conn
    if conn then
        conn:close("client close")
        ui.remove_stream(conn)
    end
    self.conn = nil
    self.connected = false
end

return api
