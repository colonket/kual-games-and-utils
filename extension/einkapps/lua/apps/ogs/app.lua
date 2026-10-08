-- online-go.com (OGS) client: sign-in, games list, challenges, and live or
-- correspondence games over the OGS realtime socket.
local ui = require("core.ui")
local gfx = require("core.gfx")
local sys = require("core.sys")
local store = require("core.store")
local kindle = require("core.kindle")
local keyboard = require("core.keyboard")
local go = require("apps.lib.go")
local goboard = require("apps.lib.goboard")
local api = require("apps.ogs.api")

local dp = ui.dp
local BLACK, WHITE, DARK, GRAY, LIGHT, PALE, MID = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.GRAY, gfx.LIGHT, gfx.PALE, gfx.MID

local M = {}

-- Helpers ------------------------------------------------------------------------------
local COLS = "ABCDEFGHJKLMNOPQRSTUVWXYZ"

local function point_name(x, y, h)
    if x < 0 then return "pass" end
    return COLS:sub(x + 1, x + 1) .. tostring(h - y)
end
M.point_name = point_name

local function rank_text(p)
    if not p then return "" end
    local r = p.rank
    if r == nil then r = p.ranking end
    if type(r) == "number" then return api.rank_string(r) end
    return r and tostring(r) or ""
end

local function cap(s) return s and (s:sub(1, 1):upper() .. s:sub(2)) or "" end

-- Seconds → clock text. Correspondence shows days/hours.
local function fmt_secs(s, corr)
    if not s then return "--:--" end
    if s < 0 then s = 0 end
    s = math.floor(s)
    if s >= 86400 then return string.format("%dd %dh", math.floor(s / 86400), math.floor(s % 86400 / 3600)) end
    if corr then
        if s >= 3600 then return string.format("%dh %02dm", math.floor(s / 3600), math.floor(s % 3600 / 60)) end
        return string.format("%dm", math.max(1, math.floor(s / 60)))
    end
    if s >= 3600 then return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60) end
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
M.fmt_secs = fmt_secs

-- An rt command failed only if it says so: false, or nil with an error.
local function failed(ok, err)
    return ok == false or (ok == nil and err ~= nil)
end

local function section(ctx, x, y, label)
    local f = ui.font("bold", 30)
    f:draw_top(ctx.s, x, y, label, DARK)
    return f.height + dp(14)
end

local function stone_icon(s, cx, cy, r, color)
    if color == go.BLACK then
        s:fill_circle(cx, cy, r, BLACK)
    else
        s:fill_circle(cx, cy, r, WHITE)
        s:circle(cx, cy, r, BLACK, math.max(2, dp(3)))
    end
end

-- Prefs (never holds the password) --------------------------------------------------------
local prefs
local function load_prefs()
    if not prefs then
        prefs = store.load("ogs_prefs", { size = 3, tc = 1, color = 1, ranked = false, friend = "", coords = true })
        -- added later, so fill them in for older saved prefs
        prefs.bot_size = prefs.bot_size or 1
        prefs.bot_speed = prefs.bot_speed or 3
        if prefs.bot_ranked == nil then prefs.bot_ranked = false end
    end
    return prefs
end
local function save_prefs() store.save("ogs_prefs", prefs) end

-- Session --------------------------------------------------------------------------------------
local session = { me = nil, active = false, open_games = {} }
M.session = session

function session.rt() return api.realtime() end

-- Make sure the realtime socket is up. Blocking (TLS + handshake).
function session.ensure_rt(quiet)
    local rt = api.realtime()
    if rt.connected then return rt end
    if not quiet then ui.busy("Connecting…") end
    rt.tries = 0 -- a user action: start the retry budget over
    local ok, err = rt:connect()
    if not rt.connected then
        ui.log("ogs rt: " .. tostring(err or ok))
        return nil, err or "couldn't connect"
    end
    return rt
end

function session.stop()
    session.active = false
    local rt = api.realtime()
    if rt then pcall(rt.close, rt) end
end

local GameScreen, Lobby -- forward

function session.open_game(id, info)
    id = tonumber(id) or id
    if session.open_games[id] then return end
    local scr = GameScreen(id, info)
    session.open_games[id] = scr
    ui.push(scr)
end

-- Login ------------------------------------------------------------------------------------------
local function LoginScreen(on_ok)
    local saved = store.load("ogs", {})
    local scr = {
        client_id = saved.client_id or "", client_secret = saved.client_secret or "",
        username = saved.username or "", password = "",
    }

    local function field(ctx, x, y, w, label, value, display, on_tap)
        y = y + section(ctx, x, y, label)
        ctx:button(x, y, w, dp(100), display ~= "" and display or "Tap to type…", on_tap,
            { align = "left", bold = false, size = 34 })
        return dp(100) + dp(26) + ui.font("bold", 30).height + dp(14)
    end

    local function edit(key, title, opts)
        opts = opts or {}
        keyboard({
            title = title, text = scr[key], start_mode = "lower", help = opts.help, hint = opts.hint,
            on_done = function(t)
                if key ~= "password" then t = t:gsub("^%s+", ""):gsub("%s+$", "") end
                scr[key] = t
                scr.msg = nil
                ui.redraw()
            end,
        })
    end

    function scr:submit()
        if self.client_id == "" or self.username == "" or self.password == "" then
            self.msg = "Fill in the client ID, username and password."
            return ui.redraw()
        end
        ui.busy("Signing in…")
        local ok, err = api.login(self.client_id, self.client_secret, self.username, self.password)
        self.password = ""
        if not ok then
            self.msg = "Sign-in failed: " .. tostring(err)
            return ui.redraw()
        end
        self.msg = nil
        session.me = nil
        on_ok()
    end

    function scr:render(ctx)
        local top = ctx:header("Sign in to OGS")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(24)
        local f = ui.font("sans", 28)
        if self.msg then
            -- the error takes the help text's place so it is visible on small screens too
            y = y + ctx:paragraph(x, y, w, self.msg, { font = ui.font("bold", 30), max_lines = 5 }) + dp(24)
        else
            y = y + ctx:paragraph(x, y, w,
                "One-time setup: on a computer, sign in to online-go.com and open online-go.com/oauth2/applications. "
                .. "Register an application with client type \"Public\" and grant type \"Resource owner password-based\", "
                .. "then type its client ID here. Your password is only used to get a token; it is never saved.",
                { font = f, color = DARK }) + dp(24)
        end
        y = y + field(ctx, x, y, w, "CLIENT ID", self.client_id, self.client_id, function()
            edit("client_id", "OAuth client ID", { help = "From online-go.com/oauth2/applications" })
        end)
        y = y + field(ctx, x, y, w, "CLIENT SECRET (OPTIONAL)", self.client_secret,
            self.client_secret ~= "" and string.rep("•", math.min(12, #self.client_secret)) or "", function()
                edit("client_secret", "Client secret", { help = "Leave empty for a Public application." })
            end)
        y = y + field(ctx, x, y, w, "USERNAME", self.username, self.username, function()
            edit("username", "OGS username")
        end)
        y = y + field(ctx, x, y, w, "PASSWORD", self.password,
            self.password ~= "" and string.rep("•", math.min(16, #self.password)) or "", function()
                edit("password", "OGS password", { help = "Used once to get a token. Not stored on the Kindle." })
            end)
        ctx:button(x, y, w, ui.BTN_H, "Sign in", function() self:submit() end, { style = "solid" })
    end
    return scr
end

-- Challenge a friend ---------------------------------------------------------------------------
local SIZES = { 9, 13, 19 }
local TCS = {
    { "Live 10m + 30s", "live", 600, 30 },
    { "Live 20m + 30s", "live", 1200, 30 },
    { "Corresp. 1 day", "correspondence", 86400, 86400 },
    { "Corresp. 3 days", "correspondence", 3 * 86400, 86400 },
}
local CHAL_COLORS = { "automatic", "black", "white" }

local function ChallengeScreen(on_sent)
    local scr = {}
    function scr:send()
        local p = load_prefs()
        if p.friend == "" then return ui.toast("Enter a username first") end
        ui.busy("Finding " .. p.friend .. "…")
        local pl, err = api.find_player(p.friend)
        if not pl then return ui.alert("Player not found", err or ("No player named " .. p.friend)) end
        local tc = TCS[p.tc] or TCS[1]
        ui.busy("Sending challenge…")
        local res, err2 = api.challenge_player(pl.id, {
            size = SIZES[p.size] or 19, ranked = p.ranked, color = CHAL_COLORS[p.color] or "automatic",
            speed = tc[2], main_time = tc[3], increment = tc[4],
        })
        if not res then return ui.alert("Challenge failed", err2) end
        ui.pop(scr)
        ui.toast("Challenge sent to " .. (pl.username or p.friend) .. ". The game appears in your list once accepted.", 4000)
        if on_sent then on_sent(res) end
    end
    function scr:render(ctx)
        local p = load_prefs()
        local top = ctx:header("Challenge a friend")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(30)
        y = y + section(ctx, x, y, "OPPONENT'S OGS USERNAME")
        ctx:button(x, y, w, dp(110), p.friend ~= "" and p.friend or "Tap to type…", function()
            keyboard({ title = "OGS username", text = p.friend, start_mode = "lower", on_done = function(t)
                p.friend = t:gsub("^%s+", ""):gsub("%s+$", ""); save_prefs(); ui.redraw()
            end })
        end, { align = "left", bold = false })
        y = y + dp(110) + dp(36)
        y = y + section(ctx, x, y, "BOARD SIZE")
        ctx:segmented(x, y, w, dp(100), { "9×9", "13×13", "19×19" }, p.size,
            function(i) p.size = i; save_prefs(); ui.redraw() end)
        y = y + dp(100) + dp(36)
        y = y + section(ctx, x, y, "TIME CONTROL")
        local gap = dp(16)
        local cw = math.floor((w - gap) / 2)
        for i, tc in ipairs(TCS) do
            local r, c = math.floor((i - 1) / 2), (i - 1) % 2
            ctx:button(x + c * (cw + gap), y + r * (dp(100) + gap), cw, dp(100), tc[1],
                function() p.tc = i; save_prefs(); ui.redraw() end, { selected = (p.tc == i), size = 32 })
        end
        y = y + 2 * dp(100) + gap + dp(36)
        y = y + section(ctx, x, y, "YOUR COLOR")
        ctx:segmented(x, y, w, dp(100), { "Automatic", "Black", "White" }, p.color,
            function(i) p.color = i; save_prefs(); ui.redraw() end)
        y = y + dp(100) + dp(30)
        ctx:toggle(x, y, w, dp(100), "Ranked game", p.ranked, function(v) p.ranked = v; save_prefs(); ui.redraw() end)
        ctx:button(x, ctx.H - ui.BTN_H - dp(50), w, ui.BTN_H, "Send challenge", function() self:send() end,
            { style = "solid" })
    end
    return scr
end

-- Play a bot ------------------------------------------------------------------------------------
local BOT_SPEED_LABELS = { "Blitz", "Rapid", "Live", "Corresp." }
local BOT_WAIT_MS = 90000   -- give up on a bot that neither accepts nor declines

-- After the challenge is sent: keep it alive until the bot's game starts
-- (game/<id>/gamedata arrives), it declines (a gameOfferRejected
-- notification), we time out, or the user cancels.
local function BotWaitScreen(bot, challenge_id, game_id, on_started)
    local scr = { done = false }
    local rt = api.realtime()
    local gd_event = "game/" .. tostring(game_id) .. "/gamedata"

    local function finish()
        if scr.done then return false end
        scr.done = true
        ui.cancel_owner(scr)
        rt:off(gd_event, scr.on_gamedata)
        rt:off("notification", scr.on_notification)
        rt:send("game/disconnect", { game_id = game_id })
        return true
    end

    local function give_up(title, msg)
        if not finish() then return end
        api.decline_challenge(challenge_id)   -- withdraw it; fine if it's already gone
        ui.pop(scr)
        if title then ui.alert(title, msg) end
    end

    function scr.on_gamedata()
        if not finish() then return end
        ui.pop(scr)
        on_started(game_id)
    end

    function scr.on_notification(n)
        if type(n) ~= "table" or n.type ~= "gameOfferRejected" or tonumber(n.game_id) ~= tonumber(game_id) then return end
        local why = type(n.rejection_details) == "table" and n.rejection_details.message or n.message
        if not finish() then return end
        ui.pop(scr)
        ui.alert(bot.username .. " declined", (why and why ~= "") and tostring(why) or "The bot turned down this game.")
    end

    function scr:enter()
        rt:on(gd_event, self.on_gamedata)
        rt:on("notification", self.on_notification)
        rt:send("game/connect", { game_id = game_id, chat = false })
        rt:keepalive(challenge_id, game_id)
        ui.every(1000, function() rt:keepalive(challenge_id, game_id) end, self)
        ui.after(BOT_WAIT_MS, function()
            give_up("No answer", bot.username .. " didn't accept in time, so the challenge was withdrawn.")
        end, self)
    end

    function scr:leave() finish() end

    function scr:render(ctx)
        local top = ctx:header("Play a bot", { back = function() give_up() end })
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(160)
        local f = ui.font("bold", 44)
        local msg = "Waiting for " .. bot.username .. "…"
        f:draw_top(ctx.s, x + (w - f:width(f:ellipsize(msg, w))) / 2, y, f:ellipsize(msg, w), BLACK)
        y = y + f.height + dp(30)
        ctx:paragraph(x, y, w, "Bots usually accept within a few seconds. The game opens as soon as it starts.",
            { font = ui.font("sans", 32), color = DARK, align = "center" })
        ctx:button(x, ctx.H - ui.BTN_H - dp(50), w, ui.BTN_H, "Cancel challenge", function() give_up() end)
    end
    return scr
end

local function BotScreen(on_started)
    local scr = { state = { page = 1 } }
    local rt = api.realtime()

    function scr.on_bots() if ui.top() == scr then ui.redraw() end end

    function scr:enter()
        rt:on("active-bots", self.on_bots)
        if not rt.connected then session.ensure_rt() end
    end

    function scr:leave() rt:off("active-bots", self.on_bots) end

    function scr:options()
        local p = load_prefs()
        return {
            size = SIZES[p.bot_size] or 9, speed = api.BOT_SPEEDS[p.bot_speed] or "live",
            ranked = p.bot_ranked, rank = session.me and tonumber(session.me.ranking),
        }
    end

    function scr:play(bot, tc)
        local o = self:options()
        -- the socket tells us when the game starts, so it must be up first
        local ok, cerr = session.ensure_rt()
        if not ok then return ui.alert("Offline", "Couldn't reach OGS's realtime server: " .. tostring(cerr)) end
        ui.busy("Challenging " .. bot.username .. "…")
        local res, err = api.challenge_player(bot.id, {
            size = o.size, ranked = o.ranked, color = "automatic", speed = tc.speed,
            main_time = tc.initial, increment = tc.increment, max_time = tc.max,
        })
        if not res then return ui.alert("Challenge failed", err) end
        local gid = type(res) == "table" and res.game
        if type(gid) == "table" then gid = gid.id end
        local cid = type(res) == "table" and res.challenge
        if not gid or not cid then
            ui.pop(self)
            return ui.toast("Challenge sent to " .. bot.username .. ". The game appears in your list once accepted.", 4000)
        end
        ui.push(BotWaitScreen(bot, cid, gid, function(id)
            ui.pop(self)
            on_started(id)
        end))
    end

    function scr:render(ctx)
        local p = load_prefs()
        local top = ctx:header("Play a bot")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(26)
        y = y + section(ctx, x, y, "BOARD SIZE")
        ctx:segmented(x, y, w, dp(96), { "9×9", "13×13", "19×19" }, p.bot_size,
            function(i) p.bot_size = i; save_prefs(); self.state.page = 1; ui.redraw() end)
        y = y + dp(96) + dp(30)
        local o = self:options()
        local preset = (api.BOT_PRESETS[o.size] or api.BOT_PRESETS[19])[o.speed]
        local clock = api.time_desc({ system = "fischer", initial_time = preset[1], time_increment = preset[2] }):gsub("%+", " + ")
        y = y + section(ctx, x, y, "SPEED  ·  " .. clock .. " per move")
        ctx:segmented(x, y, w, dp(96), BOT_SPEED_LABELS, p.bot_speed,
            function(i) p.bot_speed = i; save_prefs(); self.state.page = 1; ui.redraw() end)
        y = y + dp(96) + dp(24)
        ctx:toggle(x, y, w, dp(96), "Ranked game", p.bot_ranked,
            function(v) p.bot_ranked = v; save_prefs(); self.state.page = 1; ui.redraw() end)
        y = y + dp(96) + dp(24)
        y = y + section(ctx, x, y, "BOTS ONLINE")
        ctx.s:fill_rect(x, y - dp(4), w, ui.BORDER, LIGHT)
        local bots = api.bots()
        local ready, busy = {}, {}
        for _, b in ipairs(bots or {}) do
            local tc, why = api.bot_check(b, o)
            local rk = b.ranking and api.rank_string(b.ranking) or ""
            local title = b.username .. (rk ~= "" and (" (" .. rk .. ")") or "")
            if tc then
                local bot = b
                ready[#ready + 1] = { title = title, subtitle = cap(tc.speed) .. " · " .. api.time_desc({
                    system = "fischer", initial_time = tc.initial, time_increment = tc.increment }),
                    right = "Play ›", bold = true, on_tap = function() self:play(bot, tc) end }
            else
                busy[#busy + 1] = { title = title, subtitle = why }
            end
        end
        for _, it in ipairs(busy) do ready[#ready + 1] = it end
        local empty
        if not rt.connected then empty = "Not connected to OGS. Go back and tap ⟲ to retry."
        elseif not bots then empty = "Waiting for the list of bots…"
        else empty = "No bots are online right now." end
        ctx:list(x, y + dp(4), w, ctx.H - y - dp(20), ready, self.state, { empty = empty, row_h = dp(124) })
    end
    return scr
end

-- Lobby -------------------------------------------------------------------------------------------
Lobby = function()
    local scr = { state = { page = 1 }, games = nil, challenges = {} }

    function scr:load()
        ui.busy("Loading games…")
        self.stale = false
        local ok, err = api.ensure_token()
        if failed(ok, err) then
            self.err = err
            return ui.redraw()
        end
        if not session.me then
            local me, e = api.me()
            if not me then
                self.err = e
                return ui.redraw()
            end
            session.me = me
        end
        local ov, e2 = api.overview()
        if not ov then
            self.err = e2
            self.games = self.games or {}
        else
            self.err = nil
            self.games = ov.games or {}
            local ch = ov.challenges
            -- overview's challenge entries may be raw; use the normalized list then
            if type(ch) ~= "table" or (ch[1] and not ch[1].from) then ch = api.challenges() end
            self.challenges = ch or {}
        end
        session.ensure_rt(true)
        self.drawn_online = api.realtime().connected
        ui.redraw()
    end

    function scr:enter()
        session.active = true
        load_prefs()
        self:load()
        -- reflect socket state changes without flashing the screen
        ui.every(3000, function()
            if ui.top() == self and api.realtime().connected ~= self.drawn_online then ui.redraw_quiet() end
        end, self)
    end

    function scr:resume()
        if self.stale then self:load() end
    end

    function scr:leave()
        ui.cancel_owner(self)
        session.stop()
    end

    function scr:on_wake()
        ui.after(1500, function()
            if ui.top() == self then self:load() else self.stale = true end
        end, self)
    end

    function scr:open(id, info)
        self.stale = true
        session.open_game(id, info)
    end

    function scr:accept(c)
        ui.busy("Accepting…")
        local res, err = api.accept_challenge(c.id)
        if not res then return ui.alert("Couldn't accept", err) end
        for i, cc in ipairs(self.challenges) do if cc == c then table.remove(self.challenges, i) break end end
        local gid
        if type(res) == "number" then gid = res
        elseif type(res) == "table" then gid = res.game_id or res.game or res[1] or res.id end
        if type(gid) == "table" then gid = gid.id end
        if gid then self:open(gid) else self:load() end
    end

    function scr:decline(c)
        ui.busy("Declining…")
        local ok, err = api.decline_challenge(c.id)
        if not ok then return ui.alert("Couldn't decline", err) end
        for i, cc in ipairs(self.challenges) do if cc == c then table.remove(self.challenges, i) break end end
        ui.redraw()
    end

    function scr:render(ctx)
        local s = ctx.s
        local top = ctx:header("Go (OGS)", { back = function() ui.pop(scr) end,
            right = { "⟲", function() self:load() end, size = 44 } })
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(26)
        local me = session.me
        if not me then
            ctx:paragraph(x, y, w, "Couldn't reach online-go.com:\n" .. tostring(self.err or "unknown error"),
                { font = ui.font("sans", 32) })
            ctx:button(x, y + dp(300), w, ui.BTN_H, "Retry", function() self:load() end, { style = "solid" })
            ctx:button(x, y + dp(300) + ui.BTN_H + dp(20), w, ui.BTN_H, "Sign in again", function()
                api.logout()
                ui.replace(LoginScreen(function() ui.replace(Lobby()) end))
            end)
            return
        end
        -- account card
        local nf = ui.font("bold", 44)
        local rk = rank_text(me)
        nf:draw_top(s, x, y, nf:ellipsize(me.username or "?", w - dp(300)), BLACK)
        local nw = math.min(nf:width(me.username or "?"), w - dp(300))
        local rf = ui.font("sans", 32)
        if rk ~= "" then rf:draw_top(s, x + nw + dp(16), y + nf.height - rf.height, rk, DARK) end
        local online = api.realtime().connected
        self.drawn_online = online
        local dot = online and "● online" or "○ offline"
        local df = ui.font("sans", 28)
        df:draw_top(s, x + w - df:width(dot), y + dp(10), dot, DARK)
        y = y + nf.height + dp(26)
        ctx:button_row(x, y, w, dp(104), {
            { "Play a bot", function()
                self.stale = true
                ui.push(BotScreen(function(id) self:open(id) end))
            end, { style = "solid", size = 32 } },
            { "Challenge a friend", function()
                self.stale = true
                ui.push(ChallengeScreen())
            end, { size = 32 } },
        })
        y = y + dp(104) + dp(30)
        -- incoming challenges
        local ch = self.challenges or {}
        if #ch > 0 then
            y = y + section(ctx, x, y, "INCOMING CHALLENGES")
            for i = 1, math.min(#ch, 2) do
                local c = ch[i]
                local from = c.from or {}
                local line = string.format("%s%s · %d×%d · %s%s", from.username or "?",
                    (from.rank and from.rank ~= "") and (" (" .. tostring(from.rank) .. ")") or "",
                    c.width or 19, c.height or c.width or 19, c.ranked and "ranked" or "unranked",
                    c.time_desc and (" · " .. c.time_desc) or "")
                local lf = ui.font("sans", 30)
                lf:draw_top(s, x, y, lf:ellipsize(line, w), BLACK)
                y = y + lf.height + dp(12)
                ctx:button_row(x, y, w, dp(96), {
                    { "Accept", function() self:accept(c) end, { style = "solid", size = 32 } },
                    { "Decline", function() self:decline(c) end, { size = 32 } },
                })
                y = y + dp(96) + dp(26)
            end
            if #ch > 2 then
                local mf = ui.font("sans", 26)
                mf:draw_top(s, x, y - dp(10), "+ " .. (#ch - 2) .. " more on online-go.com", DARK)
                y = y + mf.height + dp(10)
            end
        end
        -- games
        y = y + section(ctx, x, y, "MY GAMES")
        s:fill_rect(x, y - dp(4), w, ui.BORDER, LIGHT)
        local items = {}
        for _, g in ipairs(self.games or {}) do
            local opp = g.opponent or ((g.my_color == 1) and g.white or g.black) or {}
            local rk2 = rank_text(opp)
            local sub = string.format("%d×%d · %s · you play %s", g.width or 19, g.height or g.width or 19,
                g.speed or "?", g.my_color == 1 and "black" or (g.my_color == 2 and "white" or "?"))
            local right
            if g.phase == "stone removal" then right = "Scoring"
            elseif g.my_turn then right = "Your move"
            else right = "Waiting" end
            items[#items + 1] = {
                title = (g.my_turn and "▶ " or "") .. (opp.username or "?") .. (rk2 ~= "" and (" (" .. rk2 .. ")") or ""),
                subtitle = sub, right = right, bold = g.my_turn,
                on_tap = function() self:open(g.id, g) end,
            }
        end
        local foot = dp(110)
        ctx:list(x, y + dp(4), w, ctx.H - y - foot, items, self.state,
            { empty = self.err or "No active games. Play a bot or challenge a friend to start one.", row_h = dp(128) })
        -- footer
        local ff = ui.font("sans", 26)
        local sign = "Sign out"
        local sx = x + w - ff:width(sign)
        ff:draw_top(s, sx, ctx.H - dp(70), sign, DARK)
        ctx:hit(sx - dp(30), ctx.H - dp(100), ff:width(sign) + dp(60), dp(100), function()
            ui.confirm("Sign out?", "The saved OGS token will be removed from this Kindle.", "Sign out", function()
                api.logout()
                session.me = nil
                session.stop()
                ui.replace(LoginScreen(function() ui.replace(Lobby()) end))
            end)
        end, nil, { label = "Sign out" })
    end
    return scr
end

-- Game screen ------------------------------------------------------------------------------------
local REASON = {
    occupied = "That point is taken",
    suicide = "Suicide isn't allowed",
    ko = "Ko — play elsewhere first",
    offboard = "Off the board",
}

GameScreen = function(id, info)
    local scr = {
        id = id, info = info or {}, gd = nil, g = nil, phase = nil, nmoves = 0,
        dead = {}, pending = nil, sent = nil, clock = nil, clock_rx = 0,
        my_color = info and info.my_color or nil, handlers = {},
    }
    scr.board = goboard.new({
        on_tap = function(x, y) scr:tap_point(x, y) end,
        on_hold = function(x, y) scr:tap_point(x, y) end,
    })

    local function players()
        local p = scr.gd and scr.gd.players or {}
        return p.black or scr.info.black or {}, p.white or scr.info.white or {}
    end
    local function player(color)
        local b, w = players()
        return color == go.BLACK and b or w
    end

    function scr:speed()
        local tc = self.gd and self.gd.time_control
        return (type(tc) == "table" and tc.speed) or self.info.speed
    end
    function scr:corr() return self:speed() == "correspondence" end
    function scr:live() local sp = self:speed(); return sp ~= nil and sp ~= "correspondence" end

    function scr:my_turn()
        return self.phase == "play" and self.g ~= nil and self.my_color ~= nil and self.g.turn == self.my_color
    end

    function scr:update_screensaver()
        kindle.prevent_screensaver(self.visible and self:live() and self.phase ~= "finished" or false)
    end

    -- State ---------------------------------------------------------------------------------
    function scr:apply_gamedata(gd)
        if type(gd) ~= "table" then return end
        self.gd = gd
        local ok, g = pcall(go.from_gamedata, gd)
        if not ok then
            ui.log("ogs: bad gamedata: " .. tostring(g))
            self.err = "Couldn't read this game"
            return ui.redraw()
        end
        self.g = g
        self.nmoves = #(gd.moves or {})
        self.phase = gd.phase or g.phase or "play"
        self.dead = go.parse_points(gd.removed or "", g.w)
        self.sent, self.pending, self.err = nil, nil, nil
        if gd.clock then self:set_clock(gd.clock) end
        local me = session.me and session.me.id
        local b, w = players()
        if me then
            if b.id == me then self.my_color = go.BLACK elseif w.id == me then self.my_color = go.WHITE end
        end
        if gd.winner or gd.outcome then
            self.result = { winner = gd.winner, outcome = gd.outcome, score = gd.score }
        end
        if self.phase ~= "stone removal" then self.i_accepted, self.opp_accepted = false, false end
        self:update_screensaver()
        ui.redraw()
    end

    function scr:set_clock(c)
        self.clock = c
        self.clock_rx = sys.now()
    end

    function scr:resync()
        ui.busy("Refreshing…")
        local gd, err = api.game(self.id)
        if not gd then
            ui.toast("Couldn't load game: " .. tostring(err))
            return
        end
        self:apply_gamedata(gd)
    end

    function scr:revert(msg)
        if self.before then self.g = self.before end
        self.before = nil
        if self.sent then self.nmoves = self.sent.n - 1 end
        self.sent = nil
        ui.toast(msg)
        ui.redraw()
    end

    -- Realtime events -----------------------------------------------------------------------------
    function scr:on_move(d)
        if not self.g or type(d) ~= "table" then return end
        local mv = d.move or {}
        local x, y = mv[1], mv[2]
        if x == nil then return end
        -- move_number counts moves including this one (goban checks
        -- getMoveNumber() == move_number - 1), handicap placements included.
        local n = tonumber(d.move_number)
        local sent = self.sent
        if sent and (n == sent.n or (n == nil and sent.x == x and sent.y == y)) then
            -- the server echoed our own move
            self.sent, self.before = nil, nil
            if sent.x ~= x or sent.y ~= y then return self:resync() end
            return ui.redraw()
        end
        n = n or (self.nmoves + 1)
        if n <= self.nmoves then return end
        if n > self.nmoves + 1 then return self:resync() end
        local ok = self.g:play(x, y)
        if not ok then return self:resync() end
        self.nmoves = n
        self.pending = nil
        ui.redraw()
    end

    function scr:on_phase(p)
        if type(p) ~= "string" then return end
        local old = self.phase
        self.phase = p
        self.pending = nil
        if p == "stone removal" and old ~= p then
            self.dead = go.parse_points(self.gd and self.gd.removed or "", self.g and self.g.w or 19)
            self.i_accepted, self.opp_accepted = false, false
        elseif p == "play" then
            self.dead = {}
            self.i_accepted, self.opp_accepted = false, false
        elseif p == "finished" then
            self.sent = nil
            if not self.result then
                -- fetch winner / outcome over REST once the server has settled
                ui.after(800, function() if self.visible and not self.result then self:resync() end end, self)
            end
        end
        self:update_screensaver()
        ui.redraw()
    end

    function scr:on_removed(d)
        if not self.g or type(d) ~= "table" then return end
        if d.all_removed then
            self.dead = go.parse_points(d.all_removed, self.g.w)
        else
            for i in pairs(go.parse_points(d.stones or "", self.g.w)) do self.dead[i] = d.removed and true or nil end
        end
        if self.gd then self.gd.removed = go.points_string(self.dead, self.g.w) end
        -- any change voids earlier acceptances
        self.i_accepted, self.opp_accepted = false, false
        ui.redraw()
    end

    function scr:on_accepted(d)
        if type(d) ~= "table" then return end
        if d.phase == "finished" or d.winner then
            self.result = { winner = d.winner, outcome = d.outcome, score = d.score }
            if d.stones and self.g then self.dead = go.parse_points(d.stones, self.g.w) end
            if self.gd then self.gd.winner, self.gd.outcome, self.gd.score = d.winner, d.outcome, d.score end
            self.phase = "finished"
            self:update_screensaver()
        else
            local me = session.me and session.me.id
            if me and d.player_id == me then
                self.i_accepted = true
            else
                self.opp_accepted = true
                if not self.i_accepted then ui.toast("Your opponent accepted the score") end
            end
        end
        ui.redraw()
    end

    function scr:subscribe()
        if self.subscribed then return end
        local rt = api.realtime()
        local pre = "game/" .. tostring(self.id) .. "/"
        local h = {
            gamedata = function(d) self:apply_gamedata(d) end,
            move = function(d) self:on_move(d) end,
            clock = function(d) if type(d) == "table" then self:set_clock(d); ui.redraw_quiet() end end,
            phase = function(d) self:on_phase(d) end,
            removed_stones = function(d) self:on_removed(d) end,
            removed_stones_accepted = function(d) self:on_accepted(d) end,
            error = function(d)
                if self.sent then self:revert("Move rejected: " .. tostring(d)) else ui.toast("OGS: " .. tostring(d)) end
                ui.after(500, function() if self.visible then self:resync() end end, self)
            end,
        }
        for ev, fn in pairs(h) do rt:on(pre .. ev, fn) end
        -- socket state (RT reconnects by itself and re-sends game/connect,
        -- which brings fresh gamedata)
        local st = {
            ["rt/connected"] = function() self.offline = nil; ui.redraw_quiet() end,
            ["rt/disconnected"] = function(reason) self.offline = tostring(reason or "offline"); ui.redraw_quiet() end,
        }
        for ev, fn in pairs(st) do rt:on(ev, fn) end
        self.handlers, self.state_handlers, self.subscribed = h, st, true
    end

    function scr:unsubscribe()
        if not self.subscribed then return end
        local rt = api.realtime()
        local pre = "game/" .. tostring(self.id) .. "/"
        for ev, fn in pairs(self.handlers) do rt:off(pre .. ev, fn) end
        for ev, fn in pairs(self.state_handlers or {}) do rt:off(ev, fn) end
        self.subscribed = false
    end

    -- Join the game's realtime channel. From here on RT owns the socket: it
    -- retries with backoff and re-sends game/connect after reconnecting.
    function scr:connect()
        local rt = api.realtime()
        self:subscribe()
        local ok, err = rt:game_connect(self.id)
        self.offline = (not rt.connected) and tostring(err or "offline") or nil
        ui.redraw()
    end

    -- Lifecycle -----------------------------------------------------------------------------------
    function scr:enter()
        self.visible = true
        ui.busy("Loading game…")
        local gd, err = api.game(self.id)
        if gd then self:apply_gamedata(gd) else self.err = err end
        self:connect()
        ui.every(1000, function()
            if ui.top() ~= self then return end
            if self:clock_running_color() then
                if self:corr() then
                    self.ticks = (self.ticks or 0) + 1
                    if self.ticks % 60 == 0 then ui.redraw_quiet() end
                else
                    ui.redraw_quiet()
                end
            end
        end, self)
    end
    function scr:resume() self.visible = true; self:update_screensaver() end
    function scr:leave()
        self.visible = false
        ui.cancel_owner(self)
        self:unsubscribe()
        -- always: also drops the game from RT's reconnect list when offline
        local rt = api.realtime()
        pcall(rt.game_disconnect, rt, self.id)
        session.open_games[self.id] = nil
        kindle.prevent_screensaver(false)
    end
    function scr:on_wake()
        -- Wi-Fi dropped while asleep: reload over REST, then rejoin the socket.
        ui.after(1500, function()
            if not self.visible then return end
            self:resync()
            -- the old socket is probably dead: let RT open a fresh one (it
            -- re-joins this game); don't game_connect again ourselves
            local rt = api.realtime()
            if not self.subscribed then return self:connect() end
            local ok, err = rt:reconnect()
            self.offline = (not rt.connected) and tostring(err or "offline") or nil
            ui.redraw()
        end, self)
    end

    -- Clocks --------------------------------------------------------------------------------------
    function scr:clock_running_color()
        local c = self.clock
        if not c or self.phase ~= "play" or c.paused_since then return nil end
        local b, w = players()
        if c.current_player then
            if c.current_player == (c.black_player_id or b.id) then return go.BLACK end
            if c.current_player == (c.white_player_id or w.id) then return go.WHITE end
        end
        return self.g and self.g.turn
    end

    -- returns seconds left, periods text or nil
    function scr:time_left(color)
        local c = self.clock
        if not c then return nil end
        local t = (color == go.BLACK) and c.black_time or c.white_time
        local base, periods, ptime
        if type(t) == "number" then base = t
        elseif type(t) == "table" then base, periods, ptime = t.thinking_time, t.periods, t.period_time
        else return nil end
        base = base or 0
        if self:clock_running_color() == color then
            local elapsed = (sys.now() - self.clock_rx) / 1000
            if c.last_move then
                local srv_now = c.now or self.clock_rx
                elapsed = elapsed + math.max(0, (srv_now - c.last_move) / 1000)
            end
            base = base - elapsed
            if base < 0 and periods and ptime and ptime > 0 then
                local over = -base
                local used = math.floor(over / ptime)
                periods = math.max(0, periods - used)
                base = (periods > 0) and (ptime - over % ptime) or 0
            end
        end
        local ptxt
        if periods and ptime then ptxt = string.format("%d×%ds", periods, ptime) end
        return base, ptxt
    end

    -- Moves ------------------------------------------------------------------------------------------
    function scr:tap_point(x, y)
        if not self.g then return end
        if self.phase == "stone removal" then return self:toggle_dead(x, y) end
        if self.phase ~= "play" then return end
        if self.my_color == nil then return ui.toast("You're not playing in this game") end
        if self.sent then return end
        if not self:my_turn() then return ui.toast("Waiting for your opponent's move") end
        local p = self.pending
        if p and p.x == x and p.y == y then return self:submit(x, y) end
        local ok, why = self.g:legal(x, y)
        if not ok then
            return ui.toast(REASON[why] or ("Illegal move: " .. tostring(why)), 2000)
        end
        self.pending = { x = x, y = y, color = self.my_color }
        ui.redraw()
    end

    function scr:submit(x, y)
        local rt, err = session.ensure_rt()
        if not rt then
            ui.toast("Not connected: " .. tostring(err))
            return
        end
        if not self.subscribed or not rt.games[self.id] then self:connect() end
        self.before = self.g:copy()
        local ok, why = self.g:play(x, y)
        if not ok then
            self.before = nil
            return ui.toast(REASON[why] or ("Illegal move: " .. tostring(why)))
        end
        self.pending = nil
        self.nmoves = self.nmoves + 1
        local sent = { n = self.nmoves, x = x, y = y }
        self.sent = sent
        ui.render_now()
        local r1, r2 = rt:move(self.id, x, y)
        if failed(r1, r2) then return self:revert("Move not sent: " .. tostring(r2)) end
        -- no echo from the server in time → reload the true state
        ui.after(15000, function()
            if self.sent == sent and self.visible then
                ui.toast("No answer from OGS; reloading")
                self:resync()
            end
        end, self)
        ui.redraw()
    end

    function scr:pass()
        ui.confirm("Pass?", "If your opponent passes too, the game goes to scoring.", "Pass", function()
            self:submit(-1, -1)
        end)
    end

    function scr:resign()
        ui.confirm("Resign?", "This ends the game as a loss.", "Resign", function()
            local rt, err = session.ensure_rt()
            if not rt then return ui.toast("Not connected: " .. tostring(err)) end
            local r1, r2 = rt:resign(self.id)
            if failed(r1, r2) then return ui.toast("Couldn't resign: " .. tostring(r2)) end
            ui.after(4000, function()
                if self.visible and self.phase ~= "finished" then self:resync() end
            end, self)
        end)
    end

    function scr:toggle_dead(x, y)
        if not self.g then return end
        -- OGS toggles whole empty regions (dame); we only toggle stone groups
        if self.g:at(x, y) == go.EMPTY then return ui.toast("Tap a group of stones to mark it dead or alive") end
        local before = {}
        for i in pairs(self.dead) do before[i] = true end
        local changed, now_dead = go.toggle_group_dead(self.g, self.dead, x, y)
        local set = {}
        for k, v in pairs(changed or {}) do
            local i = (v == true) and k or v
            if type(i) == "number" then set[i] = true; self.dead[i] = now_dead and true or nil end
        end
        if next(set) == nil then return end
        self.i_accepted, self.opp_accepted = false, false
        ui.redraw()
        local rt, err = session.ensure_rt()
        if not rt then
            self.dead = before
            return ui.toast("Not connected: " .. tostring(err))
        end
        local r1, r2 = rt:removed_set(self.id, now_dead and true or false, go.points_string(set, self.g.w))
        if failed(r1, r2) then
            self.dead = before
            ui.toast("Couldn't send: " .. tostring(r2))
        end
    end

    function scr:accept_score()
        local rt, err = session.ensure_rt()
        if not rt then return ui.toast("Not connected: " .. tostring(err)) end
        local r1, r2 = rt:removed_accept(self.id, go.points_string(self.dead, self.g.w))
        if failed(r1, r2) then return ui.toast("Couldn't accept: " .. tostring(r2)) end
        self.i_accepted = true
        ui.redraw()
    end

    function scr:resume_play()
        local rt, err = session.ensure_rt()
        if not rt then return ui.toast("Not connected: " .. tostring(err)) end
        local r1, r2 = rt:removed_reject(self.id)
        if failed(r1, r2) then return ui.toast("Couldn't resume: " .. tostring(r2)) end
    end

    -- Text ------------------------------------------------------------------------------------------
    local function score_totals(sc)
        if type(sc) ~= "table" then return nil end
        local function tot(v)
            if type(v) == "number" then return v end
            if type(v) == "table" then return tonumber(v.total) end
        end
        local b, w = tot(sc.black), tot(sc.white)
        if b and w then return b, w end
    end

    function scr:result_text()
        local r = self.result or {}
        local b, w = players()
        local who
        if r.winner == "black" or (r.winner ~= nil and r.winner == b.id) then who = go.BLACK
        elseif r.winner == "white" or (r.winner ~= nil and r.winner == w.id) then who = go.WHITE end
        local head
        if who and self.my_color then head = (who == self.my_color) and "You won" or "You lost"
        elseif who then head = (who == go.BLACK and "Black" or "White") .. " won"
        else head = "Game over" end
        local o = r.outcome and tostring(r.outcome) or ""
        local tail = ""
        if o:match("^[%d%.]+ points?$") then tail = " by " .. o
        elseif o:lower() == "resignation" then tail = " by resignation"
        elseif o:lower() == "timeout" then tail = " on time"
        elseif o ~= "" then tail = " — " .. o end
        return head .. tail
    end

    function scr:local_score()
        if not self.g then return nil end
        local ok, sc = pcall(go.score, self.g, self.dead)
        if ok then return sc end
        ui.log("ogs: score failed: " .. tostring(sc))
    end

    -- Drawing ---------------------------------------------------------------------------------------
    local CARD_NF, CARD_SF, CARD_CF = 30, 24, 36
    local function card_height()
        local nf, sf = ui.font("bold", CARD_NF), ui.font("sans", CARD_SF)
        local cf = ui.font("bold", CARD_CF)
        local row1 = math.max(nf.height, cf.height + dp(14))
        return dp(14) + row1 + dp(8) + sf.height + dp(14), row1
    end

    local function player_card(ctx, x, y, w, h, color)
        local s = ctx.s
        local p = player(color)
        local to_move = (scr.phase == "play" and scr.g and scr.g.turn == color)
        s:fill_round_rect(x, y, w, h, ui.R, WHITE)
        s:round_rect(x, y, w, h, ui.R, to_move and BLACK or LIGHT, to_move and dp(6) or ui.BORDER)
        local _, row1 = card_height()
        local nf = ui.font("bold", CARD_NF)
        local pad = dp(18)
        local r = math.floor(math.min(dp(24), nf.height * 0.5))
        local ry = y + dp(14) + math.floor(row1 / 2)
        stone_icon(s, x + pad + r, ry, r, color)
        -- clock box on the right
        local secs, ptxt = scr:time_left(color)
        local running = scr:clock_running_color() == color
        local cf = ui.font("bold", CARD_CF)
        local clock_txt = secs and fmt_secs(secs, scr:corr()) or ""
        local cw = 0
        if clock_txt ~= "" then
            cw = math.max(dp(150), cf:width(clock_txt) + dp(28))
            local cx, cy, chh = x + w - cw - dp(12), y + dp(14), row1
            if running then
                s:fill_round_rect(cx, cy, cw, chh, dp(10), BLACK)
                cf:draw_center(s, cx, cy, cw, chh, clock_txt, WHITE)
            else
                s:round_rect(cx, cy, cw, chh, dp(10), DARK, ui.BORDER)
                cf:draw_center(s, cx, cy, cw, chh, clock_txt, BLACK)
            end
            cw = cw + dp(12)
        end
        local tx = x + pad + 2 * r + dp(14)
        local name = (p.username or "?")
        local avail = x + w - cw - tx - dp(8)
        -- " (you)" only when it fits; the card's bold border marks you anyway
        if scr.my_color == color and nf:width(name .. " (you)") <= avail then name = name .. " (you)" end
        nf:draw_top(s, tx, ry - math.floor(nf.height / 2), nf:ellipsize(name, avail), BLACK)
        local sf = ui.font("sans", CARD_SF)
        local caps = scr.g and scr.g.captures and scr.g.captures[color] or 0
        local parts = {}
        local rk = rank_text(p)
        if rk ~= "" then parts[#parts + 1] = rk end
        parts[#parts + 1] = caps .. (caps == 1 and " capture" or " captures")
        local line2 = table.concat(parts, " · ")
        sf:draw_top(s, x + pad, y + h - sf.height - dp(14), sf:ellipsize(line2, w - 2 * pad - (ptxt and dp(130) or 0)), DARK)
        if ptxt then
            sf:draw_top(s, x + w - dp(12) - sf:width(ptxt) - dp(6), y + h - sf.height - dp(14), ptxt, DARK)
        end
    end

    function scr:status_lines()
        local g = self.g
        if not g then
            return self.err and ("Couldn't load: " .. tostring(self.err)) or "Loading…", ""
        end
        local opp = player(self.my_color == go.BLACK and go.WHITE or go.BLACK)
        local info = string.format("%s · komi %s · move %d", cap(self.gd and self.gd.rules or g.rules or "?"),
            tostring(self.gd and self.gd.komi or g.komi or "?"), self.nmoves)
        if self.offline then info = "Offline · " .. info end
        if self.phase == "finished" then
            local sc = self.result and self.result.score
            local b, w = score_totals(sc)
            if not b then
                local ls = self:local_score()
                if ls and next(self.dead) then b, w = ls.black, ls.white end
            end
            local sub = b and string.format("Black %g · White %g", b, w) or info
            return self:result_text(), sub
        elseif self.phase == "stone removal" then
            local sc = self:local_score()
            local head = "Tap groups to mark them dead"
            if self.i_accepted then head = "You accepted — waiting for opponent"
            elseif self.opp_accepted then head = "Opponent accepted — check and accept" end
            local sub = info
            if sc then
                local diff = sc.black - sc.white
                sub = string.format("Black %g · White %g  →  %s+%g", sc.black, sc.white,
                    diff >= 0 and "B" or "W", math.abs(diff))
            end
            return head, sub
        end
        local head
        local last = g.moves and g.moves[#g.moves]
        if self.sent then head = "Sending move…"
        elseif self.pending then
            head = "Play " .. point_name(self.pending.x, self.pending.y, g.h) .. "? Tap it again or Confirm"
        elseif self:my_turn() then
            head = (last and last.x == -1) and "Your move — opponent passed" or "Your move"
        elseif self.my_color then
            head = "Waiting for " .. (opp.username or "opponent") .. "…"
        else
            head = (g.turn == go.BLACK and "Black" or "White") .. " to play"
        end
        return head, info
    end

    function scr:render(ctx)
        local s = ctx.s
        local W, H = ctx.W, ctx.H
        local g = self.g
        local title = "Go"
        if g then title = string.format("%d×%d · %s", g.w, g.h, cap(self:speed() or "game")) end
        local top = ctx:header(title, { right = { "☰", function() self:menu() end, size = 44 } })
        local margin = dp(16)
        local card_h = card_height()
        local y = top + dp(12)
        local cw = math.floor((W - 2 * margin - dp(16)) / 2)
        player_card(ctx, margin, y, cw, card_h, go.BLACK)
        player_card(ctx, W - margin - cw, y, cw, card_h, go.WHITE)
        y = y + card_h + dp(12)
        local sf = ui.font("bold", 34)
        local mf = ui.font("sans", 28)
        local bottom = sf.height + mf.height + dp(24) + dp(100) + dp(28)
        local bsize = math.min(W - 2 * margin, H - y - bottom)
        local bx = math.floor((W - bsize) / 2)
        if g then
            local ov = { coords = load_prefs().coords, last = g.last }
            if ov.last and ov.last.x == -1 then ov.last = nil end
            if self.pending then ov.pending = { x = self.pending.x, y = self.pending.y, color = self.pending.color } end
            if self.phase == "stone removal" or self.phase == "finished" then
                ov.dead = self.dead
                if self.phase == "stone removal" or next(self.dead) then
                    local sc = self:local_score()
                    ov.territory = sc and sc.territory
                end
            end
            self.board:draw(ctx, g, bx, y, bsize, ov)
        else
            s:round_rect(bx, y, bsize, bsize, ui.R, LIGHT, ui.BORDER)
        end
        y = y + bsize + dp(12)
        local head, sub = self:status_lines()
        local tx, tw = margin + dp(8), W - 2 * margin - dp(16)
        sf:draw_top(s, tx, y, sf:ellipsize(head, tw), BLACK)
        mf:draw_top(s, tx, y + sf.height + dp(6), mf:ellipsize(sub or "", tw), DARK)
        y = y + sf.height + mf.height + dp(20)
        local items
        local bs = 32
        if not g then
            items = { { "Retry", function() self:resync(); self:connect() end, { style = "solid", size = bs } } }
        elseif self.phase == "finished" then
            items = { { "Back to games", function() ui.pop(self) end, { style = "solid", size = bs } } }
        elseif self.phase == "stone removal" then
            items = {
                { "Resume play", function() self:resume_play() end, { size = bs } },
                { self.i_accepted and "Accepted" or "Accept score", (not self.i_accepted) and function() self:accept_score() end or nil,
                    { style = self.i_accepted and "disabled" or "solid", size = bs } },
            }
        elseif self.pending then
            items = {
                { "Cancel", function() self.pending = nil; ui.redraw() end, { size = bs } },
                { "Confirm " .. point_name(self.pending.x, self.pending.y, g.h), function()
                    self:submit(self.pending.x, self.pending.y)
                end, { style = "solid", size = bs } },
            }
        elseif self.my_color then
            local can = self:my_turn() and not self.sent
            items = {
                { "Pass", can and function() self:pass() end or nil, { style = can and "outline" or "disabled", size = bs } },
                { "Resign", function() self:resign() end, { size = bs } },
            }
        else
            items = { { "Back to games", function() ui.pop(self) end, { size = bs } } }
        end
        local rh = math.min(dp(100), H - y - dp(12))
        if rh > dp(56) then ctx:button_row(margin, y, W - 2 * margin, rh, items) end
    end

    function scr:menu()
        local p = load_prefs()
        local opts = {
            { title = "Reload game", subtitle = "Fetch the current state from online-go.com" },
            { title = p.coords and "Hide coordinates" or "Show coordinates" },
            { title = "Game link", subtitle = "online-go.com/game/" .. tostring(self.id) },
            { title = "Back to games" },
        }
        ui.choose("Game", opts, function(i, it)
            if i == 1 then self:resync(); if not api.realtime().connected then self:connect() end
            elseif i == 2 then p.coords = not p.coords; save_prefs()
            elseif i == 3 then ui.toast("online-go.com/game/" .. tostring(self.id))
            elseif i == 4 then ui.pop(self) end
            ui.redraw()
        end)
    end

    return scr
end

-- Entry ------------------------------------------------------------------------------------------------
function M.new()
    local root = {}
    function root:enter()
        load_prefs()
        if api.load() then
            ui.replace(Lobby())
        else
            ui.replace(LoginScreen(function() ui.replace(Lobby()) end))
        end
    end
    function root:render(ctx) ctx:header("Go (OGS)") end
    return root
end

M.Lobby, M.LoginScreen, M.GameScreen, M.ChallengeScreen = Lobby, LoginScreen, GameScreen, ChallengeScreen
return M
