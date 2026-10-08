-- Chessboard widget: drawing, hit-testing and tap-to-move selection.
local ffi = require("ffi")
local ui = require("core.ui")
local gfx = require("core.gfx")
local sys = require("core.sys")
local chess = require("apps.lib.chess")

local dp = ui.dp
local BLACK, WHITE = gfx.BLACK, gfx.WHITE
local LIGHT_SQ, DARK_SQ = 0xF0, 0xB4
local LIGHT_HI, DARK_HI = 0xC8, 0x8C

local board = {}

-- Piece sprites -----------------------------------------------------------------------
local master = nil
local scaled = {}
local ORDER = { "wK", "wQ", "wR", "wB", "wN", "wP", "bK", "bQ", "bR", "bB", "bN", "bP" }
local CODE_INDEX = { [6] = 1, [5] = 2, [4] = 3, [3] = 4, [2] = 5, [1] = 6 }

local function load_master()
    if master then return master end
    local data = sys.read_file(ui.rt.root .. "/assets/pieces/cburnett.epc")
    assert(data and data:sub(1, 4) == "EPC1", "missing piece sprites")
    local p = ffi.cast("const uint8_t*", data)
    local size = p[4] + p[5] * 256
    master = { data = data, ptr = p, size = size }
    return master
end

local function sprites(size)
    if scaled[size] then return scaled[size] end
    local m = load_master()
    local set = {}
    local stride = m.size * m.size * 2
    for i = 1, 12 do
        local src = m.ptr + 6 + (i - 1) * stride
        set[i] = gfx.scale_ga(src, m.size, size)
    end
    scaled[size] = set
    return set
end

-- piece code (+/-1..6) -> sprite
local function sprite_for(set, v)
    local idx = CODE_INDEX[math.abs(v)]
    if v < 0 then idx = idx + 6 end
    return set[idx]
end

function board.draw_piece(s, v, x, y, size)
    local set = sprites(size)
    s:blit_ga(sprite_for(set, v), size, size, x, y)
end

-- Board -------------------------------------------------------------------------------
local Board = {}
Board.__index = Board

function board.new(opts)
    opts = opts or {}
    return setmetatable({
        flipped = opts.flipped or false,
        selected = nil, targets = {}, last = nil,
        on_move = opts.on_move,          -- fn(move) called with a legal move
        can_move = opts.can_move,        -- fn() -> bool, whether the user may move now
        coords = opts.coords ~= false,
    }, Board)
end

function Board:square_xy(sq, x, y, size)
    local cs = size / 8
    local f, r = chess.file_of(sq), chess.rank_of(sq)
    local col = self.flipped and (7 - f) or f
    local row = self.flipped and r or (7 - r)
    return math.floor(x + col * cs), math.floor(y + row * cs), math.floor(x + (col + 1) * cs) - math.floor(x + col * cs)
end

function Board:square_at(px, py, x, y, size)
    local cs = size / 8
    local col, row = math.floor((px - x) / cs), math.floor((py - y) / cs)
    if col < 0 or col > 7 or row < 0 or row > 7 then return nil end
    local f = self.flipped and (7 - col) or col
    local r = self.flipped and row or (7 - row)
    return r * 8 + f
end

-- Draw the board for position pos at (x, y), side length size.
function Board:draw(ctx, pos, x, y, size)
    local s = ctx.s
    local cs = math.floor(size / 8)
    size = cs * 8
    self.geom = { x = x, y = y, size = size }
    local set = sprites(cs)
    local hi = {}
    if self.last then hi[self.last.from] = true; hi[self.last.to] = true end
    local check_sq = nil
    if pos:in_check() then check_sq = pos:king_sq(pos.turn) end
    local cf = ui.font("bold", 22)
    for sq = 0, 63 do
        local sx, sy, w = self:square_xy(sq, x, y, size)
        local light = (chess.file_of(sq) + chess.rank_of(sq)) % 2 == 1
        local col = light and LIGHT_SQ or DARK_SQ
        if hi[sq] then col = light and LIGHT_HI or DARK_HI end
        s:fill_rect(sx, sy, w, w, col)
        if check_sq == sq then
            s:circle(sx + w / 2, sy + w / 2, w / 2 - dp(4), BLACK, dp(6))
        end
        local v = pos.b[sq]
        if v ~= 0 then
            s:blit_ga(sprite_for(set, v), cs, cs, sx, sy)
        end
        if self.selected == sq then
            s:rect(sx, sy, w, w, BLACK, math.max(4, dp(7)))
        end
        if self.targets[sq] then
            if v ~= 0 then
                -- capture: corner triangles
                local t = w * 0.28
                s:fill_polygon({ { sx, sy }, { sx + t, sy }, { sx, sy + t } }, BLACK)
                s:fill_polygon({ { sx + w, sy }, { sx + w - t, sy }, { sx + w, sy + t } }, BLACK)
                s:fill_polygon({ { sx, sy + w }, { sx + t, sy + w }, { sx, sy + w - t } }, BLACK)
                s:fill_polygon({ { sx + w, sy + w }, { sx + w - t, sy + w }, { sx + w, sy + w - t } }, BLACK)
            else
                s:fill_circle(sx + w / 2, sy + w / 2, w * 0.15, BLACK)
                s:fill_circle(sx + w / 2, sy + w / 2, w * 0.15 - dp(5), WHITE)
                s:fill_circle(sx + w / 2, sy + w / 2, w * 0.07, BLACK)
            end
        end
        if self.coords then
            local f, r = chess.file_of(sq), chess.rank_of(sq)
            local bottom_row, left_col
            if self.flipped then bottom_row, left_col = (r == 7), (f == 7)
            else bottom_row, left_col = (r == 0), (f == 0) end
            local tc = light and DARK_SQ - 0x50 or 0xFF
            if bottom_row then cf:draw(s, sx + w - cf:width(string.char(97 + f)) - dp(4), sy + w - dp(6), string.char(97 + f), tc) end
            if left_col then cf:draw_top(s, sx + dp(4), sy + dp(2), tostring(r + 1), tc) end
        end
    end
    s:rect(x - dp(3), y - dp(3), size + dp(6), size + dp(6), BLACK, dp(3))
    ctx:hit(x, y, size, size, function(ev) self:tap(pos, ev.x, ev.y) end)
end

function Board:clear_selection()
    self.selected = nil
    self.targets = {}
end

-- Handle a tap on the board.
function Board:tap(pos, px, py)
    local g = self.geom
    if not g then return end
    local sq = self:square_at(px, py, g.x, g.y, g.size)
    if not sq then return end
    if self.can_move and not self.can_move() then
        self:clear_selection()
        ui.redraw()
        return
    end
    local v = pos.b[sq]
    if self.selected and self.targets[sq] then
        local cands = self.targets[sq]
        self:clear_selection()
        if #cands > 1 then
            -- promotion: choose piece
            board.choose_promotion(pos.turn, function(promo)
                for _, m in ipairs(cands) do
                    if m.promo == promo then
                        if self.on_move then self.on_move(m) end
                        return
                    end
                end
            end)
        else
            if self.on_move then self.on_move(cands[1]) end
        end
    elseif v ~= 0 and (v > 0) == (pos.turn > 0) and self.selected ~= sq then
        self.selected = sq
        self.targets = {}
        for _, m in ipairs(pos:legal_from(sq)) do
            self.targets[m.to] = self.targets[m.to] or {}
            table.insert(self.targets[m.to], m)
        end
    else
        self:clear_selection()
    end
    ui.redraw()
end

-- Overlay asking which piece to promote to.
function board.choose_promotion(color, on_pick)
    local dlg = { overlay = true }
    function dlg:render(ctx)
        local s = ctx.s
        local cs = dp(200)
        local w, h = cs * 4 + dp(80), cs + dp(200)
        local x, y = (ctx.W - w) / 2, (ctx.H - h) / 2
        s:fill_round_rect(x, y, w, h, ui.R, WHITE)
        s:round_rect(x, y, w, h, ui.R, BLACK, dp(5))
        local tf = ui.font("bold", 36)
        tf:draw_center(s, x, y + dp(20), w, dp(70), "Promote to", BLACK)
        for i, p in ipairs({ chess.QUEEN, chess.ROOK, chess.BISHOP, chess.KNIGHT }) do
            local px, py = x + dp(40) + (i - 1) * cs, y + dp(110)
            s:round_rect(px + dp(6), py, cs - dp(12), cs, ui.R, BLACK, ui.BORDER)
            board.draw_piece(s, p * color, px + dp(16), py + dp(10), cs - dp(32))
            ctx:hit(px, py, cs, cs, function()
                ui.pop(dlg)
                on_pick(p)
            end)
        end
    end
    ui.push(dlg)
end

-- Captured material summary: returns list of piece codes captured by `color`
-- and the material balance from white's perspective.
function board.material(pos)
    local start = { [1] = 8, [2] = 2, [3] = 2, [4] = 2, [5] = 1 }
    local count = { [1] = {}, [-1] = {} }
    for i = 0, 63 do
        local v = pos.b[i]
        if v ~= 0 and math.abs(v) < 6 then
            local c = v > 0 and 1 or -1
            count[c][math.abs(v)] = (count[c][math.abs(v)] or 0) + 1
        end
    end
    local VAL = { 1, 3, 3, 5, 9 }
    local captured = { [1] = {}, [-1] = {} }   -- pieces of the opponent each side has taken
    local bal = 0
    for t = 5, 1, -1 do
        local wmiss = math.max(0, start[t] - (count[1][t] or 0))
        local bmiss = math.max(0, start[t] - (count[-1][t] or 0))
        for _ = 1, bmiss do table.insert(captured[1], -t) end
        for _ = 1, wmiss do table.insert(captured[-1], t) end
        bal = bal + ((count[1][t] or 0) - (count[-1][t] or 0)) * VAL[t]
    end
    return captured, bal
end

return board
