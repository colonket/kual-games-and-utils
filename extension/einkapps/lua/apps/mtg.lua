-- Magic: The Gathering life counter for 2–6 players.
-- Panels are rotated to face each player around the table. Tap the left
-- half of a panel for −1, the right half for +1; hold for −5/+5. Tap the
-- strip at the bottom of a panel for poison, commander damage and more.
local ui = require("core.ui")
local gfx = require("core.gfx")
local font = require("core.font")
local sys = require("core.sys")
local store = require("core.store")
local kindle = require("core.kindle")
local keyboard = require("core.keyboard")

local dp = ui.dp
local BLACK, WHITE, DARK, GRAY, PALE, LIGHT, MID = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.GRAY, gfx.PALE, gfx.LIGHT, gfx.MID

local M = {}

local NAMES = { "Player 1", "Player 2", "Player 3", "Player 4", "Player 5", "Player 6" }

local game = nil
local function save() store.save("mtg", game) end

local function default_rotations(n)
    if n == 2 then return { 180, 0 } end
    if n == 3 then return { 180, 90, 270 } end
    if n == 4 then return { 90, 90, 270, 270 } end
    if n == 5 then return { 180, 90, 90, 270, 270 } end
    return { 90, 90, 90, 270, 270, 270 }
end

local function new_game(n, start, opts)
    opts = opts or {}
    local rots = default_rotations(n)
    local players = {}
    local prev = game and game.players or {}
    for i = 1, n do
        players[i] = {
            name = (prev[i] and prev[i].name) or NAMES[i],
            life = start, poison = 0, energy = 0, exp = 0, tax = 0, cmd = {},
            rot = (prev[i] and #prev == n and prev[i].rot) or rots[i],
        }
        for j = 1, n do players[i].cmd[j] = 0 end
    end
    game = {
        players = players, start = start, n = n,
        commander = opts.commander, poison = opts.poison ~= false,
        cmd_affects_life = opts.cmd_affects_life ~= false,
        history = {}, started = os.time(),
    }
    save()
end

local function is_out(p)
    if p.life <= 0 then return "life" end
    if p.poison >= 10 then return "poison" end
    for _, d in pairs(p.cmd) do if d >= 21 then return "commander" end end
    return nil
end

-- Life change bookkeeping: merges rapid taps into one history entry and
-- shows a running "+3" next to the total for a few seconds.
local recent = {}   -- [player] = {delta=, at=}
local function change_life(i, delta, why)
    local p = game.players[i]
    p.life = p.life + delta
    local now = sys.now()
    local r = recent[i]
    if r and now - r.at < 3500 then
        r.delta, r.at = r.delta + delta, now
    else
        recent[i] = { delta = delta, at = now }
    end
    local h = game.history
    local last = h[#h]
    if last and last.p == i and not why and now - (last.ms or 0) < 3500 and not last.why then
        last.delta = last.delta + delta
        last.to = p.life
        last.ms = now
    else
        h[#h + 1] = { p = i, delta = delta, to = p.life, t = os.time(), ms = now, why = why }
        if #h > 300 then table.remove(h, 1) end
    end
    save()
end

-- Layout -------------------------------------------------------------------------------
local function layout(W, H, n)
    local g = dp(10)
    local rects = {}
    local junction
    local function col(x, y, w, h, count)
        local ph = (h - g * (count - 1)) / count
        local out = {}
        for k = 1, count do
            out[k] = { x, math.floor(y + (k - 1) * (ph + g)), w, math.floor(ph) }
        end
        return out
    end
    local hw = math.floor((W - g) / 2)
    if n == 2 then
        local h2 = math.floor((H - g) / 2)
        rects = { { 0, 0, W, h2 }, { 0, h2 + g, W, H - h2 - g } }
        junction = { W * 0.2, h2 + g / 2 }
    elseif n == 3 or n == 5 then
        local th = math.floor(H * (n == 3 and 0.36 or 0.30))
        rects[1] = { 0, 0, W, th }
        local per = (n == 3) and 1 or 2
        for _, r in ipairs(col(0, th + g, hw, H - th - g, per)) do rects[#rects + 1] = r end
        for _, r in ipairs(col(hw + g, th + g, W - hw - g, H - th - g, per)) do rects[#rects + 1] = r end
        junction = { W * 0.2, th + g / 2 }
    else
        local per = n / 2
        for _, r in ipairs(col(0, 0, hw, H, per)) do rects[#rects + 1] = r end
        for _, r in ipairs(col(hw + g, 0, W - hw - g, H, per)) do rects[#rects + 1] = r end
        -- on the divider, at a row boundary (away from the names mid-panel)
        junction = { W / 2, rects[1][2] + rects[1][4] + g / 2 }
    end
    return rects, junction
end

-- Convert a screen point to panel-local coordinates.
local function to_local(rect, rot, X, Y)
    local sx, sy, sw, sh = rect[1], rect[2], rect[3], rect[4]
    local x, y = X - sx, Y - sy
    if rot == 0 then return x, y, sw, sh end
    if rot == 180 then return sw - 1 - x, sh - 1 - y, sw, sh end
    if rot == 90 then return y, sw - 1 - x, sh, sw end
    return sh - 1 - y, x, sh, sw    -- 270
end

-- Panel rendering ------------------------------------------------------------------------
local surfaces = {}
local function panel_surface(w, h)
    local key = w .. "x" .. h
    local s = surfaces[key]
    if not s then
        s = gfx.Surface.new(w, h, WHITE)
        surfaces[key] = s
    end
    s:fill(WHITE)
    return s
end

local function badge_text(p, i)
    local parts = {}
    if game.poison and p.poison > 0 then parts[#parts + 1] = "☠ " .. p.poison end
    if game.commander then
        local maxd, total = 0, 0
        for j, d in pairs(p.cmd) do if j ~= i then total = total + d; if d > maxd then maxd = d end end end
        if total > 0 then parts[#parts + 1] = "⚔ " .. maxd end
        if p.tax > 0 then parts[#parts + 1] = "tax " .. p.tax end
    end
    if p.energy > 0 then parts[#parts + 1] = "⚡ " .. p.energy end
    if p.exp > 0 then parts[#parts + 1] = "✦ " .. p.exp end
    return table.concat(parts, "   ")
end

local function draw_panel(s, p, i, w, h)
    local out = is_out(p)
    local fg, bg = BLACK, WHITE
    if out then fg, bg = WHITE, BLACK end
    local r = dp(28)
    s:fill_round_rect(0, 0, w, h, r, bg)
    if not out then s:round_rect(0, 0, w, h, r, BLACK, dp(5)) end
    local strip = math.max(dp(84), math.floor(h * 0.17))
    -- name (centered, so panel corners near the menu button stay clear)
    local nf = ui.font("bold", math.min(36, h / 9 / ui.rt.S))
    local name = nf:ellipsize(p.name, w * 0.6)
    local nw = nf:width(name)
    nf:draw_top(s, (w - nw) / 2, dp(20), name, fg)
    -- life total
    local life = tostring(p.life)
    local avail_h = h - strip - nf.height - dp(30)
    local lf = font.fit("num", life, w * 0.62, avail_h * 0.95)
    local top = nf.height + dp(20)
    lf:draw_center_ink(s, 0, top, w, avail_h, life, fg)
    -- minus / plus hints
    local hf = ui.font("bold", math.min(72, h / 6 / ui.rt.S))
    local hint = out and MID or LIGHT
    hf:draw_center_ink(s, 0, top, w * 0.2, avail_h, "−", hint)
    hf:draw_center_ink(s, w * 0.8, top, w * 0.2, avail_h, "+", hint)
    -- recent change, as a pill next to the name
    local rc = recent[i]
    if rc and sys.now() - rc.at < 3500 and rc.delta ~= 0 then
        local df = ui.font("bold", math.min(34, h / 9 / ui.rt.S))
        local txt = (rc.delta > 0 and "+" or "−") .. math.abs(rc.delta)
        local pw = df:width(txt) + dp(28)
        local px = (w + nw) / 2 + dp(16)
        s:fill_round_rect(px, dp(14), pw, nf.height + dp(12), dp(14), fg)
        df:draw_center(s, px, dp(14), pw, nf.height + dp(12), txt, bg)
    end
    -- bottom strip
    local sy = h - strip
    s:fill_rect(dp(24), sy, w - dp(48), dp(3), out and MID or LIGHT)
    local bf = ui.font("sans", math.min(34, strip * 0.42 / ui.rt.S))
    local bt = badge_text(p, i)
    if out then
        bt = "☠ OUT" .. (out == "poison" and " (poison)" or out == "commander" and " (commander)" or "") .. (bt ~= "" and ("   " .. bt) or "")
    end
    if bt == "" then bt = "⋯  counters" end
    bf:draw_center(s, dp(20), sy, w - dp(40), strip, bf:ellipsize(bt, w - dp(40)), out and WHITE or DARK)
    return strip
end

-- Game screen -------------------------------------------------------------------------------
local PlayerScreen, MenuScreen, SetupScreen

local function GameScreen()
    local scr = {}
    function scr:enter()
        kindle.prevent_screensaver(true)
        self.timer = ui.every(1000, function()
            -- let the "+3" indicators fade
            local now = sys.now()
            for i, r in pairs(recent) do
                if now - r.at >= 3500 then
                    recent[i] = nil
                    ui.redraw_quiet()
                end
            end
        end, self)
    end
    function scr:leave()
        ui.cancel_owner(self)
        kindle.prevent_screensaver(false)
    end
    function scr:resume() kindle.prevent_screensaver(true) end

    function scr:render(ctx)
        local s = ctx.s
        local W, H = ctx.W, ctx.H
        local rects, junction = layout(W, H, game.n)
        self.rects = rects
        for i, p in ipairs(game.players) do
            local r = rects[i]
            local rot = p.rot or 0
            local lw, lh = r[3], r[4]
            if rot == 90 or rot == 270 then lw, lh = r[4], r[3] end
            local ps = panel_surface(lw, lh)
            local strip = draw_panel(ps, p, i, lw, lh)
            s:blit_rotated(ps, r[1], r[2], rot)
            local idx = i
            ctx:hit(r[1], r[2], r[3], r[4], function(ev) self:panel_tap(idx, ev, 1, strip) end,
                function(ev) self:panel_tap(idx, ev, 5, strip) end)
        end
        -- center menu button
        local mr = dp(62)
        local cx, cy = junction[1], junction[2]
        s:fill_circle(cx, cy, mr + dp(8), WHITE)
        s:fill_circle(cx, cy, mr, BLACK)
        ui.font("bold", 48):draw_center_ink(s, cx - mr, cy - mr, 2 * mr, 2 * mr, "☰", WHITE)
        ctx:hit(cx - mr - dp(10), cy - mr - dp(10), 2 * mr + dp(20), 2 * mr + dp(20), function() ui.push(MenuScreen()) end)
    end

    function scr:panel_tap(i, ev, amount, strip)
        local p = game.players[i]
        local lx, ly, lw, lh = to_local(self.rects[i], p.rot or 0, ev.x, ev.y)
        if ly >= lh - strip then
            ui.push(PlayerScreen(i))
            return
        end
        if lx < lw / 2 then change_life(i, -amount) else change_life(i, amount) end
        ui.redraw()
    end
    return scr
end

-- Per-player detail ------------------------------------------------------------------------------
PlayerScreen = function(i)
    local scr = {}
    local function bump(field, d, min)
        local p = game.players[i]
        p[field] = math.max(min or 0, p[field] + d)
        save()
        ui.redraw()
    end
    function scr:render(ctx)
        local p = game.players[i]
        local W = ctx.W
        local top = ctx:header(p.name, { right = { { "Rename", function()
            keyboard({ title = "Player name", text = p.name, max_len = 24, on_done = function(t)
                if t ~= "" then p.name = t; save() end
            end })
        end, size = 30 } } })
        local x, w = ui.M, W - 2 * ui.M
        local y = top + dp(20)
        -- life
        local lf = ui.font("num", 140)
        lf:draw_center_ink(ctx.s, x, y, w, dp(170), tostring(p.life), BLACK)
        y = y + dp(190)
        ctx:button_row(x, y, w, dp(100), {
            { "−10", function() change_life(i, -10) end }, { "−5", function() change_life(i, -5) end },
            { "−1", function() change_life(i, -1) end }, { "+1", function() change_life(i, 1) end },
            { "+5", function() change_life(i, 5) end }, { "+10", function() change_life(i, 10) end },
        }, { gap = dp(12), size = 34 })
        y = y + dp(130)
        local rowh = dp(96)
        if game.poison then
            ctx:stepper(x, y, w, rowh, "☠ Poison", p.poison, function() bump("poison", -1) end, function() bump("poison", 1) end)
            y = y + rowh + dp(16)
        end
        ctx:stepper(x, y, w, rowh, "⚡ Energy", p.energy, function() bump("energy", -1) end, function() bump("energy", 1) end)
        y = y + rowh + dp(16)
        ctx:stepper(x, y, w, rowh, "✦ Experience", p.exp, function() bump("exp", -1) end, function() bump("exp", 1) end)
        y = y + rowh + dp(16)
        if game.commander then
            ctx:stepper(x, y, w, rowh, "Commander tax", p.tax, function() bump("tax", -2) end, function() bump("tax", 2) end)
            y = y + rowh + dp(26)
            local sf = ui.font("bold", 30)
            sf:draw_top(ctx.s, x, y, "COMMANDER DAMAGE TAKEN", DARK)
            y = y + sf.height + dp(12)
            for j, q in ipairs(game.players) do
                if j ~= i then
                    local jj = j
                    ctx:stepper(x, y, w, rowh, "from " .. q.name, p.cmd[j] or 0,
                        function()
                            if (p.cmd[jj] or 0) > 0 then
                                p.cmd[jj] = p.cmd[jj] - 1
                                if game.cmd_affects_life then change_life(i, 1, "cmd") else save() end
                                ui.redraw()
                            end
                        end,
                        function()
                            p.cmd[jj] = (p.cmd[jj] or 0) + 1
                            if game.cmd_affects_life then change_life(i, -1, "cmd") else save() end
                            ui.redraw()
                        end)
                    y = y + rowh + dp(10)
                end
            end
        end
        local by = ctx.H - ui.BTN_H - dp(30)
        if y < by - dp(10) then
            ctx:button_row(x, by, w, ui.BTN_H, {
                { "Rotate panel ↻", function()
                    p.rot = ((p.rot or 0) + 90) % 360
                    save()
                    ui.toast("Panel rotated to " .. p.rot .. "°")
                end },
                { "Done", function() ui.pop(scr) end, { style = "solid" } },
            })
        end
    end
    return scr
end

-- Tools: dice, coin, first player -------------------------------------------------------------------
local function ToolsScreen()
    local scr = { result = nil, label = nil }
    local function show(label, result) scr.label, scr.result = label, result; ui.redraw() end
    function scr:render(ctx)
        local top = ctx:header("Dice & coin")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(40)
        local box = dp(560)
        ctx.s:round_rect(x, y, w, box, ui.R, BLACK, ui.BORDER)
        if self.result then
            local lf = ui.font("sans", 36)
            lf:draw_center(ctx.s, x, y + dp(30), w, dp(60), self.label, DARK)
            local rf = font.fit("num", self.result, w - dp(80), box - dp(160))
            if not tostring(self.result):match("^%d+$") then rf = ui.font("bold", 72) end
            local f2 = rf
            if f2:width(self.result) > w - dp(60) then f2 = ui.font("bold", 56) end
            f2:draw_center_ink(ctx.s, x, y + dp(100), w, box - dp(140), self.result, BLACK)
        else
            ui.font("sans", 34):draw_center(ctx.s, x, y, w, box, "Pick something to roll", DARK)
        end
        y = y + box + dp(40)
        local rows = {
            { { "D20", function() show("d20", tostring(math.random(20))) end },
              { "D6", function() show("d6", tostring(math.random(6))) end },
              { "2 × D6", function() local a, b = math.random(6), math.random(6); show("2d6: " .. a .. " + " .. b, tostring(a + b)) end } },
            { { "Coin flip", function() show("coin", math.random(2) == 1 and "Heads" or "Tails") end },
              { "First player", function()
                  local k = math.random(#game.players)
                  show("goes first", game.players[k].name)
              end },
              { "Planar die", function()
                  local r = math.random(6)
                  show("planar die", r == 1 and "Planeswalk" or (r == 6 and "Chaos" or "Blank"))
              end } },
        }
        for _, row in ipairs(rows) do
            ctx:button_row(x, y, w, dp(120), row, { size = 34 })
            y = y + dp(140)
        end
    end
    return scr
end

local function HistoryScreen()
    local scr = { state = { page = 1 } }
    function scr:render(ctx)
        local top = ctx:header("Life history")
        local items = {}
        for k = #game.history, 1, -1 do
            local h = game.history[k]
            local p = game.players[h.p]
            if p then
                items[#items + 1] = {
                    title = string.format("%s  %s%d  →  %d", p.name, h.delta >= 0 and "+" or "−", math.abs(h.delta), h.to),
                    right = os.date("%H:%M", h.t) .. (h.why == "cmd" and "  ⚔" or ""),
                }
            end
        end
        ctx:list(ui.M, top + dp(10), ctx.W - 2 * ui.M, ctx.H - top - dp(30), items, self.state,
            { row_h = dp(100), empty = "No life changes yet." })
    end
    return scr
end

MenuScreen = function()
    local scr = { overlay = true, dismiss_outside = true }
    function scr:render(ctx)
        local s = ctx.s
        local w = ctx.W - dp(160)
        local items = {
            { "Dice, coin & first player", function() ui.pop(scr); ui.push(ToolsScreen()) end },
            { "Life history", function() ui.pop(scr); ui.push(HistoryScreen()) end },
            { "Restart game", function()
                ui.pop(scr)
                ui.confirm("Restart?", "Everyone goes back to " .. game.start .. " life.", "Restart", function()
                    new_game(game.n, game.start, game)
                    recent = {}
                    ui.redraw(true)
                end)
            end },
            { "New game setup", function() ui.pop(scr); ui.replace(SetupScreen()) end },
            { "Exit", function() ui.pop(scr); ui.back_to_root() end },
        }
        local bh, gap = dp(118), dp(18)
        local h = #items * (bh + gap) + dp(140)
        local x, y = dp(80), math.floor((ctx.H - h) / 2)
        s:fill_round_rect(x - dp(8), y - dp(8), w + dp(16), h + dp(16), ui.R, WHITE)
        s:fill_round_rect(x, y, w, h, ui.R, WHITE)
        s:round_rect(x, y, w, h, ui.R, BLACK, dp(5))
        ui.font("bold", 40):draw_center(s, x, y + dp(20), w, dp(80), "Game menu", BLACK)
        local by = y + dp(110)
        for k, it in ipairs(items) do
            ctx:button(x + dp(40), by, w - dp(80), bh, it[1], it[2], { style = (k == #items) and "solid" or "outline", size = 34 })
            by = by + bh + gap
        end
        -- swallow taps inside the box
        ctx:hit(x, y, w, h, function() end)
        -- re-register buttons above the swallow region (hits are searched last-first)
        by = y + dp(110)
        for _, it in ipairs(items) do
            ctx:hit(x + dp(40), by, w - dp(80), bh, it[2], nil, { label = it[1] })
            by = by + bh + gap
        end
    end
    return scr
end

-- Setup ---------------------------------------------------------------------------------------------
SetupScreen = function()
    local cfg = store.load("mtg_setup", { n = 4, start = 40, commander = true, poison = true, cmd_affects_life = true })
    local scr = {}
    local LIVES = { 20, 25, 30, 40 }
    function scr:render(ctx)
        local x, w = ui.M, ctx.W - 2 * ui.M
        local top = ctx:header("Life counter", { back = function() ui.back_to_root() end })
        local y = top + dp(36)
        local sf = ui.font("bold", 30)
        sf:draw_top(ctx.s, x, y, "PLAYERS", DARK); y = y + sf.height + dp(14)
        ctx:segmented(x, y, w, dp(110), { "2", "3", "4", "5", "6" }, cfg.n - 1, function(k)
            cfg.n = k + 1
            if cfg.n == 2 and cfg.start == 40 then cfg.start = 20 end
            if cfg.n >= 3 and cfg.start == 20 then cfg.start = 40; cfg.commander = true end
            ui.redraw()
        end, { size = 40 })
        y = y + dp(150)
        sf:draw_top(ctx.s, x, y, "STARTING LIFE", DARK); y = y + sf.height + dp(14)
        local sel = 1
        for k, v in ipairs(LIVES) do if v == cfg.start then sel = k end end
        ctx:segmented(x, y, w, dp(110), { "20", "25", "30", "40" }, sel, function(k) cfg.start = LIVES[k]; ui.redraw() end, { size = 40 })
        y = y + dp(160)
        ctx:toggle(x, y, w, dp(100), "Commander damage & tax", cfg.commander, function(v) cfg.commander = v; ui.redraw() end)
        y = y + dp(110)
        ctx:toggle(x, y, w, dp(100), "Poison counters", cfg.poison, function(v) cfg.poison = v; ui.redraw() end)
        y = y + dp(110)
        if cfg.commander then
            ctx:toggle(x, y, w, dp(100), "Commander damage also lowers life", cfg.cmd_affects_life,
                function(v) cfg.cmd_affects_life = v; ui.redraw() end)
            y = y + dp(110)
        end
        y = y + dp(30)
        ctx:paragraph(x, y, w, "Tap the left or right half of a panel for −1 / +1, hold for −5 / +5. "
            .. "Tap the bottom strip of a panel for poison, commander damage, energy and to rename or rotate. "
            .. "The ☰ button opens dice, history and restart.", { font = ui.font("sans", 28), color = DARK })
        local by = ctx.H - ui.BTN_H - dp(40)
        local items = {}
        if game and game.players and #game.players > 0 then
            items[#items + 1] = { "Continue game", function() ui.replace(GameScreen()) end }
        end
        items[#items + 1] = { "Start", function()
            store.save("mtg_setup", cfg)
            new_game(cfg.n, cfg.start, cfg)
            recent = {}
            ui.replace(GameScreen())
        end, { style = "solid" } }
        ctx:button_row(x, by, w, ui.BTN_H, items)
    end
    return scr
end

function M.new()
    game = store.load("mtg")
    if not game.players or #game.players == 0 then game = nil end
    local root = {}
    function root:enter()
        if game then ui.replace(GameScreen()) else ui.replace(SetupScreen()) end
    end
    return root
end

-- exported for tests
M._layout, M._to_local = layout, to_local
return M
