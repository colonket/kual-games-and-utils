-- TEMPORARY test stand-in for lua/apps/lib/goboard.lua (workstream A owns the real one).
-- Simple drawing that honors the SPEC contract.
local ui = require("core.ui")
local gfx = require("core.gfx")
local go = require("apps.lib.go")

local BLACK, WHITE, DARK, GRAY, LIGHT = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.GRAY, gfx.LIGHT
local M = {}
local Board = {}
Board.__index = Board

function M.new(opts)
    opts = opts or {}
    return setmetatable({ on_tap = opts.on_tap, on_hold = opts.on_hold }, Board)
end

function Board:point_xy(x, y)
    local g = self.geom
    return math.floor(g.ox + x * g.step + 0.5), math.floor(g.oy + y * g.step + 0.5)
end

local LETTERS = "ABCDEFGHJKLMNOPQRSTUVWXYZ"

function Board:draw(ctx, g, x, y, size, ov)
    ov = ov or {}
    local s = ctx.s
    local n = math.max(g.w, g.h)
    local pad = ov.coords and math.floor(size / (n + 1)) or math.floor(size / (n * 2))
    local step = (size - 2 * pad) / (n - 1)
    local ox, oy = x + pad, y + pad
    self.geom = { x = x, y = y, size = size, ox = ox, oy = oy, step = step, w = g.w, h = g.h }
    s:fill_rect(x, y, size, size, WHITE)
    local t = math.max(1, ui.dp(2))
    for i = 0, g.w - 1 do s:fill_rect(math.floor(ox + i * step - t / 2), math.floor(oy), t, math.floor(step * (g.h - 1)), BLACK) end
    for j = 0, g.h - 1 do s:fill_rect(math.floor(ox), math.floor(oy + j * step - t / 2), math.floor(step * (g.w - 1)) + t, t, BLACK) end
    for _, i in ipairs(go.star_points(g.w)) do
        local px, py = self:point_xy(i % g.w, math.floor(i / g.w))
        s:fill_circle(px, py, math.max(3, step * 0.12), BLACK)
    end
    if ov.coords then
        local f = ui.font("sans", math.max(20, math.min(28, step * 0.5 / ui.rt.S)))
        for i = 0, g.w - 1 do
            local px = self:point_xy(i, 0)
            f:draw_center(s, px - step / 2, y, step, pad * 0.9, LETTERS:sub(i + 1, i + 1), DARK)
        end
        for j = 0, g.h - 1 do
            local _, py = self:point_xy(0, j)
            f:draw_center(s, x, py - step / 2, pad * 0.9, step, tostring(g.h - j), DARK)
        end
    end
    local r = step * 0.47
    for j = 0, g.h - 1 do for i = 0, g.w - 1 do
        local idx = j * g.w + i
        local v = g.board[idx]
        local px, py = self:point_xy(i, j)
        if v == 1 then
            s:fill_circle(px, py, r, BLACK)
        elseif v == 2 then
            s:fill_circle(px, py, r, WHITE)
            s:circle(px, py, r, BLACK, math.max(2, step * 0.06))
        end
        if v ~= 0 and ov.dead and ov.dead[idx] then
            local c = v == 1 and WHITE or BLACK
            local d = r * 0.5
            s:line(px - d, py - d, px + d, py + d, c, math.max(2, step * 0.08))
            s:line(px - d, py + d, px + d, py - d, c, math.max(2, step * 0.08))
        end
        local terr = ov.territory and ov.territory[idx]
        if terr and (v == 0 or (ov.dead and ov.dead[idx])) then
            local q = step * 0.3
            if terr == 1 then s:fill_rect(px - q / 2, py - q / 2, q, q, BLACK)
            else s:fill_rect(px - q / 2, py - q / 2, q, q, WHITE); s:rect(px - q / 2, py - q / 2, q, q, BLACK, math.max(2, step * 0.05)) end
        end
    end end
    if ov.last and ov.last.x and ov.last.x >= 0 then
        local px, py = self:point_xy(ov.last.x, ov.last.y)
        local v = g:at(ov.last.x, ov.last.y)
        s:circle(px, py, r * 0.45, v == 1 and WHITE or BLACK, math.max(2, step * 0.08))
    end
    if ov.pending then
        local p = ov.pending
        local px, py = self:point_xy(p.x, p.y)
        s:circle(px, py, r, BLACK, math.max(3, step * 0.1))
        s:fill_circle(px, py, r * 0.35, p.color == 1 and BLACK or GRAY)
    end
    if ov.hint then
        ui.font("bold", 30):draw_center(s, x, y, size, size, ov.hint, DARK)
    end
    local function nearest(ex, ey)
        local gx = math.floor((ex - ox) / step + 0.5)
        local gy = math.floor((ey - oy) / step + 0.5)
        if gx < 0 or gy < 0 or gx >= g.w or gy >= g.h then return nil end
        return gx, gy
    end
    ctx:hit(x, y, size, size, function(ev)
        local gx, gy = nearest(ev.x, ev.y)
        if gx and self.on_tap then self.on_tap(gx, gy) end
    end, function(ev)
        local gx, gy = nearest(ev.x, ev.y)
        if gx and self.on_hold then self.on_hold(gx, gy) end
    end, { label = "goboard" })
end

return M
