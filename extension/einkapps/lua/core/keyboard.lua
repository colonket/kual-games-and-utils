-- On-screen keyboard. ui keyboard{title=, text=, on_done=fn(text), hint=}
local ui = require("core.ui")
local sys = require("core.sys")
local gfx = require("core.gfx")

local dp = ui.dp
local BLACK, WHITE, PALE, DARK, LIGHT = gfx.BLACK, gfx.WHITE, gfx.PALE, gfx.DARK, gfx.LIGHT

local LAYOUTS = {
    lower = {
        { "q", "w", "e", "r", "t", "y", "u", "i", "o", "p" },
        { "a", "s", "d", "f", "g", "h", "j", "k", "l" },
        { "SHIFT", "z", "x", "c", "v", "b", "n", "m", "BKSP" },
        { "123", ",", "SPACE", ".", "DONE" },
    },
    num = {
        { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" },
        { "-", "/", ":", ";", "(", ")", "$", "&", "@", "\"" },
        { "SYM", "_", "#", "?", "!", "'", "%", "+", "BKSP" },
        { "ABC", ",", "SPACE", ".", "DONE" },
    },
    sym = {
        { "[", "]", "{", "}", "#", "%", "^", "*", "+", "=" },
        { "_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•" },
        { "123", "é", "è", "à", "ç", "ñ", "ü", "ö", "BKSP" },
        { "ABC", ",", "SPACE", ".", "DONE" },
    },
}

local WEIGHT = { SHIFT = 1.5, BKSP = 1.5, ["123"] = 1.5, ABC = 1.5, SYM = 1.5, SPACE = 5, DONE = 2 }
local LABEL = { SHIFT = "⇧", BKSP = "⌫", SPACE = "space", DONE = "Done", ["123"] = "123", ABC = "ABC", SYM = "#+=" }

local function keyboard(opts)
    local scr = { text = opts.text or "", mode = "lower", shift = false, caps = false }
    if opts.start_mode then scr.mode = opts.start_mode end

    local function finish()
        ui.pop(scr)
        if opts.on_done then opts.on_done(scr.text) end
    end

    local function press(k)
        if k == "SHIFT" then
            if scr.caps then scr.caps, scr.shift = false, false
            else scr.shift = not scr.shift end
        elseif k == "BKSP" then
            scr.text = sys.utf8_pop(scr.text)
        elseif k == "SPACE" then
            scr.text = scr.text .. " "
        elseif k == "DONE" then
            return finish()
        elseif k == "123" then scr.mode = "num"
        elseif k == "ABC" then scr.mode = "lower"
        elseif k == "SYM" then scr.mode = "sym"
        else
            if scr.mode == "lower" and (scr.shift or scr.caps) then k = k:upper() end
            if opts.max_len and sys.utf8_len(scr.text) >= opts.max_len then return end
            scr.text = scr.text .. k
            if scr.shift and not scr.caps then scr.shift = false end
        end
        ui.redraw()
    end

    function scr:render(ctx)
        local s = ctx.s
        local W, H = ctx.W, ctx.H
        local top = ctx:header(opts.title or "Type", {
            back = function() ui.pop(scr) if opts.on_cancel then opts.on_cancel() end end,
            back_label = "✕",
            right = { "Done", finish },
        })
        -- text field
        local f = ui.font(opts.mono and "sans" or "sans", 40)
        local fx, fy = ui.M, top + dp(36)
        local fw = W - 2 * ui.M
        local lines = f:wrap(self.text == "" and " " or self.text, fw - dp(48))
        local maxl = 5
        if #lines > maxl then
            local keep = {}
            for i = #lines - maxl + 1, #lines do keep[#keep + 1] = lines[i] end
            lines = keep
        end
        local fh = math.max(1, #lines) * f.line_height + dp(48)
        s:fill_round_rect(fx, fy, fw, fh, ui.R, WHITE)
        s:round_rect(fx, fy, fw, fh, ui.R, BLACK, ui.BORDER)
        for i, l in ipairs(lines) do
            f:draw_top(s, fx + dp(24), fy + dp(24) + (i - 1) * f.line_height, l, BLACK)
        end
        -- cursor after last line
        local last = lines[#lines] or ""
        local cx = fx + dp(24) + (self.text == "" and 0 or f:width(last)) + dp(4)
        local cy = fy + dp(24) + (#lines - 1) * f.line_height
        s:fill_rect(cx, cy, dp(4), f.height, BLACK)
        if self.text == "" and opts.hint then
            ui.font("sans", 32):draw_top(s, fx + dp(40), fy + dp(28), opts.hint, LIGHT)
        end
        local info_y = fy + fh + dp(16)
        if opts.help then
            ctx:paragraph(fx, info_y, fw, opts.help, { font = ui.font("sans", 28), color = DARK })
        end
        -- keys
        local layout = LAYOUTS[self.mode]
        local kh = dp(124)
        local gap = dp(10)
        local kb_top = H - #layout * (kh + gap) - dp(24)
        s:fill_rect(0, kb_top - dp(20), W, H - kb_top + dp(20), PALE)
        s:fill_rect(0, kb_top - dp(20), W, ui.BORDER, BLACK)
        local kf = ui.font("sans", 44)
        local sf = ui.font("bold", 32)
        for r, row in ipairs(layout) do
            local total = 0
            for _, k in ipairs(row) do total = total + (WEIGHT[k] or 1) end
            local unit = (W - dp(16) - gap * (#row - 1)) / math.max(total, 10)
            local roww = total * unit + gap * (#row - 1)
            local x = (W - roww) / 2
            local y = kb_top + (r - 1) * (kh + gap)
            for _, k in ipairs(row) do
                local kw = math.floor((WEIGHT[k] or 1) * unit)
                local label = LABEL[k] or k
                if self.mode == "lower" and not LABEL[k] and (self.shift or self.caps) then label = k:upper() end
                local solid = (k == "DONE") or (k == "SHIFT" and (self.shift or self.caps))
                s:fill_round_rect(x, y, kw, kh, dp(12), solid and BLACK or WHITE)
                s:round_rect(x, y, kw, kh, dp(12), BLACK, math.max(1, dp(2)))
                local lf = (#label > 1 and label ~= "⇧" and label ~= "⌫") and sf or kf
                lf:draw_center(s, x, y, kw, kh, label, solid and WHITE or BLACK)
                if k == "SHIFT" and self.caps then
                    s:fill_rect(x + kw / 2 - dp(20), y + kh - dp(22), dp(40), dp(6), WHITE)
                end
                local key = k
                ctx:hit(x, y, kw, kh, function() press(key) end,
                    key == "SHIFT" and function() scr.caps = true; scr.shift = true; ui.redraw() end
                    or (key == "BKSP" and function() scr.text = ""; ui.redraw() end) or nil, { label = key })
                x = x + kw + gap
            end
        end
    end
    ui.push(scr)
    return scr
end

return keyboard
