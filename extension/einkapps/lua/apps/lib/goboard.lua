-- Go board widget: e-ink friendly drawing of a go.lua Game plus tap-to-point mapping.
local ui = require("core.ui")
local gfx = require("core.gfx")
local font = require("core.font")
local go = require("apps.lib.go")

local floor, max, min = math.floor, math.max, math.min
local BLACK, WHITE = gfx.BLACK, gfx.WHITE
local BOARD_BG = 0xE6
local COORD_C = 0x44

local goboard = {}

local Board = {}
Board.__index = Board
goboard.Board = Board

function goboard.new(opts)
    opts = opts or {}
    return setmetatable({ on_tap = opts.on_tap, on_hold = opts.on_hold }, Board)
end

-- Layout ------------------------------------------------------------------------------
-- Fits a w×h grid into the size×size square at (x, y). Margin (in cells) leaves
-- room for half a stone at the edges, or for coordinate labels.
-- `band` pixels at the bottom are reserved (for the hint pill).
local function layout(x, y, size, w, h, coords, band, m)
    band = band or 0
    m = m or (coords and 1.05 or 0.55)
    local cell = floor(min(size / (w - 1 + 2 * m), (size - band) / (h - 1 + 2 * m)))
    cell = max(cell, 4)
    local gw, gh = cell * (w - 1), cell * (h - 1)
    local ox = x + floor((size - gw) / 2)
    local oy = y + floor((size - band - gh) / 2)
    return { x = x, y = y, size = size, w = w, h = h, cell = cell, ox = ox, oy = oy, coords = coords, margin = m }
end

function Board:point_xy(px, py)
    local g = self.geom
    return g.ox + px * g.cell, g.oy + py * g.cell
end

-- Nearest intersection for a screen point, or nil if more than half a cell outside.
function Board:point_at(sx, sy)
    local g = self.geom
    if not g then return nil end
    local fx, fy = (sx - g.ox) / g.cell, (sy - g.oy) / g.cell
    if fx < -0.5 or fy < -0.5 or fx > g.w - 0.5 or fy > g.h - 0.5 then return nil end
    local px, py = floor(fx + 0.5), floor(fy + 0.5)
    px, py = max(0, min(g.w - 1, px)), max(0, min(g.h - 1, py))
    return px, py
end

-- Primitives --------------------------------------------------------------------------
-- Hatch the inside of a circle with diagonal lines (period p, line thickness t).
local function hatch_circle(s, cx, cy, r, c, p, t)
    local r2 = r * r
    for yy = floor(cy - r), floor(cy + r) do
        local dy = yy + 0.5 - cy
        for xx = floor(cx - r), floor(cx + r) do
            local dx = xx + 0.5 - cx
            if dx * dx + dy * dy <= r2 and (xx + yy) % p < t then
                s:blend(xx, yy, c, 1)
            end
        end
    end
end

local function cross(s, cx, cy, a, c, t)
    s:line(cx - a, cy - a, cx + a, cy + a, c, t)
    s:line(cx - a, cy + a, cx + a, cy - a, c, t)
end

local function stone(s, cx, cy, r, color, ring)
    if color == go.BLACK then
        s:fill_circle(cx, cy, r, BLACK)
    else
        s:fill_circle(cx, cy, r, BLACK)
        s:fill_circle(cx, cy, r - ring, WHITE)
    end
end

-- Drawing -----------------------------------------------------------------------------
function Board:draw(ctx, g, x, y, size, ov)
    ov = ov or {}
    local s = ctx.s
    local W, H = g.w, g.h
    local hint = ov.hint ~= "" and ov.hint or nil
    local hfont, band = nil, 0
    if hint then
        hfont = font.get("bold", max(20, min(36, size / 28)))
        band = hfont.height + ui.dp(18) + ui.dp(12)
    end
    local geo = layout(x, y, size, W, H, ov.coords, band)
    local cfont
    if ov.coords then
        -- On small screens the smallest font may not fit the default margin: widen it.
        cfont = font.get("bold", max(20, geo.cell * 0.42))
        local need = (cfont:width(tostring(H)) + ui.dp(6)) / geo.cell + 0.5
        if need > geo.margin then
            geo = layout(x, y, size, W, H, true, band, need)
            cfont = font.get("bold", max(20, geo.cell * 0.42))
        end
    end
    self.geom = geo
    local cell, ox, oy = geo.cell, geo.ox, geo.oy
    local gw, gh = cell * (W - 1), cell * (H - 1)

    -- background
    s:fill_rect(x, y, size, size, BOARD_BG)

    -- grid
    local t = max(1, floor(cell / 28 + 0.5))
    local te = max(t + 1, min(floor(cell / 14 + 0.5), t * 2 + 1))
    for i = 0, W - 1 do
        local lx = ox + i * cell
        local th = (i == 0 or i == W - 1) and te or t
        s:fill_rect(lx - floor(th / 2), oy - floor(te / 2), th, gh + te, BLACK)
    end
    for j = 0, H - 1 do
        local ly = oy + j * cell
        local th = (j == 0 or j == H - 1) and te or t
        s:fill_rect(ox - floor(te / 2), ly - floor(th / 2), gw + te, th, BLACK)
    end
    if W == H then
        local sr = max(2.5, cell * 0.14)
        for _, i in ipairs(go.star_points(W)) do
            s:fill_circle(ox + (i % W) * cell + 0.5, oy + floor(i / W) * cell + 0.5, sr, BLACK)
        end
    end

    -- coordinates
    if ov.coords then
        local f = cfont
        local m = cell * geo.margin
        for i = 0, W - 1 do
            local lbl = go.COLS:sub(i + 1, i + 1)
            local cx = ox + i * cell
            f:draw_center_ink(s, cx - cell / 2, oy - m, cell, m - cell * 0.5, lbl, COORD_C)
            f:draw_center_ink(s, cx - cell / 2, oy + gh + cell * 0.5, cell, m - cell * 0.5, lbl, COORD_C)
        end
        for j = 0, H - 1 do
            local lbl = tostring(H - j)
            local cy = oy + j * cell
            f:draw_center_ink(s, ox - m, cy - cell / 2, m - cell * 0.45, cell, lbl, COORD_C)
            f:draw_center_ink(s, ox + gw + cell * 0.45, cy - cell / 2, m - cell * 0.45, cell, lbl, COORD_C)
        end
    end

    -- territory under stones (only on empty points; dead stones get theirs drawn later)
    local terr = ov.territory or {}
    local dead = ov.dead or {}
    local r = cell * 0.48
    local ring = max(2, floor(cell * 0.06 + 0.5))
    local tsz = max(5, floor(cell * 0.34))
    local tline = max(1, floor(cell / 30 + 0.5))
    local function terr_square(cx, cy, color, sz)
        local x0, y0 = floor(cx - sz / 2 + 0.5), floor(cy - sz / 2 + 0.5)
        if color == go.BLACK then
            s:fill_rect(x0, y0, sz, sz, BLACK)
        else
            s:fill_rect(x0, y0, sz, sz, BLACK)
            s:fill_rect(x0 + tline + 1, y0 + tline + 1, sz - 2 * (tline + 1), sz - 2 * (tline + 1), WHITE)
        end
    end

    for j = 0, H - 1 do
        for i = 0, W - 1 do
            local idx = j * W + i
            local v = g.board[idx]
            local cx, cy = ox + i * cell + 0.5, oy + j * cell + 0.5
            if v ~= go.EMPTY then
                if dead[idx] then
                    -- faded stone with an ×
                    if v == go.BLACK then
                        s:fill_circle(cx, cy, r, 0x66)
                    else
                        s:fill_circle(cx, cy, r, 0x66)
                        s:fill_circle(cx, cy, r - ring, WHITE)
                    end
                    local tc = terr[idx]
                    if tc then
                        terr_square(cx, cy, tc, floor(tsz * 1.15))
                    else
                        cross(s, cx, cy, r * 0.42, v == go.BLACK and WHITE or BLACK, max(2, floor(cell * 0.08)))
                    end
                else
                    stone(s, cx, cy, r, v, ring)
                end
            elseif terr[idx] then
                terr_square(cx, cy, terr[idx], tsz)
            end
        end
    end

    -- last move marker
    local last = ov.last
    if last and last.x and last.x >= 0 and last.y >= 0 and last.x < W and last.y < H then
        local v = g.board[last.y * W + last.x]
        local cx, cy = ox + last.x * cell + 0.5, oy + last.y * cell + 0.5
        if v == go.BLACK then
            s:circle(cx, cy, r * 0.5, WHITE, max(2, cell * 0.09))
        elseif v == go.WHITE then
            s:circle(cx, cy, r * 0.5, BLACK, max(2, cell * 0.09))
        end
    end

    -- pending (ghost) stone
    local p = ov.pending
    if p and p.x and p.x >= 0 and p.y >= 0 and p.x < W and p.y < H then
        local cx, cy = ox + p.x * cell + 0.5, oy + p.y * cell + 0.5
        local pr = r - 0.5
        local period = max(4, floor(cell / 6))
        local ht = max(2, floor(period / 2.5))
        if (p.color or g.turn) == go.WHITE then
            s:fill_circle(cx, cy, pr, WHITE)
            hatch_circle(s, cx, cy, pr - ring, 0x99, period, ht)
            s:circle(cx, cy, pr, BLACK, ring)
        else
            s:fill_circle(cx, cy, pr, BOARD_BG)
            hatch_circle(s, cx, cy, pr, BLACK, period, ht)
            s:circle(cx, cy, pr, BLACK, max(ring + 1, floor(cell * 0.09)))
        end
        -- small solid centre so the point reads clearly
        local cr = max(3, cell * 0.12)
        s:fill_circle(cx, cy, cr + max(2, ring), WHITE)
        s:fill_circle(cx, cy, cr, BLACK)
    end

    -- hint pill in the reserved band along the bottom edge
    if hint then
        local f = hfont
        local tw = f:width(hint)
        local pw = min(size - ui.dp(20), tw + ui.dp(40))
        local ph = f.height + ui.dp(18)
        local px, py = x + floor((size - pw) / 2), y + size - ph - ui.dp(6)
        s:fill_round_rect(px, py, pw, ph, ph / 2, WHITE)
        s:round_rect(px, py, pw, ph, ph / 2, BLACK, max(2, ui.dp(3)))
        f:draw_center(s, px, py, pw, ph, f:ellipsize(hint, pw - ui.dp(24)), BLACK)
    end

    local tap = function(ev)
        local px, py = self:point_at(ev.x, ev.y)
        if px and self.on_tap then self.on_tap(px, py) end
    end
    local hold = nil
    if self.on_hold then
        hold = function(ev)
            local px, py = self:point_at(ev.x, ev.y)
            if px then self.on_hold(px, py) end
        end
    end
    ctx:hit(x, y, size, size, tap, hold, { label = "goboard" })
end

return goboard
