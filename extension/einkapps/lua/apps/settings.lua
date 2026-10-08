-- Settings, diagnostics and a touch test.
local ui = require("core.ui")
local gfx = require("core.gfx")
local sys = require("core.sys")
local store = require("core.store")
local display = require("core.display")
local input = require("core.input")
local net = require("core.net")
local kindle = require("core.kindle")
local reader = require("core.reader")
local html = require("core.html")

local dp = ui.dp
local BLACK, WHITE, DARK, LIGHT = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.LIGHT

local M = {}

local function TouchTest()
    local scr = { marks = {} }
    local function add(ev, kind)
        table.insert(scr.marks, { x = ev.x, y = ev.y, kind = kind, x2 = ev.x2, y2 = ev.y2, dir = ev.dir })
        if #scr.marks > 8 then table.remove(scr.marks, 1) end
        ui.redraw()
    end
    function scr:on_tap(ev) add(ev, "tap") end
    function scr:on_hold(ev) add(ev, "hold") end
    function scr:on_swipe(ev) add(ev, "swipe") end
    function scr:render(ctx)
        local s = ctx.s
        local top = ctx:header("Touch test")
        ctx:paragraph(ui.M, top + dp(30), ctx.W - 2 * ui.M,
            "Tap, hold and swipe anywhere. Each crosshair should appear exactly under your finger. If it is mirrored or swapped, fix it in Settings.",
            { font = ui.font("sans", 30), color = DARK })
        local f = ui.font("sans", 26)
        for k, m in ipairs(self.marks) do
            local c = (k == #self.marks) and BLACK or LIGHT
            s:line(m.x - dp(40), m.y, m.x + dp(40), m.y, c, dp(4))
            s:line(m.x, m.y - dp(40), m.x, m.y + dp(40), c, dp(4))
            if m.kind == "swipe" then s:line(m.x, m.y, m.x2, m.y2, c, dp(3)) end
            if k == #self.marks then
                local label = string.format("%s %d,%d%s", m.kind, m.x, m.y, m.dir and (" " .. m.dir) or "")
                f:draw_top(s, math.min(m.x + dp(30), ctx.W - f:width(label) - dp(10)), m.y + dp(30), label, BLACK)
            end
        end
    end
    return scr
end

function M.new()
    local cfg = store.load("settings", { flash_every = 24 })
    local scr = {}
    local function save()
        store.save("settings", cfg)
        display.flash_every = cfg.flash_every
    end

    function scr:render(ctx)
        local top = ctx:header("Settings")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(24)
        local rh = dp(100)
        ctx:stepper(x, y, w, rh, "Refreshes between flashes", cfg.flash_every,
            function() cfg.flash_every = math.max(4, cfg.flash_every - 4); save(); ui.redraw() end,
            function() cfg.flash_every = math.min(100, cfg.flash_every + 4); save(); ui.redraw() end)
        y = y + rh + dp(14)
        ctx:toggle(x, y, w, rh, "Touch: swap X/Y (restart app)", cfg.touch_swap_xy, function(v) cfg.touch_swap_xy = v or nil; save(); ui.redraw() end)
        y = y + rh + dp(6)
        ctx:toggle(x, y, w, rh, "Touch: mirror X (restart app)", cfg.touch_mirror_x, function(v) cfg.touch_mirror_x = v or nil; save(); ui.redraw() end)
        y = y + rh + dp(6)
        ctx:toggle(x, y, w, rh, "Touch: mirror Y (restart app)", cfg.touch_mirror_y, function(v) cfg.touch_mirror_y = v or nil; save(); ui.redraw() end)
        y = y + rh + dp(6)
        -- not saved: it switches itself off when the app closes
        ctx:toggle(x, y, w, rh, "Skip HTTPS certificate checks", net.insecure, function(v)
            net.insecure = v and true or false; ui.redraw()
        end)
        y = y + rh
        if net.insecure then
            y = y + ctx:paragraph(x, y, w, "Unsafe on shared Wi-Fi. Turns off when you close the app, and never applies to OGS or Lichess.",
                { font = ui.font("sans", 24), color = DARK })
        end
        y = y + dp(24)
        ctx:button_row(x, y, w, ui.BTN_H, {
            { "Touch test", function() ui.push(TouchTest()) end, { size = 34 } },
            { "View log", function()
                local log = sys.read_file(ui.rt.root .. "/data/log.txt") or "(empty)"
                if #log > 20000 then log = log:sub(-20000) end
                reader.open({ header = "Log", title = "data/log.txt", blocks = html.text_blocks(log) })
            end, { size = 34 } },
        })
        y = y + ui.BTN_H + dp(30)
        local f = ui.font("sans", 26)
        local info = {
            string.format("Screen %d×%d @ %d dpi%s", display.w, display.h, display.dpi or 0,
                display.device and (" · " .. display.device) or ""),
            "Touch: " .. input.device_info(),
            "FBInk: " .. tostring(display.fbink or "simulator"),
            "TLS: " .. (net.has_tls() and "LuaSec available" or "missing!") .. " · Wi-Fi: " .. (kindle.wifi_connected() and "connected" or "off"),
            "Battery: " .. tostring(kindle.battery() or "?") .. "%",
            "Data folder: extensions/einkapps/data",
        }
        for _, line in ipairs(info) do
            y = y + ctx:paragraph(x, y, w, line, { font = f, color = DARK }) + dp(6)
        end
        y = y + dp(16)
        ctx:paragraph(x, y, w,
            "Chess pieces: cburnett set by Colin M.L. Burnett (CC BY-SA 3.0), via Lichess. Fonts: DejaVu, Poppins (OFL). Calculator, dice, sudoku, chess, clock, weather, Wikipedia, RSS and DuckDuckGo are ports of CrossPoint Apps (MIT).",
            { font = ui.font("sans", 22), color = DARK })
    end
    return scr
end

M.TouchTest = TouchTest
return M
