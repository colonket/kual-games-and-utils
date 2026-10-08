-- Calculator (ported from CrossPoint Apps' CalculatorActivity, made touch-first).
local ui = require("core.ui")
local gfx = require("core.gfx")
local font = require("core.font")
local sys = require("core.sys")

local dp = ui.dp
local BLACK, WHITE, DARK, PALE = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.PALE

local M = {}

-- Recursive-descent evaluator: + − × ÷ ^ %, parentheses, unary minus.
local function evaluate(expr)
    local s = expr:gsub("×", "*"):gsub("÷", "/"):gsub("−", "-")
    local i = 1
    local function peek() return s:sub(i, i) end
    local function skip() while peek() == " " do i = i + 1 end end
    local parse_expr
    local function primary()
        skip()
        local c = peek()
        if c == "-" then i = i + 1; return -primary() end
        if c == "+" then i = i + 1; return primary() end
        if c == "(" then
            i = i + 1
            local v = parse_expr()
            skip()
            if peek() == ")" then i = i + 1 end
            return v
        end
        local num = s:match("^%d*%.?%d+", i) or s:match("^%d+%.?", i)
        if not num then error("syntax") end
        i = i + #num
        local v = tonumber(num)
        skip()
        if peek() == "%" then i = i + 1; v = v / 100 end
        return v
    end
    local function power()
        local b = primary()
        skip()
        if peek() == "^" then i = i + 1; return b ^ power() end
        return b
    end
    local function term()
        local v = power()
        while true do
            skip()
            local c = peek()
            if c == "*" then i = i + 1; v = v * power()
            elseif c == "/" then
                i = i + 1
                local d = power()
                if d == 0 then error("division by zero") end
                v = v / d
            elseif c == "(" then v = v * power()   -- implicit multiply: 2(3)
            else break end
        end
        return v
    end
    parse_expr = function()
        local v = term()
        while true do
            skip()
            local c = peek()
            if c == "+" then i = i + 1; v = v + term()
            elseif c == "-" then i = i + 1; v = v - term()
            else break end
        end
        return v
    end
    local ok, v = pcall(parse_expr)
    if not ok then return nil, (tostring(v):match("division by zero") and "Can't divide by 0" or "Error") end
    if i <= #s then return nil, "Error" end
    return v
end
M.evaluate = evaluate

local function fmt(v)
    if v ~= v then return "Error" end
    if v == math.huge or v == -math.huge then return "∞" end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    local s = string.format("%.10g", v)
    return s
end
M.fmt = fmt

local GRID = {
    { "C", "(", ")", "÷" },
    { "7", "8", "9", "×" },
    { "4", "5", "6", "−" },
    { "1", "2", "3", "+" },
    { "0", ".", "⌫", "=" },
}
local OPS = { ["+"] = true, ["−"] = true, ["×"] = true, ["÷"] = true }

function M.new()
    local scr = { expr = "", result = nil, history = {} }

    local function last_char(s)
        local out = ""
        for _, cp in sys.utf8_codes(s) do out = sys.utf8_char(cp) end
        return out
    end

    function scr:press(k)
        if k == "C" then
            self.expr, self.result = "", nil
        elseif k == "⌫" then
            if self.result then self.result = nil
            else self.expr = sys.utf8_pop(self.expr) end
        elseif k == "=" then
            if self.expr == "" then return end
            local v, err = evaluate(self.expr)
            self.result = v and fmt(v) or err
            if v then
                table.insert(self.history, 1, self.expr .. " = " .. self.result)
                if #self.history > 4 then table.remove(self.history) end
            end
        else
            if self.result then
                -- continue from the result with an operator, else start fresh
                if OPS[k] and self.result:match("^%-?[%d.e+]+$") then
                    self.expr = self.result:gsub("^%-", "−")
                else
                    self.expr = ""
                end
                self.result = nil
            end
            if OPS[k] then
                local lc = last_char(self.expr)
                if self.expr == "" and k ~= "−" then return end
                if OPS[lc] then self.expr = sys.utf8_pop(self.expr) end
            end
            self.expr = self.expr .. k
        end
        ui.redraw()
    end

    function scr:render(ctx)
        local s = ctx.s
        local top = ctx:header("Calculator")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(30)
        -- display
        local dh = dp(300)
        s:round_rect(x, y, w, dh, ui.R, BLACK, ui.BORDER)
        local hf = ui.font("sans", 26)
        local nh = ui.rt.S < 0.8 and 1 or 2
        for k = math.min(#self.history, nh), 1, -1 do
            local line = hf:ellipsize(self.history[k], w - dp(60))
            hf:draw_top(s, x + w - dp(30) - hf:width(line), y + dp(18) + (nh - k) * hf.line_height, line, DARK)
        end
        local ef = font.fit("sans", self.expr == "" and "0" or self.expr, w - dp(60), dh * 0.22, 56 * ui.rt.S)
        local et = self.expr == "" and "0" or self.expr
        if ef:width(et) > w - dp(60) then et = "…" .. et:sub(-24) end
        ef:draw_top(s, x + w - dp(30) - ef:width(et), y + dp(90), et, self.result and DARK or BLACK)
        if self.result then
            local rf = font.fit("bold", "= " .. self.result, w - dp(60), dh * 0.36, 96 * ui.rt.S)
            local rt = "= " .. self.result
            rf:draw_top(s, x + w - dp(30) - rf:width(rt), y + dh - rf.height - dp(20), rt, BLACK)
        end
        y = y + dh + dp(30)
        -- keypad
        local gap = dp(16)
        local rows, cols = #GRID, 4
        local kh = math.floor((ctx.H - y - dp(30) - gap * (rows - 1)) / rows)
        local kw = math.floor((w - gap * (cols - 1)) / cols)
        for r, row in ipairs(GRID) do
            for c, k in ipairs(row) do
                local kx, ky = x + (c - 1) * (kw + gap), y + (r - 1) * (kh + gap)
                local style = (k == "=") and "solid" or ((OPS[k] or k == "C") and "light" or "outline")
                ctx:button(kx, ky, kw, kh, k, function() self:press(k) end, { style = style, size = 56 })
            end
        end
    end
    return scr
end

return M
