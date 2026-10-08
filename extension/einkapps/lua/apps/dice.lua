-- Dice & 8-Ball (ported from CrossPoint Apps' DiceActivity): D6, spinning
-- arrow, D20, Magic 8-Ball, plus a coin flip.
local ui = require("core.ui")
local gfx = require("core.gfx")
local font = require("core.font")
local sys = require("core.sys")

local dp = ui.dp
local BLACK, WHITE, DARK, PALE, LIGHT = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.PALE, gfx.LIGHT

local M = {}

local RESPONSES = {
    "It is certain", "It is decidedly so", "Without a doubt", "Yes, definitely", "You may rely on it",
    "As I see it, yes", "Most likely", "Outlook good", "Yes", "Signs point to yes",
    "Reply hazy, try again", "Ask again later", "Better not tell you now", "Cannot predict now",
    "Concentrate and ask again", "Don't count on it", "My reply is no", "My sources say no",
    "Outlook not so good", "Very doubtful",
}

local MODES = { "D6", "Arrow", "D20", "8-Ball", "Coin" }

local PIPS = {
    [1] = { { 0.5, 0.5 } },
    [2] = { { 0.27, 0.27 }, { 0.73, 0.73 } },
    [3] = { { 0.27, 0.27 }, { 0.5, 0.5 }, { 0.73, 0.73 } },
    [4] = { { 0.27, 0.27 }, { 0.73, 0.27 }, { 0.27, 0.73 }, { 0.73, 0.73 } },
    [5] = { { 0.27, 0.27 }, { 0.73, 0.27 }, { 0.5, 0.5 }, { 0.27, 0.73 }, { 0.73, 0.73 } },
    [6] = { { 0.27, 0.25 }, { 0.73, 0.25 }, { 0.27, 0.5 }, { 0.73, 0.5 }, { 0.27, 0.75 }, { 0.73, 0.75 } },
}

local function draw_d6(s, x, y, size, v)
    s:fill_round_rect(x, y, size, size, size * 0.16, WHITE)
    s:round_rect(x, y, size, size, size * 0.16, BLACK, math.max(4, size * 0.04))
    for _, p in ipairs(PIPS[v]) do
        s:fill_circle(x + p[1] * size, y + p[2] * size, size * 0.085, BLACK)
    end
end

local function draw_arrow(s, cx, cy, r, angle)
    s:circle(cx, cy, r + dp(30), LIGHT, dp(4))
    local a = math.rad(angle)
    local ex, ey = cx + math.cos(a) * r, cy + math.sin(a) * r
    local tx, ty = cx - math.cos(a) * r * 0.55, cy - math.sin(a) * r * 0.55
    s:line(tx, ty, ex, ey, BLACK, dp(14))
    local hl = r * 0.28
    local left = { ex + math.cos(a + math.pi * 0.82) * hl, ey + math.sin(a + math.pi * 0.82) * hl }
    local right = { ex + math.cos(a - math.pi * 0.82) * hl, ey + math.sin(a - math.pi * 0.82) * hl }
    local tip = { ex + math.cos(a) * dp(10), ey + math.sin(a) * dp(10) }
    s:fill_polygon({ tip, left, right }, BLACK)
    s:fill_circle(cx, cy, dp(22), BLACK)
end

local function draw_d20(s, cx, cy, r, v)
    local px, py = {}, {}
    for k = 0, 5 do
        local a = math.rad(k * 60 - 90)
        px[k], py[k] = cx + math.cos(a) * r, cy + math.sin(a) * r
    end
    local poly = {}
    for k = 0, 5 do poly[#poly + 1] = { px[k], py[k] } end
    s:fill_polygon(poly, WHITE)
    for k = 0, 5 do s:line(px[k], py[k], px[(k + 1) % 6], py[(k + 1) % 6], BLACK, dp(6)) end
    -- inner triangle and facets
    local ix, iy = {}, {}
    for k = 0, 2 do
        local a = math.rad(k * 120 - 90 + 60)
        ix[k], iy[k] = cx + math.cos(a) * r * 0.62, cy + math.sin(a) * r * 0.62
    end
    -- flip so the inner triangle points up
    for k = 0, 2 do
        local a = math.rad(k * 120 - 90)
        ix[k], iy[k] = cx + math.cos(a) * r * 0.62, cy - math.sin(a) * r * 0.62 + r * 0.0
    end
    for k = 0, 2 do s:line(ix[k], iy[k], ix[(k + 1) % 3], iy[(k + 1) % 3], BLACK, dp(4)) end
    for k = 0, 5 do
        local nearest = 0
        local bd = math.huge
        for j = 0, 2 do
            local d = (px[k] - ix[j]) ^ 2 + (py[k] - iy[j]) ^ 2
            if d < bd then bd, nearest = d, j end
        end
        s:line(px[k], py[k], ix[nearest], iy[nearest], BLACK, dp(3))
    end
    local f = font.fit("num", tostring(v), r * 0.8, r * 0.55)
    f:draw_center_ink(s, cx - r, cy - r * 0.25, 2 * r, r * 0.6, tostring(v), BLACK)
end

local function draw_8ball(s, cx, cy, r, idx)
    s:fill_circle(cx, cy, r, BLACK)
    local ir = r * 0.58
    s:fill_circle(cx, cy, ir, WHITE)
    local f = ui.font("bold", 36)
    local lines = f:wrap(RESPONSES[idx], ir * 1.55)
    local lh = f.line_height
    local y0 = cy - #lines * lh / 2
    for k, l in ipairs(lines) do
        f:draw_top(s, cx - f:width(l) / 2, y0 + (k - 1) * lh, l, BLACK)
    end
end

local function draw_coin(s, cx, cy, r, heads)
    s:fill_circle(cx, cy, r, PALE)
    s:circle(cx, cy, r, BLACK, dp(8))
    s:circle(cx, cy, r * 0.84, DARK, dp(3))
    local f = font.fit("bold", heads and "HEADS" or "TAILS", r * 1.4, r * 0.5)
    f:draw_center_ink(s, cx - r, cy - r, 2 * r, 2 * r, heads and "HEADS" or "TAILS", BLACK)
end

function M.new()
    local scr = { mode = 1, count = 2, d6 = { 3, 5 }, angle = -60, d20 = 20, ball = 1, heads = true, rolls = 0 }
    math.randomseed(sys.now() % 2147483647)

    function scr:roll()
        local m = MODES[self.mode]
        if m == "D6" then
            self.d6 = {}
            for k = 1, self.count do self.d6[k] = math.random(6) end
        elseif m == "Arrow" then self.angle = math.random(0, 359)
        elseif m == "D20" then self.d20 = math.random(20)
        elseif m == "8-Ball" then self.ball = math.random(#RESPONSES)
        else self.heads = math.random(2) == 1 end
        self.rolls = self.rolls + 1
        ui.redraw(true)
    end

    function scr:on_swipe(ev)
        if ev.dir == "left" then self.mode = self.mode % #MODES + 1
        elseif ev.dir == "right" then self.mode = (self.mode - 2) % #MODES + 1 end
        ui.redraw()
    end

    function scr:render(ctx)
        local s = ctx.s
        local top = ctx:header("Dice & 8-Ball")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(26)
        ctx:segmented(x, y, w, dp(96), MODES, self.mode, function(i) self.mode = i; ui.redraw() end, { size = 32 })
        y = y + dp(126)
        local card_h = ctx.H - y - ui.BTN_H - dp(80)
        s:round_rect(x, y, w, card_h, dp(24), BLACK, ui.BORDER)
        local cx, cy = ctx.W / 2, y + card_h / 2
        local m = MODES[self.mode]
        if m == "D6" then
            local n = #self.d6
            local cols = (n <= 3) and n or math.ceil(n / 2)
            local rows = (n <= 3) and 1 or 2
            local size = math.min((w - dp(80)) / cols - dp(30), (card_h - dp(200)) / rows - dp(30), dp(300))
            local total = 0
            for k, v in ipairs(self.d6) do
                total = total + v
                local r, c = math.floor((k - 1) / cols), (k - 1) % cols
                local inrow = math.min(cols, n - r * cols)
                local rowx = cx - (inrow * (size + dp(30)) - dp(30)) / 2
                local dy = cy - (rows * (size + dp(30)) - dp(30)) / 2 - dp(40) + r * (size + dp(30))
                draw_d6(s, rowx + c * (size + dp(30)), dy, size, v)
            end
            if n > 1 then
                ui.font("bold", 44):draw_center(s, x, y + card_h - dp(170), w, dp(70), "Total " .. total, BLACK)
            end
            -- dice count
            local bw = dp(90)
            local by = y + card_h - dp(100)
            ctx:button(cx - bw - dp(110), by, bw, dp(80), "−", function()
                self.count = math.max(1, self.count - 1); self:roll()
            end, { size = 44 })
            ui.font("sans", 32):draw_center(s, cx - dp(110), by, dp(220), dp(80), self.count .. (self.count == 1 and " die" or " dice"), BLACK)
            ctx:button(cx + dp(110), by, bw, dp(80), "+", function()
                self.count = math.min(6, self.count + 1); self:roll()
            end, { size = 44 })
        elseif m == "Arrow" then
            draw_arrow(s, cx, cy, math.min(w, card_h) * 0.36, self.angle)
        elseif m == "D20" then
            draw_d20(s, cx, cy, math.min(w, card_h) * 0.4, self.d20)
        elseif m == "8-Ball" then
            draw_8ball(s, cx, cy, math.min(w, card_h) * 0.42, self.ball)
        else
            draw_coin(s, cx, cy, math.min(w, card_h) * 0.36, self.heads)
        end
        local label = ({ D6 = "Roll", Arrow = "Spin", D20 = "Roll D20", ["8-Ball"] = "Shake", Coin = "Flip" })[m]
        ctx:button(x, ctx.H - ui.BTN_H - dp(40), w, ui.BTN_H, label, function() self:roll() end, { style = "solid", size = 40 })
    end
    return scr
end

return M
