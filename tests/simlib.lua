-- helpers for simulator scripts
local display = require("core.display")
local ui = require("core.ui")
local input = require("core.input")
local M = {}

local function find_hit(text, nth)
    nth = nth or 1
    for pass = 1, 2 do
        local n = 0
        for _, h in ipairs(ui.rt.hits or {}) do
            local d = h.data
            local lbl = d and (d.label or d.title)
            if lbl and ((pass == 1 and lbl == text) or (pass == 2 and tostring(lbl):find(text, 1, true))) then
                n = n + 1
                if n == nth then return h end
            end
        end
    end
end
M.find_hit = find_hit

function M.snap(name)
    return function()
        if ui.rt.dirty then ui.render_now() end
        display.save_pgm(os.getenv("EINK_SIM") .. "/" .. name .. ".pgm")
    end
end
function M.tap(x, y) return { "tap", x, y } end
function M.hold(x, y) return { "hold", x, y } end
function M.swipe(dir, x, y) return { "swipe", x or 500, y or 700, dir } end
function M.wait(ms) return { "wait", ms } end

-- Tap a button / list row by its label
function M.tap_text(text, nth)
    return function()
        if ui.rt.dirty then ui.render_now() end
        local h = find_hit(text, nth)
        if not h then
            local labels = {}
            for _, hh in ipairs(ui.rt.hits or {}) do labels[#labels + 1] = tostring(hh.data and (hh.data.label or hh.data.title)) end
            error("no hit region labelled " .. text .. " in: " .. table.concat(labels, ", "))
        end
        input.inject({ type = "tap", x = h.x + math.floor(h.w / 2), y = h.y + math.floor(h.h / 2) })
    end
end

function M.hold_text(text)
    return function()
        if ui.rt.dirty then ui.render_now() end
        local h = find_hit(text)
        if not h then error("no hit region labelled " .. text) end
        input.inject({ type = "hold", x = h.x + math.floor(h.w / 2), y = h.y + math.floor(h.h / 2) })
    end
end

-- Tap a chess square on the top screen's board
function M.tap_square(name)
    return function()
        if ui.rt.dirty then ui.render_now() end
        local chess = require("apps.lib.chess")
        local scr = ui.top()
        local b = scr.board
        local g = b.geom
        local x, y, w = b:square_xy(chess.sq_parse(name), g.x, g.y, g.size)
        input.inject({ type = "tap", x = x + math.floor(w / 2), y = y + math.floor(w / 2) })
    end
end

-- Wait until a predicate holds (pumping the main loop), up to ms
function M.wait_until(pred, ms)
    local steps = {}
    return { "wait_until", pred, ms or 5000 }
end

function M.check(pred, msg)
    return function()
        if not pred() then error("CHECK FAILED: " .. (msg or "?")) end
        io.stderr:write("ok: ", msg or "", "\n")
    end
end
return M
