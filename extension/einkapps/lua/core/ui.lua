-- Screen stack, main loop and immediate-mode widgets.
--
-- A screen is a table with optional methods:
--   enter(), leave(), render(ctx), on_tap(ev), on_hold(ev), on_swipe(ev),
--   on_back(), on_wake(), tick(now)
-- Each render redraws the full frame into an offscreen surface; the display
-- layer diffs it against what's on the panel and refreshes only what changed.
local sys = require("core.sys")
local gfx = require("core.gfx")
local font = require("core.font")
local display = require("core.display")
local input = require("core.input")
local kindle = require("core.kindle")

local floor, min, max = math.floor, math.min, math.max
local BLACK, WHITE, GRAY, LIGHT, PALE, DARK, MID = gfx.BLACK, gfx.WHITE, gfx.GRAY, gfx.LIGHT, gfx.PALE, gfx.DARK, gfx.MID

local ui = {}
local rt = {
    stack = {}, timers = {}, streams = {}, readers = {},
    dirty = true, running = false, next_timer_id = 1,
}
ui.rt = rt

-- Layout helpers -----------------------------------------------------------------
function ui.dp(n) return floor(n * rt.S + 0.5) end
local dp = ui.dp

function ui.font(fam, px) return font.get(fam, px * rt.S) end

function ui.init(root_dir)
    rt.root = root_dir
    font.init(root_dir .. "/assets")
    rt.surface = display.init()
    rt.W, rt.H = display.w, display.h
    rt.S = display.scale
    ui.M = dp(36)            -- outer margin
    ui.HEADER_H = dp(118)
    ui.BTN_H = dp(108)
    ui.R = dp(16)            -- corner radius
    ui.BORDER = math.max(2, dp(3))
    return rt.surface
end

-- Screen stack ---------------------------------------------------------------------
function ui.push(screen)
    local top = rt.stack[#rt.stack]
    if top and top.pause then top:pause() end
    rt.stack[#rt.stack + 1] = screen
    if screen.enter then ui.safe(screen.enter, screen) end
    rt.flash_next = not screen.overlay
    rt.dirty = true
end

function ui.pop(screen)
    local top = rt.stack[#rt.stack]
    if screen and top ~= screen then
        -- remove a specific screen (e.g. a dialog already replaced)
        for i = #rt.stack, 1, -1 do
            if rt.stack[i] == screen then
                table.remove(rt.stack, i)
                if screen.leave then ui.safe(screen.leave, screen) end
                break
            end
        end
        rt.dirty = true
        return
    end
    table.remove(rt.stack)
    if top and top.leave then ui.safe(top.leave, top) end
    local now_top = rt.stack[#rt.stack]
    if not now_top then
        rt.running = false
        return
    end
    if now_top.resume then ui.safe(now_top.resume, now_top) end
    rt.flash_next = top and not top.overlay
    rt.dirty = true
end

function ui.replace(screen)
    local top = table.remove(rt.stack)
    if top and top.leave then ui.safe(top.leave, top) end
    rt.stack[#rt.stack + 1] = screen
    if screen.enter then ui.safe(screen.enter, screen) end
    rt.flash_next = true
    rt.dirty = true
end

function ui.top() return rt.stack[#rt.stack] end

-- Leave the current app: back to the launcher, or exit if started directly.
function ui.back_to_root()
    local base = rt.app_base or 0
    while #rt.stack > base do
        local top = table.remove(rt.stack)
        if top.leave then ui.safe(top.leave, top) end
    end
    if #rt.stack == 0 then
        rt.running = false
        return
    end
    local t = rt.stack[#rt.stack]
    if t.resume then ui.safe(t.resume, t) end
    rt.flash_next = true
    rt.dirty = true
end

function ui.quit()
    rt.running = false
end

function ui.redraw(flash)
    rt.dirty = true
    rt.loud = true
    if flash then rt.flash_next = true end
end

-- Redraw for small automatic updates (ticking clocks) that shouldn't count
-- toward the periodic ghost-clearing flash.
function ui.redraw_quiet()
    rt.dirty = true
    rt.quiet = true
end

-- Timers ---------------------------------------------------------------------------
function ui.after(ms, fn, owner)
    local id = rt.next_timer_id
    rt.next_timer_id = id + 1
    rt.timers[id] = { at = sys.now() + ms, fn = fn, owner = owner }
    return id
end

function ui.every(ms, fn, owner)
    local id = rt.next_timer_id
    rt.next_timer_id = id + 1
    rt.timers[id] = { at = sys.now() + ms, fn = fn, every = ms, owner = owner }
    return id
end

function ui.cancel(id)
    if id then rt.timers[id] = nil end
end

function ui.cancel_owner(owner)
    for id, t in pairs(rt.timers) do
        if t.owner == owner then rt.timers[id] = nil end
    end
end

-- Network streams that the main loop pumps
function ui.add_stream(s) rt.streams[s] = true end
function ui.remove_stream(s) rt.streams[s] = nil end

-- Errors ---------------------------------------------------------------------------
local function log_line(msg)
    local f = io.open(rt.root .. "/data/log.txt", "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S "), msg, "\n")
        f:close()
    end
end
ui.log = log_line

function ui.safe(fn, ...)
    local args = { ... }
    local ok, err = xpcall(function() return fn(unpack(args)) end, debug.traceback)
    if not ok then
        log_line(tostring(err))
        rt.errors = (rt.errors or 0) + 1
        io.stderr:write(tostring(err), "\n")
        local msg = tostring(err):match("^[^\n]*") or "error"
        ui.alert("Something went wrong", msg:gsub("^.-:%d+: ", ""))
    end
    return ok
end

-- Rendering --------------------------------------------------------------------------
local Ctx = {}
Ctx.__index = Ctx

local function new_ctx(active)
    return setmetatable({ s = rt.surface, hits = {}, active = active, W = rt.W, H = rt.H }, Ctx)
end

function Ctx:hit(x, y, w, h, on_tap, on_hold, data)
    if not self.active then return end
    self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, on_tap = on_tap, on_hold = on_hold, data = data }
end

function Ctx:text(x, y, str, opts)
    opts = opts or {}
    local f = opts.font or ui.font("sans", 34)
    local c = opts.color or BLACK
    str = tostring(str)
    if opts.w and opts.ellipsize ~= false then str = f:ellipsize(str, opts.w) end
    local tw = f:width(str)
    if opts.align == "center" and opts.w then x = x + (opts.w - tw) / 2
    elseif opts.align == "right" then
        if opts.w then x = x + opts.w - tw else x = x - tw end
    end
    f:draw_top(self.s, x, y, str, c)
    return tw, f.height
end

-- Wrapped paragraph. Returns height used.
function Ctx:paragraph(x, y, w, str, opts)
    opts = opts or {}
    local f = opts.font or ui.font("sans", 32)
    local lh = opts.line_height or f.line_height
    local lines = f:wrap(str, w)
    local maxl = opts.max_lines or #lines
    for i = 1, min(#lines, maxl) do
        local line = lines[i]
        if i == maxl and #lines > maxl then line = f:ellipsize(line .. " …", w) end
        local lx = x
        if opts.align == "center" then lx = x + (w - f:width(line)) / 2 end
        f:draw_top(self.s, lx, y + (i - 1) * lh, line, opts.color or BLACK)
    end
    return min(#lines, maxl) * lh
end

-- style: "outline" (default), "solid", "flat", "light", "disabled"
function Ctx:button(x, y, w, h, label, on_tap, opts)
    opts = opts or {}
    local s = self.s
    local style = opts.style or "outline"
    if opts.selected then style = "solid" end
    local r = opts.radius or ui.R
    local fg = BLACK
    if style == "solid" then
        s:fill_round_rect(x, y, w, h, r, BLACK)
        fg = WHITE
    elseif style == "light" then
        s:fill_round_rect(x, y, w, h, r, PALE)
        s:round_rect(x, y, w, h, r, BLACK, ui.BORDER)
    elseif style == "outline" then
        s:fill_round_rect(x, y, w, h, r, WHITE)
        s:round_rect(x, y, w, h, r, BLACK, ui.BORDER)
    elseif style == "disabled" then
        s:round_rect(x, y, w, h, r, LIGHT, ui.BORDER)
        fg = MID
    end
    if label and label ~= "" then
        local f = opts.font or ui.font(opts.bold == false and "sans" or "bold", opts.size or 36)
        local lbl = f:ellipsize(label, w - dp(16))
        if opts.align == "left" then
            local ty = y + (h - f.height) / 2 + f.ascent
            f:draw(s, x + dp(28), ty, lbl, fg)
        else
            f:draw_center(s, x, y, w, h, lbl, fg)
        end
    end
    if on_tap and style ~= "disabled" then self:hit(x, y, w, h, on_tap, opts.on_hold, { label = label }) end
end

-- A row of equal-width buttons.
function Ctx:button_row(x, y, w, h, items, opts)
    opts = opts or {}
    local gap = opts.gap or dp(16)
    local n = #items
    local bw = (w - gap * (n - 1)) / n
    for i, it in ipairs(items) do
        local bx = floor(x + (i - 1) * (bw + gap))
        self:button(bx, y, floor(bw), h, it[1], it[2], it[3] or opts)
    end
end

-- Segmented selector: options = {"A","B",...}, sel index
function Ctx:segmented(x, y, w, h, options, sel, on_pick, opts)
    opts = opts or {}
    local n = #options
    local s = self.s
    local f = opts.font or ui.font("bold", opts.size or 32)
    s:fill_round_rect(x, y, w, h, ui.R, WHITE)
    local cw = w / n
    for i, o in ipairs(options) do
        local cx = floor(x + (i - 1) * cw)
        local cwi = floor(x + i * cw) - cx
        if i == sel then
            s:fill_round_rect(cx, y, cwi, h, ui.R, BLACK)
            f:draw_center(s, cx, y, cwi, h, f:ellipsize(o, cwi - dp(8)), WHITE)
        else
            f:draw_center(s, cx, y, cwi, h, f:ellipsize(o, cwi - dp(8)), BLACK)
            if i > 1 and i - 1 ~= sel then s:fill_rect(cx, y + dp(16), ui.BORDER, h - dp(32), LIGHT) end
        end
        self:hit(cx, y, cwi, h, function() on_pick(i) end, nil, { label = o })
    end
    s:round_rect(x, y, w, h, ui.R, BLACK, ui.BORDER)
end

-- Label with  [−]  value  [+]  controls.
function Ctx:stepper(x, y, w, h, label, value, on_minus, on_plus, opts)
    opts = opts or {}
    local f = ui.font("sans", 34)
    local bw = h
    self:text(x, y + (h - f.height) / 2, label, { font = f, w = w - bw * 2 - dp(170) })
    local vx = x + w - bw * 2 - dp(150)
    self:button(vx, y, bw, h, "−", on_minus, { size = 48 })
    ui.font("bold", 40):draw_center(self.s, vx + bw, y, dp(150), h, tostring(value), BLACK)
    self:button(vx + bw + dp(150), y, bw, h, "+", on_plus, { size = 48 })
end

function Ctx:toggle(x, y, w, h, label, value, on_change)
    local f = ui.font("sans", 34)
    self:text(x, y + (h - f.height) / 2, label, { font = f, w = w - dp(200) })
    local tw, th = dp(150), dp(72)
    local tx, ty = x + w - tw, y + (h - th) / 2
    local s = self.s
    if value then
        s:fill_round_rect(tx, ty, tw, th, th / 2, BLACK)
        s:fill_circle(tx + tw - th / 2, ty + th / 2, th / 2 - dp(8), WHITE)
    else
        s:fill_round_rect(tx, ty, tw, th, th / 2, WHITE)
        s:round_rect(tx, ty, tw, th, th / 2, BLACK, ui.BORDER)
        s:fill_circle(tx + th / 2, ty + th / 2, th / 2 - dp(10), BLACK)
    end
    self:hit(x, y, w, h, function() on_change(not value) end, nil, { label = label })
end

-- Title bar. opts.back: function (default pops) or false; opts.right: {label, fn}
function Ctx:header(title, opts)
    opts = opts or {}
    local s, H = self.s, ui.HEADER_H
    local f = ui.font("bold", 40)
    local side = dp(150)
    if opts.back ~= false then
        local fn = opts.back
        if type(fn) ~= "function" then fn = function() ui.back() end end
        local af = ui.font("bold", 56)
        af:draw_center_ink(s, 0, 0, side, H, opts.back_label or "‹", BLACK)
        self:hit(0, 0, side + dp(40), H, fn, nil, { label = "back" })
    end
    if opts.right then
        local items = opts.right
        if type(items[1]) == "string" then items = { items } end
        local rx = self.W - dp(12)
        for i = #items, 1, -1 do
            local it = items[i]
            local rf = ui.font(it.font or "bold", it.size or 34)
            local w = math.max(dp(110), rf:width(it[1]) + dp(48))
            rx = rx - w
            rf:draw_center_ink(s, rx, 0, w, H, it[1], BLACK)
            if it[2] then self:hit(rx, 0, w, H, it[2], nil, { label = it[1] }) end
        end
        side = math.max(side, self.W - rx)
    end
    local t = f:ellipsize(title or "", self.W - 2 * side)
    f:draw_center(s, 0, 0, self.W, H, t, BLACK)
    s:fill_rect(0, H - ui.BORDER, self.W, ui.BORDER, BLACK)
    return H
end

-- Simple paginated list. state = table kept by the screen ({page=1}).
-- items: {title=, subtitle=, right=, on_tap=, on_hold=, bold=}
function Ctx:list(x, y, w, h, items, state, opts)
    opts = opts or {}
    local row_h = opts.row_h or dp(132)
    local nav_h = dp(100)
    local per = math.max(1, floor((h - nav_h) / row_h))
    local pages = math.max(1, math.ceil(#items / per))
    state.page = math.max(1, math.min(state.page or 1, pages))
    local s = self.s
    local tf = opts.title_font or ui.font("sans", 36)
    local sf = opts.sub_font or ui.font("sans", 26)
    local first = (state.page - 1) * per + 1
    for i = first, math.min(#items, first + per - 1) do
        local it = items[i]
        local ry = y + (i - first) * row_h
        local rw = w
        if it.right then
            local rf = ui.font("sans", 28)
            local rwid = rf:width(it.right)
            rf:draw_top(s, x + w - rwid - dp(10), ry + (row_h - rf.height) / 2, it.right, DARK)
            rw = w - rwid - dp(30)
        end
        local f = it.bold and ui.font("bold", 36) or tf
        if it.subtitle and it.subtitle ~= "" then
            f:draw_top(s, x + dp(10), ry + dp(18), f:ellipsize(it.title or "", rw - dp(10)), BLACK)
            sf:draw_top(s, x + dp(10), ry + dp(18) + f.height + dp(8), sf:ellipsize(it.subtitle, rw - dp(10)), DARK)
        else
            f:draw_top(s, x + dp(10), ry + (row_h - f.height) / 2, f:ellipsize(it.title or "", rw - dp(10)), BLACK)
        end
        if i < first + per - 1 and i < #items then
            s:fill_rect(x, ry + row_h - 1, w, max(1, dp(2)), LIGHT)
        end
        if it.on_tap or it.on_hold then
            self:hit(x, ry, w, row_h, it.on_tap, it.on_hold, it)
        end
    end
    if #items == 0 and opts.empty then
        local ef = ui.font("sans", 32)
        self:paragraph(x + dp(20), y + dp(40), w - dp(40), opts.empty, { font = ef, color = DARK, align = "center" })
    end
    if pages > 1 then
        local ny = y + h - nav_h + dp(8)
        local bw = dp(220)
        self:button(x, ny, bw, nav_h - dp(16), "‹ Prev", state.page > 1 and function()
            state.page = state.page - 1; ui.redraw()
        end or nil, { style = state.page > 1 and "outline" or "disabled", size = 32 })
        self:button(x + w - bw, ny, bw, nav_h - dp(16), "Next ›", state.page < pages and function()
            state.page = state.page + 1; ui.redraw()
        end or nil, { style = state.page < pages and "outline" or "disabled", size = 32 })
        ui.font("sans", 30):draw_center(s, x + bw, ny, w - 2 * bw, nav_h - dp(16),
            string.format("%d / %d", state.page, pages), DARK)
    end
    return pages
end

local function render_all()
    local s = rt.surface
    s:fill(WHITE)
    s.clips = {}
    s.cx0, s.cy0, s.cx1, s.cy1 = 0, 0, s.w, s.h
    -- find the bottom-most screen we need to draw (skip under full screens)
    local first = #rt.stack
    while first > 1 and rt.stack[first].overlay do first = first - 1 end
    local ctx
    for i = first, #rt.stack do
        local scr = rt.stack[i]
        ctx = new_ctx(i == #rt.stack)
        if scr.render then
            local ok, err = xpcall(function() scr:render(ctx) end, debug.traceback)
            if not ok then
                log_line(err)
                io.stderr:write(err, "\n")
                local ef = ui.font("sans", 26)
                ctx:paragraph(dp(20), dp(200), rt.W - dp(40), "Render error: " .. tostring(err), { font = ef })
            end
        end
    end
    rt.hits = ctx and ctx.hits or {}
    if rt.toast_msg then
        local f = ui.font("sans", 32)
        local lines = f:wrap(rt.toast_msg, rt.W - dp(160))
        local h = #lines * f.line_height + dp(40)
        local y = rt.H - h - dp(60)
        s:fill_round_rect(dp(50), y, rt.W - dp(100), h, ui.R, BLACK)
        for i, l in ipairs(lines) do
            f:draw_top(s, (rt.W - f:width(l)) / 2, y + dp(20) + (i - 1) * f.line_height, l, WHITE)
        end
    end
end

function ui.render_now(opts)
    render_all()
    local quiet = rt.quiet and not rt.loud
    display.flush({ flash = (opts and opts.flash) or rt.flash_next, full = opts and opts.full, quiet = quiet })
    rt.flash_next = false
    rt.dirty = false
    rt.quiet, rt.loud = false, false
end

-- Show a centered "working…" box right away (before a blocking call).
function ui.busy(msg)
    local s = rt.surface
    local f = ui.font("bold", 36)
    local w = math.min(rt.W - dp(100), f:width(msg) + dp(120))
    local h = dp(150)
    local x, y = (rt.W - w) / 2, (rt.H - h) / 2
    s:fill_round_rect(x - dp(6), y - dp(6), w + dp(12), h + dp(12), ui.R + dp(4), WHITE)
    s:fill_round_rect(x, y, w, h, ui.R, BLACK)
    f:draw_center(s, x, y, w, h, msg, WHITE)
    display.flush({})
    rt.dirty = true
end

function ui.toast(msg, ms)
    rt.toast_msg = msg
    rt.dirty = true
    if rt.toast_timer then ui.cancel(rt.toast_timer) end
    rt.toast_timer = ui.after(ms or 2500, function()
        rt.toast_msg = nil
        rt.toast_timer = nil
        rt.dirty = true
    end)
end

-- Event dispatch --------------------------------------------------------------------
local function inside(h, x, y)
    return x >= h.x and y >= h.y and x < h.x + h.w and y < h.y + h.h
end

local function dispatch(ev)
    local top = rt.stack[#rt.stack]
    if not top then return end
    if ev.type == "tap" or ev.type == "hold" then
        if rt.toast_msg and ev.type == "tap" then
            rt.toast_msg = nil
            rt.dirty = true
        end
        local hits = rt.hits or {}
        for i = #hits, 1, -1 do
            local h = hits[i]
            if inside(h, ev.x, ev.y) then
                local fn = (ev.type == "hold" and h.on_hold) or h.on_tap
                if fn then
                    ui.safe(fn, ev, h.data)
                    rt.dirty = true
                    return
                end
            end
        end
        local handler = ev.type == "hold" and (top.on_hold or top.on_tap) or top.on_tap
        if handler then ui.safe(handler, top, ev) end
        if top.overlay and top.dismiss_outside and ev.type == "tap" then ui.pop(top) end
    elseif ev.type == "swipe" then
        if top.on_swipe then ui.safe(top.on_swipe, top, ev) end
    end
end
ui.dispatch = dispatch

function ui.back()
    local top = rt.stack[#rt.stack]
    if top and top.on_back then
        if top:on_back() ~= false then return end
        return
    end
    ui.pop()
end

-- Main loop ----------------------------------------------------------------------------
function ui.run(opts)
    opts = opts or {}
    rt.running = true
    local power = kindle.power_watcher()
    local asleep = false
    local script = opts.script
    local script_i = 1
    while rt.running and #rt.stack > 0 do
        local now = sys.now()
        if rt.dirty and not asleep then ui.render_now() end
        -- next deadline
        local timeout = 1000
        for _, t in pairs(rt.timers) do timeout = min(timeout, max(0, t.at - now)) end
        if input.pressed() then timeout = min(timeout, 50) end
        if next(rt.streams) then timeout = min(timeout, 200) end
        local fds = {}
        for _, fd in ipairs(input.fds) do fds[#fds + 1] = fd end
        if power and power.fp then fds[#fds + 1] = power.fd end
        for st in pairs(rt.streams) do
            local fd = st:getfd()
            if fd then fds[#fds + 1] = fd end
        end
        if script then
            timeout = min(timeout, 10)
        end
        local ready = sys.poll(fds, timeout)
        input.read()
        input.update(sys.now())
        -- Power button / screensaver
        if power then
            for _, line in ipairs(power:read_lines()) do
                if line:find("goingToScreenSaver") then
                    asleep = true
                    input.grab(false)
                    for _, scr in ipairs(rt.stack) do if scr.on_sleep then ui.safe(scr.on_sleep, scr) end end
                elseif line:find("outOfScreenSaver") or line:find("exitingScreenSaver") then
                    if asleep then
                        asleep = false
                        sys.sleep_ms(400)
                        input.grab(true)
                        display.invalidate()
                        rt.dirty = true
                        rt.flash_next = true
                        for _, scr in ipairs(rt.stack) do if scr.on_wake then ui.safe(scr.on_wake, scr) end end
                    end
                end
            end
        end
        -- Streams
        for st in pairs(rt.streams) do
            if st.closed then rt.streams[st] = nil else
                local ok, err = pcall(st.pump, st)
                if not ok then
                    log_line("stream error: " .. tostring(err))
                    pcall(st.close, st, "error")
                    rt.streams[st] = nil
                end
            end
        end
        -- Timers
        now = sys.now()
        local due = {}
        for id, t in pairs(rt.timers) do
            if t.at <= now then due[#due + 1] = { id, t } end
        end
        table.sort(due, function(a, b) return a[2].at < b[2].at end)
        for _, d in ipairs(due) do
            local id, t = d[1], d[2]
            if rt.timers[id] == t then
                if t.every then t.at = now + t.every else rt.timers[id] = nil end
                ui.safe(t.fn)
            end
        end
        -- Ticks
        local top = rt.stack[#rt.stack]
        if top and top.tick then ui.safe(top.tick, top, now) end
        -- Input
        while true do
            local ev = input.pop()
            if not ev then break end
            if not asleep then
                dispatch(ev)
                rt.dirty = true
            end
        end
        -- Simulator script
        if script and #input.queue == 0 and not rt.dirty then
            local step = script[script_i]
            if not step then break end
            if type(step) == "table" and step[1] == "wait_until" then
                step.deadline = step.deadline or (sys.now() + step[3])
                local ok, res = pcall(step[2])
                if ok and res then
                    script_i = script_i + 1
                elseif sys.now() > step.deadline then
                    rt.sim_failed = "wait_until timed out at step " .. script_i
                    io.stderr:write(rt.sim_failed, "\n")
                    break
                end
            else
                script_i = script_i + 1
                if type(step) == "function" then
                    local ok, err = xpcall(step, debug.traceback)
                    if not ok then
                        rt.sim_failed = tostring(err)
                        io.stderr:write("SCRIPT ERROR: ", rt.sim_failed, "\n")
                        break
                    end
                elseif step[1] == "wait" then sys.sleep_ms(step[2])
                else input.inject({ type = step[1], x = step[2], y = step[3], dir = step[4] }) end
            end
        end
    end
    for _, scr in ipairs(rt.stack) do
        if scr.leave then pcall(scr.leave, scr) end
    end
    rt.stack = {}
    for st in pairs(rt.streams) do pcall(st.close, st, "quit") end
    kindle.prevent_screensaver(false)
end

-- Dialogs -------------------------------------------------------------------------------

-- Modal box with a message and buttons {{label, fn}, ...}
function ui.alert(title, msg, buttons)
    buttons = buttons or { { "OK" } }
    local dlg = { overlay = true }
    function dlg:render(ctx)
        local s = ctx.s
        local w = rt.W - dp(120)
        local mf = ui.font("sans", 34)
        local tf = ui.font("bold", 40)
        local lines = mf:wrap(msg or "", w - dp(80))
        local nl = math.min(#lines, 14)
        local h = dp(60) + (title and (tf.height + dp(30)) or 0) + nl * mf.line_height + dp(50) + ui.BTN_H + dp(40)
        local x, y = dp(60), floor((rt.H - h) / 2)
        s:fill_round_rect(x - dp(8), y - dp(8), w + dp(16), h + dp(16), ui.R + dp(6), WHITE)
        s:fill_round_rect(x, y, w, h, ui.R, WHITE)
        s:round_rect(x, y, w, h, ui.R, BLACK, dp(5))
        local cy = y + dp(50)
        if title then
            tf:draw_top(s, x + (w - tf:width(tf:ellipsize(title, w - dp(80)))) / 2, cy, tf:ellipsize(title, w - dp(80)), BLACK)
            cy = cy + tf.height + dp(30)
        end
        for i = 1, nl do
            local l = lines[i]
            mf:draw_top(s, x + (w - mf:width(l)) / 2, cy, l, BLACK)
            cy = cy + mf.line_height
        end
        cy = cy + dp(40)
        local items = {}
        for i, b in ipairs(buttons) do
            items[i] = { b[1], function()
                ui.pop(dlg)
                if b[2] then b[2]() end
            end, { style = (i == #buttons) and "solid" or "outline" } }
        end
        ctx:button_row(x + dp(40), cy, w - dp(80), ui.BTN_H, items)
    end
    ui.push(dlg)
    return dlg
end

function ui.confirm(title, msg, yes_label, on_yes, no_label)
    return ui.alert(title, msg, { { no_label or "Cancel" }, { yes_label or "OK", on_yes } })
end

-- Full-screen list picker. options: list of strings or {title, subtitle, value}
function ui.choose(title, options, on_pick, opts)
    opts = opts or {}
    local scr = { state = { page = 1 } }
    if opts.selected then
        local per = 8
        scr.state.page = math.floor((opts.selected - 1) / per) + 1
    end
    function scr:render(ctx)
        local top = ctx:header(title)
        local items = {}
        for i, o in ipairs(options) do
            local it = type(o) == "table" and o or { title = o }
            items[i] = {
                title = (opts.selected == i and "✓ " or "") .. (it.title or tostring(it[1])),
                subtitle = it.subtitle, right = it.right, bold = opts.selected == i,
                on_tap = function()
                    ui.pop(scr)
                    on_pick(i, it)
                end,
            }
        end
        ctx:list(ui.M, top + dp(10), rt.W - 2 * ui.M, rt.H - top - dp(30), items, self.state,
            { row_h = opts.row_h or dp(124), empty = opts.empty })
    end
    ui.push(scr)
    return scr
end

return ui
