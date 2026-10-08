-- Offline chess (ported from CrossPoint Apps' ChessActivity, now with full
-- rules: castling, en passant, promotion, check/mate/draw detection) for
-- two players on one Kindle, or against a built-in engine.
local ui = require("core.ui")
local gfx = require("core.gfx")
local store = require("core.store")
local chess = require("apps.lib.chess")
local boardlib = require("apps.lib.board")

local dp = ui.dp
local BLACK, WHITE, DARK = gfx.BLACK, gfx.WHITE, gfx.DARK

local M = {}

function M.new()
    local saved = store.load("chess_local", { mode = "friend", level = 2, human = 1, moves = {} })
    local scr = { cfg = saved }

    local function save()
        local moves = {}
        for _, h in ipairs(scr.pos.history) do moves[#moves + 1] = h.uci end
        scr.cfg.moves = moves
        store.save("chess_local", scr.cfg)
    end

    local function rebuild(moves)
        scr.pos = chess.replay("startpos", table.concat(moves or {}, " "))
        local h = scr.pos.history[#scr.pos.history]
        scr.board.last = h and { from = h.from, to = h.to } or nil
        scr.board:clear_selection()
        scr.result = scr.pos:outcome()
    end

    local function engine_turn()
        return scr.cfg.mode == "computer" and scr.pos.turn ~= scr.cfg.human and not scr.result
    end

    local function engine_move()
        if not engine_turn() then return end
        ui.busy("Thinking…")
        local m = chess.best_move(scr.pos, scr.cfg.level)
        if m then
            scr.pos:play(m)
            scr.board.last = { from = m.from, to = m.to }
            scr.result = scr.pos:outcome()
            save()
        end
        ui.redraw()
    end

    scr.board = boardlib.new({
        can_move = function() return not scr.result and not engine_turn() end,
        on_move = function(m)
            scr.pos:play(m)
            scr.board.last = { from = m.from, to = m.to }
            scr.result = scr.pos:outcome()
            save()
            if engine_turn() then
                ui.render_now()
                engine_move()
            end
            ui.redraw()
        end,
    })
    rebuild(saved.moves)
    scr.board.flipped = (saved.mode == "computer" and saved.human == -1)

    local function new_game(mode, human)
        scr.cfg.mode, scr.cfg.human = mode, human or 1
        rebuild({})
        scr.board.flipped = (mode == "computer" and scr.cfg.human == -1)
        save()
        ui.redraw(true)
        if engine_turn() then ui.after(100, engine_move) end
    end

    function scr:enter()
        if engine_turn() then ui.after(200, engine_move) end
    end

    function scr:menu()
        ui.choose("New game", {
            { title = "Two players (pass & play)" },
            { title = "Play White vs computer" },
            { title = "Play Black vs computer" },
            { title = "Computer strength: " .. ({ "Easy", "Medium", "Hard", "Harder" })[self.cfg.level], subtitle = "Tap to change" },
        }, function(i)
            if i == 1 then new_game("friend")
            elseif i == 2 then new_game("computer", 1)
            elseif i == 3 then new_game("computer", -1)
            else
                ui.choose("Strength", { "Easy", "Medium", "Hard", "Harder (slow)" }, function(k)
                    self.cfg.level = k
                    save()
                end, { selected = self.cfg.level })
            end
        end)
    end

    function scr:render(ctx)
        local s = ctx.s
        local mode_txt = self.cfg.mode == "computer" and ("vs computer · " .. ({ "easy", "medium", "hard", "harder" })[self.cfg.level]) or "Two players"
        local top = ctx:header("Chess", { right = { "New", function() self:menu() end, size = 34 } })
        local W = ctx.W
        local reserved = dp(20) + ui.font("sans", 30).height + dp(14) + 2 * dp(56) + dp(14) + dp(100) + dp(134) + dp(10)
        local bsize = math.floor(math.min(W - dp(48), ctx.H - top - reserved) / 8) * 8
        local bx = math.floor((W - bsize) / 2)
        local y = top + dp(20)
        local f = ui.font("sans", 30)
        f:draw_top(s, bx, y, mode_txt, DARK)
        -- captured material
        local captured, bal = boardlib.material(self.pos)
        local function caps(list, x, yy, adv)
            local ps = dp(40)
            for k, v in ipairs(list) do boardlib.draw_piece(s, v, x + (k - 1) * (ps - dp(12)), yy, ps) end
            if adv > 0 then
                f:draw_top(s, x + #list * (ps - dp(12)) + dp(20), yy + dp(4), "+" .. adv, DARK)
            end
        end
        y = y + f.height + dp(14)
        local top_color = self.board.flipped and 1 or -1
        caps(captured[top_color], bx, y, top_color == 1 and bal or -bal)
        y = y + dp(56)
        self.board:draw(ctx, self.pos, bx, y, bsize)
        y = y + bsize + dp(14)
        caps(captured[-top_color], bx, y, -top_color == 1 and bal or -bal)
        y = y + dp(56)
        local status
        if self.result then
            status = (self.result.winner and ((self.result.winner == 1 and "White" or "Black") .. " wins") or "Draw")
                .. " · " .. self.result.reason
        else
            status = (self.pos.turn == 1 and "White" or "Black") .. " to move" .. (self.pos:in_check() and " — check!" or "")
        end
        ui.font("bold", 36):draw_top(s, bx, y, status, BLACK)
        local hist = self.pos.history
        if #hist > 0 then
            local parts = {}
            local start = math.max(1, #hist - 5)
            if start % 2 == 0 then start = start - 1 end
            for i = start, #hist do
                if i % 2 == 1 then parts[#parts + 1] = math.floor((i + 1) / 2) .. "." end
                parts[#parts + 1] = hist[i].san
            end
            f:draw_top(s, bx, y + dp(54), f:ellipsize(table.concat(parts, " "), bsize), DARK)
        end
        local by = ctx.H - dp(110) - dp(24)
        ctx:button_row(bx, by, bsize, dp(110), {
            { "Undo", #hist > 0 and function()
                local moves = {}
                local drop = (self.cfg.mode == "computer" and #hist >= 2 and self.pos.turn == self.cfg.human) and 2 or 1
                for k = 1, #hist - drop do moves[k] = hist[k].uci end
                rebuild(moves)
                save()
                ui.redraw()
            end or nil, { style = #hist > 0 and "outline" or "disabled", size = 34 } },
            { "Flip", function() self.board.flipped = not self.board.flipped; ui.redraw() end, { size = 34 } },
            { "New game", function() self:menu() end, { size = 34 } },
        })
    end
    return scr
end

return M
