-- Visual + tap-mapping demo for apps/lib/goboard.lua (no OGS app needed).
-- usage: tests/sim.sh calculator tests/scripts/goboard_demo.lua /tmp/sim_A/goboard [W H DPI]
local S = require("simlib")
local ui = require("core.ui")
local input = require("core.input")
local go = require("apps.lib.go")
local goboard = require("apps.lib.goboard")

-- 19x19 mid-game (SGF coords); includes a capture.
local MOVES19 = "pddpqpddfqcncfnqqjpjqfjdnccqdrjpqnpnqoqmplcicl" ..
    "rdqcrcqbrbqdpeoenendmdmepcrepfhqgrhrgqiqbqbpcpdocoeoe" .. "ndnemm"

local function midgame()
    local g = go.new(19)
    for k = 1, #MOVES19 - 1, 2 do
        local x, y = go.from_sgf(MOVES19:sub(k, k + 1))
        if g:legal(x, y) then g:play(x, y) end
    end
    return g
end

-- 9x9 finished position: X/O stones, x/o = stones that will be marked dead.
local POS9 = {
    "...XO....",
    ".o.XO..x.",
    "..XXOO...",
    "..X.XO...",
    "XXX.XOOOO",
    "..XXXXO..",
    ".....XO..",
    ".oo.XO...",
    "....XO...",
}
local function scoring()
    local g = go.new(9)
    g.rules, g.komi = "japanese", 6.5
    local deadpts = {}
    for y, row in ipairs(POS9) do
        for x = 1, 9 do
            local ch = row:sub(x, x)
            local c = (ch == "X" or ch == "x") and go.BLACK or (ch == "O" or ch == "o") and go.WHITE or nil
            if c then g:place(x - 1, y - 1, c) end
            if ch == "x" or ch == "o" then deadpts[#deadpts + 1] = { x - 1, y - 1 } end
        end
    end
    local dead = {}
    for _, p in ipairs(deadpts) do
        if not dead[p[2] * 9 + p[1]] then go.toggle_group_dead(g, dead, p[1], p[2]) end
    end
    return g, dead
end

local scr = { mode = "mid", taps = {} }
scr.board = goboard.new{
    on_tap = function(x, y) scr.taps[#scr.taps + 1] = { x, y }; if scr.mode == "mid" then scr.pending = { x = x, y = y, color = scr.g.turn } end end,
    on_hold = function(x, y) scr.held = { x, y } end,
}
scr.g = midgame()
function scr:render(ctx)
    local s = ctx.s
    s:fill(255)
    local W = ctx.W
    local m = ui.dp(16)
    local size = W - 2 * m
    local top = ui.dp(140)
    ctx:text(m, ui.dp(40), self.mode == "mid" and "19×19 mid-game" or (self.mode == "score" and "9×9 scoring" or "13×13"),
        { font = ui.font("bold", 44) })
    if self.mode == "mid" then
        self.board:draw(ctx, self.g, m, top, size, {
            coords = true, last = self.g.last, pending = self.pending or { x = 16, y = 16, color = self.g.turn },
            hint = self.pending and "Tap again to confirm" or nil,
        })
    elseif self.mode == "score" then
        local sc = go.score(self.g, self.dead)
        self.board:draw(ctx, self.g, m, top, size, { coords = true, dead = self.dead, territory = sc.territory,
            last = { x = 4, y = 8 }, hint = "Tap dead groups, then Accept" })
        ctx:text(m, top + size + ui.dp(30), string.format("Black %.1f  ·  White %.1f", sc.black, sc.white),
            { font = ui.font("sans", 40) })
    else
        self.board:draw(ctx, self.g, m, top, size, { last = self.g.last })
    end
end

local function tap_point(x, y)
    return function()
        if ui.rt.dirty then ui.render_now() end
        local px, py = scr.board:point_xy(x, y)
        input.inject({ type = "tap", x = px, y = py })
    end
end

return {
    function() ui.push(scr) end,
    S.check(function() return scr.board.geom and scr.board.geom.cell > 0 end, "goboard geometry"),
    S.snap("go19_mid"),
    tap_point(3, 3),
    S.check(function() local t = scr.taps[#scr.taps]; return t and t[1] == 3 and t[2] == 3 end, "tap maps to D16"),
    function()
        local px, py = scr.board:point_xy(18, 0)
        local c = scr.board.geom.cell
        input.inject({ type = "tap", x = px + math.floor(c * 0.4), y = py - math.floor(c * 0.4) })
    end,
    S.check(function() local t = scr.taps[#scr.taps]; return t[1] == 18 and t[2] == 0 end, "near-corner tap snaps to T19"),
    function()
        local n = #scr.taps
        scr.ntaps = n
        local px, py = scr.board:point_xy(0, 18)
        local c = scr.board.geom.cell
        input.inject({ type = "tap", x = px - math.floor(c * 0.8), y = py + math.floor(c * 0.8) })
    end,
    S.check(function() return #scr.taps == scr.ntaps end, "tap beyond half a cell is ignored"),
    function()
        local px, py = scr.board:point_xy(9, 9)
        input.inject({ type = "hold", x = px, y = py })
    end,
    S.check(function() return scr.held and scr.held[1] == 9 and scr.held[2] == 9 end, "hold maps to point"),
    tap_point(16, 2),
    S.snap("go19_pending"),
    function() scr.mode = "score"; scr.g, scr.dead = scoring(); scr.pending = nil; ui.redraw() end,
    S.check(function() local sc = go.score(scr.g, scr.dead); return sc.black > 0 and sc.white > 0 end, "score computed"),
    S.snap("go9_score"),
    function()
        scr.mode = "plain"; scr.g = go.new(13)
        for _, mv in ipairs({ { 3, 3 }, { 9, 9 }, { 9, 3 }, { 3, 9 }, { 6, 6 } }) do scr.g:play(mv[1], mv[2]) end
        ui.redraw()
    end,
    S.snap("go13_plain"),
}
