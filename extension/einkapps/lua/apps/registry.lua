-- The list of apps, their launcher icons, and how to open them.
local ui = require("core.ui")
local gfx = require("core.gfx")

local BLACK, WHITE, GRAY = gfx.BLACK, gfx.WHITE, gfx.GRAY
local registry = {}

local function glyph(ch, fam)
    return function(s, x, y, size)
        local f = ui.font(fam or "sans", size * 0.7 / ui.rt.S)
        f:draw_center_ink(s, x, y, size, size, ch, BLACK)
    end
end

local icons = {}

function icons.grid(s, x, y, size)
    local m = size * 0.2
    local g = (size - 2 * m)
    s:rect(x + m, y + m, g, g, BLACK, math.max(3, size * 0.035))
    for i = 1, 2 do
        local t = math.max(2, size * 0.018)
        s:fill_rect(x + m + g * i / 3 - t / 2, y + m, t, g, BLACK)
        s:fill_rect(x + m, y + m + g * i / 3 - t / 2, g, t, BLACK)
    end
    local f = ui.font("bold", size * 0.16 / ui.rt.S)
    f:draw_center_ink(s, x + m, y + m, g / 3, g / 3, "5", BLACK)
    f:draw_center_ink(s, x + m + g * 2 / 3, y + m + g / 3, g / 3, g / 3, "3", BLACK)
    f:draw_center_ink(s, x + m + g / 3, y + m + g * 2 / 3, g / 3, g / 3, "8", BLACK)
end

function icons.clock(s, x, y, size)
    local cx, cy, r = x + size / 2, y + size / 2, size * 0.32
    s:circle(cx, cy, r, BLACK, math.max(3, size * 0.045))
    local t = math.max(3, size * 0.04)
    s:line(cx, cy, cx, cy - r * 0.7, BLACK, t)
    s:line(cx, cy, cx + r * 0.5, cy + r * 0.15, BLACK, t)
    s:fill_circle(cx, cy, t, BLACK)
end

function icons.rss(s, x, y, size)
    local ox, oy = x + size * 0.26, y + size * 0.74
    s:fill_circle(ox + size * 0.05, oy - size * 0.05, size * 0.06, BLACK)
    local t = math.max(4, size * 0.07)
    for i, r in ipairs({ 0.26, 0.46 }) do
        local R = size * r
        -- quarter ring
        s:push_clip(ox, oy - R - t, R + t, R + t)
        s:circle(ox, oy, R, BLACK, t)
        s:pop_clip()
    end
end

function icons.search(s, x, y, size)
    local cx, cy, r = x + size * 0.43, y + size * 0.43, size * 0.2
    local t = math.max(4, size * 0.06)
    s:circle(cx, cy, r, BLACK, t)
    s:line(cx + r * 0.75, cy + r * 0.75, x + size * 0.76, y + size * 0.76, BLACK, t * 1.4)
end

function icons.calc(s, x, y, size)
    local m = size * 0.22
    local w, h = size - 2 * m, size - 2 * m * 0.8
    local bx, by = x + m, y + m * 0.8
    s:round_rect(bx, by, w, h, size * 0.05, BLACK, math.max(3, size * 0.035))
    s:fill_rect(bx + w * 0.15, by + h * 0.12, w * 0.7, h * 0.18, BLACK)
    for r = 0, 2 do
        for c = 0, 2 do
            s:fill_rect(bx + w * (0.15 + c * 0.25), by + h * (0.42 + r * 0.18), w * 0.17, h * 0.11, BLACK)
        end
    end
end

function icons.mtg(s, x, y, size)
    local f = ui.font("num", size * 0.5 / ui.rt.S)
    f:draw_center_ink(s, x, y + size * 0.05, size, size * 0.7, "20", BLACK)
    local hf = ui.font("sans", size * 0.22 / ui.rt.S)
    hf:draw_center_ink(s, x, y + size * 0.7, size, size * 0.2, "♥", BLACK)
end

function icons.lichess(s, x, y, size)
    glyph("♞")(s, x, y, size)
end

-- A 3×3 corner of a go board with one black and one white stone.
function icons.go(s, x, y, size)
    local m = size * 0.21
    local g = size - 2 * m
    local step = g / 2
    local t = math.max(2, size * 0.025)
    for i = 0, 2 do
        s:fill_rect(x + m + step * i - t / 2, y + m - step * 0.4, t, g + step * 0.8, BLACK)
        s:fill_rect(x + m - step * 0.4, y + m + step * i - t / 2, g + step * 0.8, t, BLACK)
    end
    local r = step * 0.46
    s:fill_circle(x + m + step, y + m + step, r, BLACK)
    s:fill_circle(x + m + step * 2, y + m, r, WHITE)
    s:circle(x + m + step * 2, y + m, r, BLACK, math.max(3, size * 0.035))
end

registry.apps = {
    { id = "lichess", title = "Lichess", icon = icons.lichess, module = "apps.lichess.app" },
    { id = "ogs", title = "Go (OGS)", icon = icons.go, module = "apps.ogs.app" },
    { id = "mtg", title = "Life Counter", icon = icons.mtg, module = "apps.mtg" },
    { id = "chess", title = "Chess", icon = glyph("♚"), module = "apps.chess_local" },
    { id = "sudoku", title = "Sudoku", icon = icons.grid, module = "apps.sudoku" },
    { id = "dice", title = "Dice & 8-Ball", icon = glyph("⚄"), module = "apps.dice" },
    { id = "calculator", title = "Calculator", icon = icons.calc, module = "apps.calculator" },
    { id = "clock", title = "Clock", icon = icons.clock, module = "apps.clock" },
    { id = "weather", title = "Weather", icon = glyph("☀"), module = "apps.weather" },
    { id = "wikipedia", title = "Wikipedia", icon = glyph("W", "serifb"), module = "apps.wikipedia" },
    { id = "rss", title = "RSS & Reddit", icon = icons.rss, module = "apps.rss" },
    { id = "duckduckgo", title = "DuckDuckGo", icon = icons.search, module = "apps.duckduckgo" },
    { id = "settings", title = "Settings", icon = glyph("⚙"), module = "apps.settings" },
}

function registry.find(id)
    for _, a in ipairs(registry.apps) do
        if a.id == id then return a end
    end
end

function registry.open(id, is_root)
    if id == "home" then
        local home = require("apps.home")
        ui.push(home.new())
        return
    end
    local a = registry.find(id)
    if not a then error("unknown app: " .. tostring(id)) end
    local mod = require(a.module)
    local scr = mod.new()
    ui.rt.app_base = #ui.rt.stack
    ui.push(scr)
end

return registry
