-- Lichess client: lobby, seeks, AI and friend challenges, and live games
-- through the Board API.
local ui = require("core.ui")
local gfx = require("core.gfx")
local sys = require("core.sys")
local store = require("core.store")
local kindle = require("core.kindle")
local keyboard = require("core.keyboard")
local chess = require("apps.lib.chess")
local boardlib = require("apps.lib.board")
local api = require("apps.lichess.api")

local dp = ui.dp
local BLACK, WHITE, DARK, GRAY, PALE, LIGHT, MID = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.GRAY, gfx.PALE, gfx.LIGHT, gfx.MID

local M = {}

-- Time controls ------------------------------------------------------------------------
local SEEK_TC = {
    { "10+0", 10, 0 }, { "10+5", 10, 5 }, { "15+10", 15, 10 }, { "30+0", 30, 0 },
    { "30+20", 30, 20 }, { "1 day", nil, nil, 1 }, { "3 days", nil, nil, 3 }, { "7 days", nil, nil, 7 },
}
local DIRECT_TC = {
    { "3+2", 3, 2 }, { "5+0", 5, 0 }, { "5+3", 5, 3 }, { "10+0", 10, 0 }, { "10+5", 10, 5 },
    { "15+10", 15, 10 }, { "30+0", 30, 0 }, { "1 day", nil, nil, 1 }, { "3 days", nil, nil, 3 },
}

local function tc_label(tc) return tc[1] end

local function fmt_clock(ms)
    if not ms then return "--:--" end
    if ms < 0 then ms = 0 end
    local s = math.floor(ms / 1000)
    if s >= 86400 then return string.format("%dd %dh", math.floor(s / 86400), math.floor(s % 86400 / 3600)) end
    if s >= 3600 then return string.format("%d:%02d:%02d", math.floor(s / 3600), math.floor(s % 3600 / 60), s % 60) end
    if s < 20 then return string.format("%d:%02d.%d", math.floor(s / 60), s % 60, math.floor(ms % 1000 / 100)) end
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
M.fmt_clock = fmt_clock

-- Draw a grid of selectable chips. Returns height used.
local function chips(ctx, x, y, w, items, sel, on_pick, cols)
    cols = cols or 4
    local gap = dp(14)
    local cw = math.floor((w - gap * (cols - 1)) / cols)
    local ch = dp(96)
    for i, it in ipairs(items) do
        local r, c = math.floor((i - 1) / cols), (i - 1) % cols
        ctx:button(x + c * (cw + gap), y + r * (ch + gap), cw, ch, type(it) == "table" and it[1] or it,
            function() on_pick(i) end, { selected = (i == sel), size = 32 })
    end
    local rows = math.ceil(#items / cols)
    return rows * ch + (rows - 1) * gap
end

local function section(ctx, x, y, label)
    local f = ui.font("bold", 30)
    f:draw_top(ctx.s, x, y, label, DARK)
    return f.height + dp(14)
end

-- Session: token, account, event stream --------------------------------------------------
local session = {
    account = nil, challenges = {}, outgoing = nil, events = nil, events_ok = false,
    open_games = {}, retry_timer = nil,
}
M.session = session

local GameScreen -- forward

function session.on_event(ev)
    local t = ev.type
    if t == "gameStart" then
        local g = ev.game or {}
        local id = g.gameId or g.id
        session.outgoing = nil
        if session.seeking then session.seeking:found() end
        if session.waiting then ui.pop(session.waiting) end
        if id then session.open_game(id, g) end
    elseif t == "gameFinish" then
        local g = ev.game or {}
        local scr = session.open_games[g.gameId or g.id or ""]
        if scr then scr:refresh_soon() end
    elseif t == "challenge" then
        local c = ev.challenge or {}
        local me = session.account and session.account.id
        if c.challenger and c.challenger.id == me then
            session.outgoing = c
        else
            session.challenges[c.id] = c
            ui.toast("Challenge from " .. ((c.challenger or {}).name or "someone"))
        end
    elseif t == "challengeCanceled" or t == "challengeDeclined" then
        local c = ev.challenge or {}
        session.challenges[c.id] = nil
        if session.outgoing and session.outgoing.id == c.id then
            session.outgoing = nil
            if session.waiting then session.waiting:declined(t == "challengeDeclined" and (c.declineReason or "Declined") or "Canceled") end
        end
    end
    ui.redraw()
end

function session.start_events()
    if session.events and not session.events.closed then return true end
    local st, err = api.event_stream(session.on_event, function(reason)
        session.events_ok = false
        ui.redraw()
        if session.active then
            -- reconnect with a delay
            ui.cancel(session.retry_timer)
            session.retry_timer = ui.after(5000, function()
                session.retry_timer = nil
                if session.active then session.start_events() end
            end)
        end
    end)
    if not st then
        session.events_ok = false
        ui.log("lichess events: " .. tostring(err))
        if session.active then
            ui.cancel(session.retry_timer)
            session.retry_timer = ui.after(15000, function()
                session.retry_timer = nil
                if session.active then session.start_events() end
            end)
        end
        return nil, err
    end
    session.events = st
    session.events_ok = true
    ui.add_stream(st)
    return true
end

function session.stop()
    session.active = false
    ui.cancel(session.retry_timer)
    if session.events then session.events:close("bye") end
    session.events = nil
end

function session.open_game(id, info)
    if session.open_games[id] then return end
    local scr = GameScreen(id, info)
    session.open_games[id] = scr
    ui.push(scr)
end

-- Token screen ---------------------------------------------------------------------------
local function TokenScreen(on_ok)
    local scr = { msg = nil }
    local function try(token)
        token = (token or ""):gsub("%s", "")
        if token == "" then return end
        ui.busy("Checking token…")
        local old = api.token
        api.token = token
        local acc, err = api.account()
        if not acc then
            api.token = old
            scr.msg = err
            ui.redraw()
            return
        end
        api.save_token(token)
        session.account = acc
        on_ok()
    end

    function scr:render(ctx)
        local top = ctx:header("Connect to Lichess")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(30)
        local f = ui.font("sans", 32)
        y = y + ctx:paragraph(x, y, w,
            "This app uses the Lichess Board API with a personal access token.", { font = f }) + dp(24)
        y = y + ctx:paragraph(x, y, w, "1. On a computer or phone, open:", { font = f }) + dp(10)
        y = y + ctx:paragraph(x + dp(30), y, w - dp(30), "lichess.org/account/oauth/token/create", { font = ui.font("bold", 32) }) + dp(10)
        y = y + ctx:paragraph(x, y, w,
            "2. Tick the scopes \"Play games with the board API\" (board:play), \"Read incoming challenges\" and \"Create, accept, decline challenges\". Create the token.",
            { font = f }) + dp(24)
        y = y + ctx:paragraph(x, y, w,
            "3. Either type it below, or save it as a text file on the Kindle over USB at:", { font = f }) + dp(10)
        y = y + ctx:paragraph(x + dp(30), y, w - dp(30), "extensions/einkapps/data/lichess_token.txt",
            { font = ui.font("bold", 28) }) + dp(36)
        ctx:button(x, y, w, ui.BTN_H, "Type token", function()
            keyboard({
                title = "Lichess token", hint = "lip_…", start_mode = "lower",
                help = "Tokens start with lip_. Letters are case-sensitive.",
                on_done = try,
            })
        end, { style = "solid" })
        y = y + ui.BTN_H + dp(20)
        ctx:button(x, y, w, ui.BTN_H, "Load token file", function()
            local t = api.load_token()
            if not t then
                scr.msg = "No token file found at data/lichess_token.txt"
                ui.redraw()
                return
            end
            try(t)
        end)
        y = y + ui.BTN_H + dp(30)
        if self.msg then
            ctx:paragraph(x, y, w, self.msg, { font = ui.font("bold", 30) })
        end
    end
    return scr
end

-- Game options screens ---------------------------------------------------------------------
local prefs = nil
local function load_prefs()
    if not prefs then
        prefs = store.load("lichess_prefs", { seek_tc = 2, seek_rated = false, ai_level = 3, ai_tc = 5,
            ai_color = 2, friend_tc = 5, friend_color = 2, friend_rated = false, friend_name = "" })
    end
    return prefs
end
local function save_prefs() store.save("lichess_prefs", prefs) end

local function tc_params(tc, kind)
    local p = {}
    if tc[4] then
        p.days = tc[4]
    elseif kind == "seek" then
        p.time, p.increment = tc[2], tc[3]
    else
        p["clock.limit"], p["clock.increment"] = tc[2] * 60, tc[3]
    end
    return p
end

local COLORS = { "white", "random", "black" }

-- Waiting overlay for an outgoing seek
local function SeekingScreen(tc, rated)
    local scr = { started = sys.now() }
    function scr:enter()
        session.seeking = self
        local p = tc_params(tc, "seek")
        p.rated = rated
        if tc[4] then
            local res, err = api.seek(p)
            if not res then
                ui.pop(self)
                ui.alert("Seek failed", err)
                return
            end
            self.corr_id = type(res) == "table" and res.id or nil
            self.corr = true
            return
        end
        local st, err = api.seek(p, function(reason)
            -- server closes when accepted or expired
            self.stream = nil
            if not self.done then
                ui.after(3000, function()
                    if not self.done and ui.top() == self then
                        self.expired = true
                        ui.redraw()
                    end
                end)
            end
        end)
        if not st then
            ui.pop(self)
            ui.alert("Seek failed", err)
            return
        end
        self.stream = st
        ui.add_stream(st)
        self.timer = ui.every(1000, function() ui.redraw_quiet() end, self)
    end
    function scr:found()
        self.done = true
        ui.pop(self)
    end
    function scr:leave()
        session.seeking = nil
        ui.cancel_owner(self)
        if self.stream then self.stream:close("cancel") end
    end
    function scr:render(ctx)
        local top = ctx:header("Finding opponent", { back_label = "✕" })
        local cx = ctx.W / 2
        local y = top + dp(200)
        local f = ui.font("bold", 56)
        f:draw_center(ctx.s, 0, y, ctx.W, f.height, tc_label(tc) .. (rated and " rated" or " casual"), BLACK)
        y = y + f.height + dp(60)
        local info
        if self.corr then
            info = "Correspondence seek posted. It stays open on Lichess until someone accepts; you'll find the game under Ongoing games."
        elseif self.expired then
            info = "The seek ended without a game. Try again or pick another time control."
        else
            local secs = math.floor((sys.now() - self.started) / 1000)
            info = string.format("Waiting for a player… %d:%02d\n\nKeep this screen open — leaving cancels the seek.", math.floor(secs / 60), secs % 60)
        end
        ctx:paragraph(ui.M, y, ctx.W - 2 * ui.M, info, { font = ui.font("sans", 34), align = "center" })
        ctx:button(ui.M, ctx.H - ui.BTN_H - dp(60), ctx.W - 2 * ui.M, ui.BTN_H,
            (self.corr or self.expired) and "Back" or "Cancel", function() ui.pop(self) end)
    end
    return scr
end

local function SeekScreen()
    local scr = {}
    function scr:render(ctx)
        local p = load_prefs()
        local top = ctx:header("Quick pairing")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(30)
        y = y + section(ctx, x, y, "TIME CONTROL")
        y = y + chips(ctx, x, y, w, SEEK_TC, p.seek_tc, function(i) p.seek_tc = i; save_prefs(); ui.redraw() end, 4) + dp(30)
        ctx:paragraph(x, y, w, "Lichess allows rapid, classical and correspondence games for seeks made through the Board API.",
            { font = ui.font("sans", 26), color = DARK })
        y = y + dp(90)
        ctx:toggle(x, y, w, dp(100), "Rated game", p.seek_rated, function(v) p.seek_rated = v; save_prefs(); ui.redraw() end)
        y = y + dp(130)
        ctx:button(x, ctx.H - ui.BTN_H - dp(50), w, ui.BTN_H, "Find opponent", function()
            ui.push(SeekingScreen(SEEK_TC[p.seek_tc], p.seek_rated))
        end, { style = "solid" })
    end
    return scr
end

local function AIScreen()
    local scr = {}
    function scr:render(ctx)
        local p = load_prefs()
        local top = ctx:header("Play the computer")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(30)
        y = y + section(ctx, x, y, "STRENGTH (Stockfish level)")
        y = y + chips(ctx, x, y, w, { "1", "2", "3", "4", "5", "6", "7", "8" }, p.ai_level,
            function(i) p.ai_level = i; save_prefs(); ui.redraw() end, 8) + dp(36)
        y = y + section(ctx, x, y, "TIME CONTROL")
        y = y + chips(ctx, x, y, w, DIRECT_TC, p.ai_tc, function(i) p.ai_tc = i; save_prefs(); ui.redraw() end, 3) + dp(36)
        y = y + section(ctx, x, y, "YOUR COLOR")
        ctx:segmented(x, y, w, dp(96), { "White", "Random", "Black" }, p.ai_color,
            function(i) p.ai_color = i; save_prefs(); ui.redraw() end)
        ctx:button(x, ctx.H - ui.BTN_H - dp(50), w, ui.BTN_H, "Start game", function()
            local params = tc_params(DIRECT_TC[p.ai_tc], "challenge")
            params.level = p.ai_level
            params.color = COLORS[p.ai_color]
            ui.busy("Starting game…")
            local res, err = api.challenge_ai(params)
            if not res then return ui.alert("Couldn't start", err) end
            ui.pop(scr)
            if type(res) == "table" and res.id then session.open_game(res.id, res) end
        end, { style = "solid" })
    end
    return scr
end

local function WaitingScreen(challenge, name)
    local scr = {}
    function scr:enter() session.waiting = self end
    function scr:leave() session.waiting = nil end
    function scr:declined(reason)
        self.reason = reason
        ui.redraw()
    end
    function scr:render(ctx)
        local top = ctx:header("Challenge sent", { back_label = "✕" })
        local y = top + dp(200)
        local msg = self.reason and (name .. " declined: " .. self.reason)
            or ("Waiting for " .. name .. " to accept.\n\nThe game opens automatically when they do. You can also share this link:\n\nlichess.org/" .. (challenge.id or ""))
        ctx:paragraph(ui.M, y, ctx.W - 2 * ui.M, msg, { font = ui.font("sans", 34), align = "center" })
        local items = {}
        if not self.reason then
            items[#items + 1] = { "Cancel challenge", function()
                ui.busy("Canceling…")
                api.cancel_challenge(challenge.id)
                ui.pop(scr)
            end }
        end
        items[#items + 1] = { "Back", function() ui.pop(scr) end }
        ctx:button_row(ui.M, ctx.H - ui.BTN_H - dp(60), ctx.W - 2 * ui.M, ui.BTN_H, items)
    end
    return scr
end

local function FriendScreen()
    local scr = {}
    function scr:render(ctx)
        local p = load_prefs()
        local top = ctx:header("Challenge a friend")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(30)
        y = y + section(ctx, x, y, "OPPONENT'S USERNAME")
        ctx:button(x, y, w, dp(110), p.friend_name ~= "" and p.friend_name or "Tap to type…", function()
            keyboard({ title = "Lichess username", text = p.friend_name, on_done = function(t)
                p.friend_name = t:gsub("%s", ""); save_prefs(); ui.redraw()
            end })
        end, { align = "left", bold = false })
        y = y + dp(140)
        y = y + section(ctx, x, y, "TIME CONTROL")
        y = y + chips(ctx, x, y, w, DIRECT_TC, p.friend_tc, function(i) p.friend_tc = i; save_prefs(); ui.redraw() end, 3) + dp(36)
        y = y + section(ctx, x, y, "YOUR COLOR")
        ctx:segmented(x, y, w, dp(96), { "White", "Random", "Black" }, p.friend_color,
            function(i) p.friend_color = i; save_prefs(); ui.redraw() end)
        y = y + dp(130)
        ctx:toggle(x, y, w, dp(100), "Rated game", p.friend_rated, function(v) p.friend_rated = v; save_prefs(); ui.redraw() end)
        ctx:button(x, ctx.H - ui.BTN_H - dp(50), w, ui.BTN_H, "Send challenge", function()
            if p.friend_name == "" then return ui.toast("Enter a username first") end
            local params = tc_params(DIRECT_TC[p.friend_tc], "challenge")
            params.color = COLORS[p.friend_color]
            params.rated = p.friend_rated
            ui.busy("Sending challenge…")
            local res, err = api.challenge_user(p.friend_name, params)
            if not res then return ui.alert("Challenge failed", err) end
            local ch = (type(res) == "table" and (res.challenge or res)) or {}
            ui.replace(WaitingScreen(ch, p.friend_name))
        end, { style = "solid" })
    end
    return scr
end

local function OngoingScreen()
    local scr = { state = { page = 1 }, games = nil }
    function scr:enter() self:load() end
    function scr:resume() self:load() end
    function scr:load()
        ui.busy("Loading games…")
        local res, err = api.playing()
        if not res then
            self.err = err
            self.games = {}
        else
            self.err = nil
            self.games = res.nowPlaying or {}
        end
        ui.redraw()
    end
    function scr:render(ctx)
        local top = ctx:header("Ongoing games", { right = { "⟲", function() self:load() end, size = 44 } })
        local items = {}
        for _, g in ipairs(self.games or {}) do
            local opp = g.opponent or {}
            local sub = (g.speed or "") .. (g.rated and " · rated" or " · casual")
            if g.secondsLeft then sub = sub .. " · " .. fmt_clock(g.secondsLeft * 1000) .. " left" end
            items[#items + 1] = {
                title = (g.isMyTurn and "▶ " or "") .. (opp.username or "?") .. (opp.rating and (" (" .. opp.rating .. ")") or ""),
                subtitle = sub, right = g.isMyTurn and "Your move" or "Waiting", bold = g.isMyTurn,
                on_tap = function() session.open_game(g.gameId or g.fullId:sub(1, 8), g) end,
            }
        end
        ctx:list(ui.M, top + dp(10), ctx.W - 2 * ui.M, ctx.H - top - dp(30), items, self.state,
            { empty = self.err or "No ongoing games." })
    end
    return scr
end

-- Lobby ----------------------------------------------------------------------------------------
local function Lobby()
    local scr = {}

    function scr:enter()
        session.active = true
        if not session.account then
            ui.busy("Connecting to Lichess…")
            local acc, err = api.account()
            if not acc then
                self.err = err
            else
                session.account = acc
            end
        end
        if session.account then session.start_events() end
    end

    function scr:leave()
        session.stop()
        for _, c in pairs(session.challenges) do session.challenges[c.id] = nil end
    end

    function scr:on_wake()
        -- Wi-Fi drops while asleep; reconnect the event stream.
        if session.events then session.events:close("sleep") end
        session.events = nil
        ui.after(1500, function() if session.active then session.start_events() end end)
    end

    function scr:render(ctx)
        local s = ctx.s
        local top = ctx:header("Lichess", { back = function()
            ui.pop(scr)
        end })
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(28)
        local acc = session.account
        if not acc then
            ctx:paragraph(x, y, w, "Couldn't reach Lichess:\n" .. tostring(self.err or "unknown error"),
                { font = ui.font("sans", 32) })
            ctx:button(x, y + dp(300), w, ui.BTN_H, "Retry", function()
                self:enter(); ui.redraw()
            end, { style = "solid" })
            ctx:button(x, y + dp(300) + ui.BTN_H + dp(20), w, ui.BTN_H, "Change token", function()
                api.forget_token()
                ui.replace(TokenScreen(function() ui.replace(Lobby()) end))
            end)
            return
        end
        -- account card
        local nf = ui.font("bold", 44)
        nf:draw_top(s, x, y, (acc.title and (acc.title .. " ") or "") .. (acc.username or "?"), BLACK)
        local dot = session.events_ok and "● online" or "○ offline"
        local df = ui.font("sans", 28)
        df:draw_top(s, x + w - df:width(dot), y + dp(10), dot, DARK)
        y = y + nf.height + dp(14)
        local perfs = acc.perfs or {}
        local parts = {}
        for _, k in ipairs({ "blitz", "rapid", "classical", "correspondence" }) do
            local pf = perfs[k]
            if pf and pf.rating then
                local short = ({ blitz = "Blitz", rapid = "Rapid", classical = "Classical", correspondence = "Corr." })[k]
                parts[#parts + 1] = string.format("%s %d%s", short, pf.rating, pf.prov and "?" or "")
            end
        end
        local pf_font = ui.font("sans", 30)
        pf_font:draw_top(s, x, y, pf_font:ellipsize(table.concat(parts, "  ·  "), w), DARK)
        y = y + dp(70)
        s:fill_rect(x, y, w, ui.BORDER, LIGHT)
        y = y + dp(34)
        local bh = dp(124)
        ctx:button(x, y, w, bh, "Quick pairing", function() ui.push(SeekScreen()) end, { style = "solid", size = 40 })
        y = y + bh + dp(20)
        ctx:button(x, y, w, bh, "Play the computer", function() ui.push(AIScreen()) end, { size = 40 })
        y = y + bh + dp(20)
        ctx:button(x, y, w, bh, "Challenge a friend", function() ui.push(FriendScreen()) end, { size = 40 })
        y = y + bh + dp(20)
        ctx:button(x, y, w, bh, "Ongoing games", function() ui.push(OngoingScreen()) end, { size = 40 })
        y = y + bh + dp(40)
        -- incoming challenges
        local list = {}
        for _, c in pairs(session.challenges) do list[#list + 1] = c end
        table.sort(list, function(a, b) return (a.id or "") < (b.id or "") end)
        if #list > 0 then
            y = y + section(ctx, x, y, "INCOMING CHALLENGES")
            for i = 1, math.min(#list, 2) do
                local c = list[i]
                local who = (c.challenger or {}).name or "?"
                local rating = (c.challenger or {}).rating
                local tc = c.timeControl or {}
                local tcs = tc.show or (tc.type == "correspondence" and ((tc.daysPerTurn or "?") .. " days")) or tc.type or ""
                local variant = (c.variant or {}).key or "standard"
                local line = string.format("%s%s · %s · %s%s", who, rating and (" (" .. rating .. ")") or "",
                    tcs, c.rated and "rated" or "casual", variant ~= "standard" and (" · " .. variant) or "")
                local lf = ui.font("sans", 30)
                lf:draw_top(s, x, y, lf:ellipsize(line, w), BLACK)
                y = y + lf.height + dp(12)
                local supported = (variant == "standard" or variant == "fromPosition")
                ctx:button_row(x, y, w, dp(96), {
                    { supported and "Accept" or "Unsupported", supported and function()
                        ui.busy("Accepting…")
                        local ok, err = api.accept(c.id)
                        session.challenges[c.id] = nil
                        if not ok then ui.alert("Couldn't accept", err) end
                    end or nil, { style = supported and "solid" or "disabled", size = 32 } },
                    { "Decline", function()
                        ui.busy("Declining…")
                        api.decline(c.id, supported and "generic" or "variant")
                        session.challenges[c.id] = nil
                    end, { size = 32 } },
                })
                y = y + dp(96) + dp(24)
            end
        end
        -- footer
        local ff = ui.font("sans", 26)
        local sign = "Sign out"
        local sx = x + w - ff:width(sign)
        ff:draw_top(s, sx, ctx.H - dp(70), sign, DARK)
        ctx:hit(sx - dp(30), ctx.H - dp(100), ff:width(sign) + dp(60), dp(100), function()
            ui.confirm("Sign out?", "The saved token will be removed from this Kindle.", "Sign out", function()
                api.forget_token()
                session.account = nil
                session.stop()
                ui.replace(TokenScreen(function() ui.replace(Lobby()) end))
            end)
        end)
    end
    return scr
end

-- Game screen -----------------------------------------------------------------------------------
local STATUS_TEXT = {
    mate = "Checkmate", resign = "Resignation", stalemate = "Stalemate", timeout = "Opponent left",
    draw = "Draw", outoftime = "Time out", cheat = "Cheat detected", noStart = "Game didn't start",
    aborted = "Game aborted", variantEnd = "Variant ending", unknownFinish = "Finished",
}

GameScreen = function(id, info)
    local scr = {
        id = id, info = info or {}, pos = chess.from_fen(), full = nil, state = nil,
        my_color = nil, received_at = sys.now(), sending = false,
    }
    scr.board = boardlib.new({
        can_move = function() return scr:my_turn() and not scr.sending end,
        on_move = function(m) scr:play(m) end,
    })

    function scr:my_turn()
        if not self.state or self.state.status ~= "started" and self.state.status ~= "created" then return false end
        return self.my_color ~= nil and self.pos.turn == self.my_color
    end

    function scr:rebuild()
        local moves = self.state and self.state.moves or ""
        local fen = self.full and self.full.initialFen or "startpos"
        local p, bad = chess.replay(fen, moves)
        if bad then ui.log("lichess: could not apply move " .. bad) end
        self.pos = p
        local h = p.history[#p.history]
        self.board.last = h and { from = h.from, to = h.to } or nil
        self.board:clear_selection()
    end

    function scr:apply_state(st)
        self.state = st
        self.received_at = sys.now()
        self.sending = false
        self:rebuild()
        if st.status ~= "started" and st.status ~= "created" then
            self.over = true
            kindle.prevent_screensaver(false)
        end
        ui.redraw()
    end

    function scr:on_event(ev)
        if ev.type == "gameFull" then
            self.full = ev
            local me = session.account and session.account.id
            if ev.white and ev.white.id == me then self.my_color = 1
            elseif ev.black and ev.black.id == me then self.my_color = -1 end
            if self.info.color then self.my_color = self.info.color == "white" and 1 or -1 end
            self.board.flipped = self.my_color == -1
            self:apply_state(ev.state or {})
        elseif ev.type == "gameState" then
            self:apply_state(ev)
        elseif ev.type == "opponentGone" then
            self.gone = ev
            ui.redraw()
        elseif ev.type == "chatLine" then
            if ev.username ~= "lichess" or ev.room == "player" then
                self.chat = (ev.username or "?") .. ": " .. (ev.text or "")
                ui.redraw()
            end
        end
    end

    function scr:connect()
        if self.stream and not self.stream.closed then return end
        local st, err = api.game_stream(self.id, function(ev) self:on_event(ev) end, function(reason)
            self.stream = nil
            if not self.over and self.visible then
                ui.after(3000, function() if self.visible and not self.over then self:connect() end end)
            end
            ui.redraw()
        end)
        if not st then
            self.err = err
            ui.toast("Game stream: " .. tostring(err))
            ui.after(8000, function() if self.visible and not self.over then self:connect() end end)
            return
        end
        self.err = nil
        self.stream = st
        ui.add_stream(st)
    end

    function scr:enter()
        self.visible = true
        ui.busy("Loading game…")
        self:connect()
        kindle.prevent_screensaver(true)
        self.tick_timer = ui.every(1000, function()
            if not self.over and self.state and self:clocks_running() then ui.redraw_quiet() end
        end, self)
    end
    function scr:resume() self.visible = true; self:connect() end
    function scr:pause() end
    function scr:leave()
        self.visible = false
        ui.cancel_owner(self)
        if self.stream then self.stream:close("leave") end
        session.open_games[self.id] = nil
        kindle.prevent_screensaver(false)
    end
    function scr:on_wake()
        if self.stream then self.stream:close("sleep") end
        self.stream = nil
        ui.after(1500, function() if self.visible then self:connect() end end)
    end
    function scr:refresh_soon()
        ui.after(1000, function() if self.visible and not self.stream then self:connect() end end)
    end

    function scr:clocks_running()
        local st = self.state
        if not st or st.status ~= "started" then return false end
        if self.full and self.full.speed == "correspondence" then return false end
        -- Lichess starts the clock after each side's first move
        return #self.pos.history >= 2
    end

    function scr:clock_ms(color)
        local st = self.state
        if not st then return nil end
        local ms = color == 1 and st.wtime or st.btime
        if ms and self:clocks_running() and self.pos.turn == color then
            ms = ms - (sys.now() - self.received_at)
        end
        return ms
    end

    function scr:play(m)
        local uci = chess.uci(m)
        -- show the move immediately
        self.pos:play(m)
        self.board.last = { from = m.from, to = m.to }
        self.sending = true
        ui.render_now()
        local ok, err = api.move(self.id, uci)
        self.sending = false
        if not ok then
            ui.toast("Move rejected: " .. tostring(err))
            self:rebuild()
        end
        ui.redraw()
    end

    local function player_bar(ctx, x, y, w, h, color, info_p)
        local s = ctx.s
        info_p = info_p or {}
        local name = info_p.name or info_p.id or (info_p.aiLevel and ("Stockfish level " .. info_p.aiLevel)) or "?"
        if info_p.title then name = info_p.title .. " " .. name end
        local rating = info_p.rating and (" " .. info_p.rating .. (info_p.provisional and "?" or "")) or ""
        local nf = ui.font("bold", 34)
        local rf = ui.font("sans", 30)
        boardlib.draw_piece(s, chess.KING * color, x, y + (h - dp(64)) / 2, dp(64))
        local tx = x + dp(80)
        nf:draw_top(s, tx, y + (h - nf.height) / 2, nf:ellipsize(name, w - dp(520)), BLACK)
        local nw = math.min(nf:width(name), w - dp(520))
        rf:draw_top(s, tx + nw, y + (h - nf.height) / 2 + dp(4), rating, DARK)
        -- clock
        local ms = scr:clock_ms(color)
        local corr = scr.full and scr.full.speed == "correspondence"
        local clock_txt = corr and "" or fmt_clock(ms)
        if clock_txt ~= "" then
            local cf = ui.font("bold", 44)
            local cw = dp(250)
            local cx = x + w - cw
            local running = scr:clocks_running() and scr.pos.turn == color
            if running then
                s:fill_round_rect(cx, y + dp(6), cw, h - dp(12), ui.R, BLACK)
                cf:draw_center(s, cx, y + dp(6), cw, h - dp(12), clock_txt, WHITE)
            else
                s:round_rect(cx, y + dp(6), cw, h - dp(12), ui.R, BLACK, ui.BORDER)
                cf:draw_center(s, cx, y + dp(6), cw, h - dp(12), clock_txt, BLACK)
            end
        end
    end

    function scr:render(ctx)
        local s = ctx.s
        local full = self.full or {}
        local opp_color = -(self.my_color or 1)
        local opp = (opp_color == 1) and full.white or full.black
        local me = (opp_color == 1) and full.black or full.white
        local title = (full.speed and (full.speed:sub(1, 1):upper() .. full.speed:sub(2)) or "Game")
            .. (full.rated and " · rated" or (full.rated == false and " · casual" or ""))
        local top = ctx:header(title, { right = { "☰", function() self:menu() end, size = 44 } })
        local W = ctx.W
        local bar_h = dp(96)
        local bsize = math.min(W - dp(48), ctx.H - top - 2 * bar_h - dp(250))
        bsize = math.floor(bsize / 8) * 8
        local bx = math.floor((W - bsize) / 2)
        local y = top + dp(8)
        local bottom_color = self.board.flipped and -1 or 1
        local top_color = -bottom_color
        local function pinfo(color) return (color == 1) and full.white or full.black end
        player_bar(ctx, bx, y, bsize, bar_h, top_color, pinfo(top_color))
        y = y + bar_h + dp(6)
        self.board:draw(ctx, self.pos, bx, y, bsize)
        y = y + bsize + dp(10)
        player_bar(ctx, bx, y, bsize, bar_h, bottom_color, pinfo(bottom_color))
        y = y + bar_h + dp(10)
        -- status line
        local st = self.state or {}
        local status
        local sf = ui.font("bold", 34)
        if not self.state then
            status = self.err and ("Connecting… " .. self.err) or "Connecting…"
        elseif self.over then
            local who = st.winner and (st.winner == "white" and 1 or -1) or nil
            local res
            if who then res = (who == self.my_color) and "You won" or "You lost" else res = "Game over" end
            status = res .. " · " .. (STATUS_TEXT[st.status] or st.status or "")
        elseif self.sending then
            status = "Sending move…"
        elseif self:my_turn() then
            status = self.pos:in_check() and "Your move — check!" or "Your move"
        else
            status = "Waiting for opponent…"
        end
        local hist = self.pos.history
        local moves_txt = ""
        if #hist > 0 then
            local parts = {}
            local start = math.max(1, #hist - 3)
            if start % 2 == 0 then start = start - 1 end
            for i = start, #hist do
                if i % 2 == 1 then parts[#parts + 1] = math.floor((i + 1) / 2) .. "." end
                parts[#parts + 1] = hist[i].san
            end
            moves_txt = table.concat(parts, " ")
        end
        sf:draw_top(s, bx, y, sf:ellipsize(status, bsize), BLACK)
        local mf = ui.font("sans", 30)
        mf:draw_top(s, bx, y + sf.height + dp(8), mf:ellipsize(moves_txt, bsize), DARK)
        y = y + sf.height + mf.height + dp(26)
        -- offers / actions row
        local my = self.my_color == 1 and "w" or "b"
        local their = self.my_color == 1 and "b" or "w"
        local items = nil
        if not self.over and st[their .. "draw"] then
            items = {
                { "Accept draw", function() ui.busy("…"); api.draw(self.id, true) end, { style = "solid", size = 32 } },
                { "Decline", function() ui.busy("…"); api.draw(self.id, false); st[their .. "draw"] = nil end, { size = 32 } },
            }
        elseif not self.over and st[their .. "takeback"] then
            items = {
                { "Allow takeback", function() ui.busy("…"); api.takeback(self.id, true) end, { style = "solid", size = 32 } },
                { "Decline", function() ui.busy("…"); api.takeback(self.id, false); st[their .. "takeback"] = nil end, { size = 32 } },
            }
        elseif not self.over and self.gone and self.gone.gone and self.gone.claimWinInSeconds == 0 then
            items = {
                { "Claim victory", function() ui.busy("…"); api.claim_victory(self.id) end, { style = "solid", size = 32 } },
            }
        elseif self.over then
            items = {
                { "Back to lobby", function() ui.pop(self) end, { style = "solid", size = 32 } },
            }
        else
            items = {
                { "Flip", function() self.board.flipped = not self.board.flipped; ui.redraw() end, { size = 32 } },
                { st[my .. "draw"] and "Draw offered" or "Offer draw", not st[my .. "draw"] and function()
                    ui.confirm("Offer a draw?", nil, "Offer draw", function() ui.busy("…"); api.draw(self.id, true) end)
                end or nil, { size = 32, style = st[my .. "draw"] and "disabled" or nil } },
                { #hist < 2 and "Abort" or "Resign", function()
                    if #hist < 2 then
                        ui.confirm("Abort this game?", nil, "Abort", function() ui.busy("…"); api.abort(self.id) end)
                    else
                        ui.confirm("Resign?", "This ends the game as a loss.", "Resign", function() ui.busy("…"); api.resign(self.id) end)
                    end
                end, { size = 32 } },
            }
        end
        local rh = math.min(dp(100), ctx.H - y - dp(16))
        if rh > dp(60) then ctx:button_row(bx, y, bsize, rh, items) end
        if self.chat then
            -- small chat line overlay at top of the actions when present
        end
    end

    function scr:menu()
        local opts = {
            { title = "Flip board" },
            { title = "Propose takeback" },
            { title = "Send a chat message" },
            { title = "Copy game link", subtitle = "lichess.org/" .. self.id },
            { title = "Back to lobby" },
        }
        if self.chat then table.insert(opts, 3, { title = "Last chat", subtitle = self.chat }) end
        ui.choose("Game", opts, function(i, it)
            if it.title == "Flip board" then self.board.flipped = not self.board.flipped
            elseif it.title == "Propose takeback" then ui.busy("…"); local ok, err = api.takeback(self.id, true); if not ok then ui.toast(err) end
            elseif it.title == "Send a chat message" then
                keyboard({ title = "Chat", on_done = function(t) if t ~= "" then api.chat(self.id, t) end end })
            elseif it.title == "Copy game link" then ui.toast("lichess.org/" .. self.id)
            elseif it.title == "Back to lobby" then ui.pop(self) end
            ui.redraw()
        end)
    end

    return scr
end

-- Entry ------------------------------------------------------------------------------------------
function M.new()
    local root = { }
    function root:enter()
        load_prefs()
        if api.load_token() then
            ui.replace(Lobby())
        else
            ui.replace(TokenScreen(function() ui.replace(Lobby()) end))
        end
    end
    function root:render(ctx) ctx:header("Lichess") end
    return root
end

M.Lobby, M.TokenScreen, M.GameScreen = Lobby, TokenScreen, GameScreen
return M
