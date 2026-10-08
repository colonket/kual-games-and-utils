-- Desk clock (ported from CrossPoint Apps' ClockActivity): digital, analog
-- and flip styles; 12/24h; adjustable UTC offset. Keeps the screen awake
-- while open and refreshes once a minute.
local ui = require("core.ui")
local gfx = require("core.gfx")
local font = require("core.font")
local sys = require("core.sys")
local store = require("core.store")
local kindle = require("core.kindle")

local dp = ui.dp
local BLACK, WHITE, DARK, GRAY, PALE, LIGHT = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.GRAY, gfx.PALE, gfx.LIGHT

local M = {}
local STYLES = { "Digital", "Analog", "Flip" }

function M.new()
    local cfg = store.load("clock", { style = 1, h24 = false, offset = nil, show_date = true })
    local scr = { chrome = true }

    local function now_t()
        local off = cfg.offset or kindle.local_offset()
        return os.date("!*t", os.time() + off), off
    end

    local function schedule()
        local secs = os.time() % 60
        ui.cancel(scr.timer)
        scr.timer = ui.after((60 - secs) * 1000 + 200, function()
            local t = now_t()
            ui.redraw(t.min == 0)   -- flash once an hour to clear ghosting
            schedule()
        end, scr)
    end

    function scr:enter()
        kindle.prevent_screensaver(true)
        schedule()
    end
    function scr:leave()
        ui.cancel_owner(self)
        kindle.prevent_screensaver(false)
    end
    function scr:on_wake() schedule(); ui.redraw(true) end

    local function hhmm(t)
        local h = t.hour
        if not cfg.h24 then
            h = h % 12
            if h == 0 then h = 12 end
        end
        return h, t.min
    end

    local function draw_digital(s, x, y, w, h, t)
        local hh, mm = hhmm(t)
        local txt = (cfg.h24 and string.format("%02d", hh) or tostring(hh)) .. ":" .. string.format("%02d", mm)
        local f = font.fit("num", txt, w * 0.95, h * 0.8)
        f:draw_center_ink(s, x, y, w, h, txt, BLACK)
    end

    local function draw_analog(s, x, y, w, h, t)
        local cx, cy = x + w / 2, y + h / 2
        local r = math.min(w, h) * 0.46
        s:circle(cx, cy, r, BLACK, dp(10))
        for k = 0, 59 do
            local a = math.rad(k * 6 - 90)
            local long = k % 5 == 0
            local r1 = r - dp(long and 52 or 26)
            s:line(cx + math.cos(a) * r1, cy + math.sin(a) * r1, cx + math.cos(a) * (r - dp(18)), cy + math.sin(a) * (r - dp(18)),
                long and BLACK or GRAY, long and dp(8) or dp(3))
        end
        local nf = ui.font("bold", 48)
        for k = 1, 12 do
            local a = math.rad(k * 30 - 90)
            local rr = r - dp(100)
            nf:draw_center_ink(s, cx + math.cos(a) * rr - dp(40), cy + math.sin(a) * rr - dp(40), dp(80), dp(80), tostring(k), BLACK)
        end
        local ha = math.rad(((t.hour % 12) + t.min / 60) * 30 - 90)
        local ma = math.rad(t.min * 6 - 90)
        s:line(cx, cy, cx + math.cos(ha) * r * 0.5, cy + math.sin(ha) * r * 0.5, BLACK, dp(18))
        s:line(cx, cy, cx + math.cos(ma) * r * 0.78, cy + math.sin(ma) * r * 0.78, BLACK, dp(10))
        s:fill_circle(cx, cy, dp(22), BLACK)
        s:fill_circle(cx, cy, dp(8), WHITE)
    end

    local function draw_flip(s, x, y, w, h, t)
        local hh, mm = hhmm(t)
        local hs = cfg.h24 and string.format("%02d", hh) or string.format("%2d", hh):gsub(" ", "")
        local ms = string.format("%02d", mm)
        local gap = dp(40)
        local cw = (w - gap) / 2
        local ch = math.min(h * 0.75, cw * 1.25)
        local cy = y + (h - ch) / 2
        for k, txt in ipairs({ hs, ms }) do
            local cx = x + (k - 1) * (cw + gap)
            s:fill_round_rect(cx, cy, cw, ch, dp(36), BLACK)
            local f = font.fit("num", "88", cw * 0.86, ch * 0.8)
            f:draw_center_ink(s, cx, cy, cw, ch, txt, WHITE)
            s:fill_rect(cx, cy + ch / 2 - dp(4), cw, dp(8), WHITE)
            s:fill_circle(cx, cy + ch / 2, dp(14), WHITE)
            s:fill_circle(cx + cw, cy + ch / 2, dp(14), WHITE)
        end
    end

    function scr:on_tap(ev)
        self.chrome = not self.chrome
        ui.redraw(true)
    end

    function scr:render(ctx)
        local s = ctx.s
        local t, off = now_t()
        local top = 0
        if self.chrome then
            top = ctx:header("Clock", { right = { "⚙", function() self:settings() end, size = 44 } })
        end
        local x, w = ui.M, ctx.W - 2 * ui.M
        local info_h = dp(260)
        local area_y = top + dp(40)
        local area_h = ctx.H - area_y - info_h - (self.chrome and ui.BTN_H + dp(60) or dp(40))
        local style = STYLES[cfg.style]
        if style == "Digital" then draw_digital(s, x, area_y, w, area_h, t)
        elseif style == "Analog" then draw_analog(s, x, area_y, w, area_h, t)
        else draw_flip(s, x, area_y, w, area_h, t) end
        local y = area_y + area_h + dp(20)
        local df = ui.font("bold", 56)
        local date = os.date("!%A, %B ", os.time() + off) .. t.day
        df:draw_center(s, 0, y, ctx.W, df.height, date, BLACK)
        y = y + df.height + dp(20)
        local inf = ui.font("sans", 34)
        local bat = kindle.battery()
        local parts = {}
        if not cfg.h24 then parts[#parts + 1] = t.hour >= 12 and "PM" or "AM" end
        parts[#parts + 1] = string.format("UTC%+.2g", off / 3600):gsub("%+0$", "")
        if bat then parts[#parts + 1] = "Battery " .. bat .. "%" end
        inf:draw_center(s, 0, y, ctx.W, inf.height, table.concat(parts, "   ·   "), DARK)
        if self.chrome then
            ctx:segmented(x, ctx.H - ui.BTN_H - dp(40), w, ui.BTN_H, STYLES, cfg.style, function(i)
                cfg.style = i; store.save("clock", cfg); ui.redraw(true)
            end, { size = 36 })
            ui.font("sans", 24):draw_center(s, 0, ctx.H - ui.BTN_H - dp(100), ctx.W, dp(40), "Tap the clock to hide the controls", GRAY)
        end
    end

    function scr:settings()
        local st = {}
        function st:render(ctx)
            local top = ctx:header("Clock settings")
            local x, w = ui.M, ctx.W - 2 * ui.M
            local y = top + dp(40)
            ctx:toggle(x, y, w, dp(100), "24-hour time", cfg.h24, function(v) cfg.h24 = v; store.save("clock", cfg); ui.redraw() end)
            y = y + dp(130)
            ctx:toggle(x, y, w, dp(100), "Use the Kindle's time zone", cfg.offset == nil, function(v)
                cfg.offset = (not v) and kindle.local_offset() or nil
                store.save("clock", cfg); ui.redraw()
            end)
            y = y + dp(130)
            if cfg.offset then
                local off = cfg.offset / 3600
                ctx:stepper(x, y, w, dp(100), "UTC offset (hours)", string.format("%+g", off),
                    function() cfg.offset = cfg.offset - 1800; store.save("clock", cfg); ui.redraw() end,
                    function() cfg.offset = cfg.offset + 1800; store.save("clock", cfg); ui.redraw() end)
                y = y + dp(130)
            end
            ctx:paragraph(x, y + dp(20), w,
                "Kindles often keep their system clock in UTC. If the time is off, turn off the Kindle time zone and set your UTC offset (Chicago is −5 in summer, −6 in winter).",
                { font = ui.font("sans", 28), color = DARK })
        end
        ui.push(st)
    end
    return scr
end

return M
