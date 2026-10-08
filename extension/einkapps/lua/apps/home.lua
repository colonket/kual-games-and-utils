-- App launcher grid.
local ui = require("core.ui")
local gfx = require("core.gfx")
local kindle = require("core.kindle")
local registry = require("apps.registry")

local dp = ui.dp
local BLACK, WHITE, DARK, PALE = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.PALE

local M = {}

function M.new()
    local scr = {}

    function scr:enter()
        self.minute_timer = ui.every(60000, function() ui.redraw() end, self)
    end

    function scr:leave()
        ui.cancel_owner(self)
    end

    function scr:render(ctx)
        local s = ctx.s
        local W, H = ctx.W, ctx.H
        local bat = kindle.battery()
        local right = {}
        right[1] = { os.date("%H:%M") .. (bat and ("  " .. bat .. "%") or ""), nil, font = "sans", size = 30 }
        local top = ctx:header("Tabletop Apps", { back = function() ui.quit() end, back_label = "✕", right = right })
        local cols = 3
        local gap = dp(22)
        local n = #registry.apps
        local rows = math.ceil(n / cols)
        local gw = W - 2 * ui.M
        local tw = math.floor((gw - gap * (cols - 1)) / cols)
        local avail = H - top - dp(40)
        local th = math.min(math.floor((avail - gap * (rows - 1)) / rows), dp(290))
        local y0 = top + dp(24)
        local lf = ui.font("bold", 30)
        for i, app in ipairs(registry.apps) do
            local r, c = math.floor((i - 1) / cols), (i - 1) % cols
            local x = ui.M + c * (tw + gap)
            local y = y0 + r * (th + gap)
            s:fill_round_rect(x, y, tw, th, dp(24), WHITE)
            s:round_rect(x, y, tw, th, dp(24), BLACK, ui.BORDER)
            local isz = math.min(tw, th - lf.height - dp(30)) * 0.92
            app.icon(s, x + (tw - isz) / 2, y + dp(8), isz)
            local label = lf:ellipsize(app.title, tw - dp(20))
            lf:draw_top(s, x + (tw - lf:width(label)) / 2, y + th - lf.height - dp(22), label, BLACK)
            ctx:hit(x, y, tw, th, function() registry.open(app.id) end)
        end
    end

    return scr
end

return M
