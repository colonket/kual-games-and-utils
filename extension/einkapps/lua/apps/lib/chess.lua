-- Chess rules: legal move generation, FEN, UCI and SAN, game end detection,
-- plus a small alpha-beta engine for offline play.
--
-- Squares are 0..63 (a1 = 0, h1 = 7, a8 = 56). Pieces are integers:
-- 1 pawn, 2 knight, 3 bishop, 4 rook, 5 queen, 6 king; positive = white,
-- negative = black, 0 = empty.
local chess = {}

local PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING = 1, 2, 3, 4, 5, 6
chess.PAWN, chess.KNIGHT, chess.BISHOP, chess.ROOK, chess.QUEEN, chess.KING = PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING
local LETTER = { "P", "N", "B", "R", "Q", "K" }
local FROM_LETTER = { p = 1, n = 2, b = 3, r = 4, q = 5, k = 6 }
chess.START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

local function file_of(sq) return sq % 8 end
local function rank_of(sq) return math.floor(sq / 8) end
chess.file_of, chess.rank_of = file_of, rank_of

function chess.sq_name(sq)
    return string.char(97 + file_of(sq)) .. tostring(rank_of(sq) + 1)
end

function chess.sq_parse(s)
    local f, r = s:byte(1) - 97, tonumber(s:sub(2, 2))
    if not r or f < 0 or f > 7 or r < 1 or r > 8 then return nil end
    return (r - 1) * 8 + f
end

local KNIGHT_D = { { 1, 2 }, { 2, 1 }, { 2, -1 }, { 1, -2 }, { -1, -2 }, { -2, -1 }, { -2, 1 }, { -1, 2 } }
local KING_D = { { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 } }
local BISHOP_D = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local ROOK_D = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- Position ------------------------------------------------------------------------
local Pos = {}
Pos.__index = Pos
chess.Pos = Pos

function chess.from_fen(fen)
    fen = fen or chess.START_FEN
    if fen == "startpos" then fen = chess.START_FEN end
    local p = setmetatable({ b = {}, history = {} }, Pos)
    for i = 0, 63 do p.b[i] = 0 end
    local parts = {}
    for w in fen:gmatch("%S+") do parts[#parts + 1] = w end
    local rank, file = 7, 0
    for c in (parts[1] or ""):gmatch(".") do
        if c == "/" then rank, file = rank - 1, 0
        elseif c:match("%d") then file = file + tonumber(c)
        else
            local t = FROM_LETTER[c:lower()]
            if t and rank >= 0 and file < 8 then
                p.b[rank * 8 + file] = (c == c:upper()) and t or -t
            end
            file = file + 1
        end
    end
    p.turn = (parts[2] == "b") and -1 or 1
    local cr = parts[3] or "-"
    p.castle = { K = cr:find("K") ~= nil, Q = cr:find("Q") ~= nil, k = cr:find("k") ~= nil, q = cr:find("q") ~= nil }
    p.ep = (parts[4] and parts[4] ~= "-") and chess.sq_parse(parts[4]) or nil
    p.half = tonumber(parts[5] or "0") or 0
    p.full = tonumber(parts[6] or "1") or 1
    p.keys = { [p:key()] = 1 }
    return p
end

function Pos:copy()
    local q = setmetatable({ b = {}, history = {} }, Pos)
    for i = 0, 63 do q.b[i] = self.b[i] end
    q.turn, q.ep, q.half, q.full = self.turn, self.ep, self.half, self.full
    q.castle = { K = self.castle.K, Q = self.castle.Q, k = self.castle.k, q = self.castle.q }
    q.keys = {}
    for k, v in pairs(self.keys or {}) do q.keys[k] = v end
    for i, h in ipairs(self.history) do q.history[i] = h end
    return q
end

function Pos:fen()
    local rows = {}
    for r = 7, 0, -1 do
        local row, empty = "", 0
        for f = 0, 7 do
            local v = self.b[r * 8 + f]
            if v == 0 then empty = empty + 1
            else
                if empty > 0 then row = row .. empty; empty = 0 end
                local l = LETTER[math.abs(v)]
                row = row .. (v > 0 and l or l:lower())
            end
        end
        if empty > 0 then row = row .. empty end
        rows[#rows + 1] = row
    end
    local cr = (self.castle.K and "K" or "") .. (self.castle.Q and "Q" or "") .. (self.castle.k and "k" or "") .. (self.castle.q and "q" or "")
    return table.concat(rows, "/") .. " " .. (self.turn == 1 and "w" or "b") .. " " .. (cr == "" and "-" or cr) ..
        " " .. (self.ep and chess.sq_name(self.ep) or "-") .. " " .. self.half .. " " .. self.full
end

-- Repetition key: placement + side + castling + ep
function Pos:key()
    local t = {}
    for i = 0, 63 do t[#t + 1] = string.char(self.b[i] + 70) end
    return table.concat(t) .. self.turn .. (self.castle.K and "K" or "") .. (self.castle.Q and "Q" or "") ..
        (self.castle.k and "k" or "") .. (self.castle.q and "q" or "") .. (self.ep or "")
end

function Pos:king_sq(color)
    for i = 0, 63 do
        if self.b[i] == KING * color then return i end
    end
end

-- Is square sq attacked by side `by` (1 or -1)?
function Pos:attacked(sq, by)
    local b = self.b
    local f, r = file_of(sq), rank_of(sq)
    -- pawns
    local pr = r - by
    if pr >= 0 and pr <= 7 then
        if f > 0 and b[pr * 8 + f - 1] == PAWN * by then return true end
        if f < 7 and b[pr * 8 + f + 1] == PAWN * by then return true end
    end
    for _, d in ipairs(KNIGHT_D) do
        local nf, nr = f + d[1], r + d[2]
        if nf >= 0 and nf < 8 and nr >= 0 and nr < 8 and b[nr * 8 + nf] == KNIGHT * by then return true end
    end
    for _, d in ipairs(KING_D) do
        local nf, nr = f + d[1], r + d[2]
        if nf >= 0 and nf < 8 and nr >= 0 and nr < 8 and b[nr * 8 + nf] == KING * by then return true end
    end
    for _, d in ipairs(BISHOP_D) do
        local nf, nr = f + d[1], r + d[2]
        while nf >= 0 and nf < 8 and nr >= 0 and nr < 8 do
            local v = b[nr * 8 + nf]
            if v ~= 0 then
                if v == BISHOP * by or v == QUEEN * by then return true end
                break
            end
            nf, nr = nf + d[1], nr + d[2]
        end
    end
    for _, d in ipairs(ROOK_D) do
        local nf, nr = f + d[1], r + d[2]
        while nf >= 0 and nf < 8 and nr >= 0 and nr < 8 do
            local v = b[nr * 8 + nf]
            if v ~= 0 then
                if v == ROOK * by or v == QUEEN * by then return true end
                break
            end
            nf, nr = nf + d[1], nr + d[2]
        end
    end
    return false
end

function Pos:in_check(color)
    color = color or self.turn
    local k = self:king_sq(color)
    return k ~= nil and self:attacked(k, -color)
end

-- Pseudo-legal moves for the side to move.
function Pos:pseudo_moves(captures_only)
    local b, us = self.b, self.turn
    local moves = {}
    local function add(from, to, flags)
        local m = { from = from, to = to, piece = b[from], captured = b[to] }
        if flags then for k, v in pairs(flags) do m[k] = v end end
        moves[#moves + 1] = m
    end
    for sq = 0, 63 do
        local v = b[sq]
        if v ~= 0 and (v > 0) == (us > 0) then
            local t = math.abs(v)
            local f, r = file_of(sq), rank_of(sq)
            if t == PAWN then
                local nr = r + us
                local promo_rank = (us == 1) and 7 or 0
                local function pawn_to(to, flags)
                    if rank_of(to) == promo_rank then
                        for _, pr in ipairs({ QUEEN, ROOK, BISHOP, KNIGHT }) do
                            local fl = { promo = pr }
                            if flags then for k2, v2 in pairs(flags) do fl[k2] = v2 end end
                            add(sq, to, fl)
                        end
                    else
                        add(sq, to, flags)
                    end
                end
                if nr >= 0 and nr <= 7 then
                    if not captures_only and b[nr * 8 + f] == 0 then
                        pawn_to(nr * 8 + f)
                        local start = (us == 1) and 1 or 6
                        if r == start and b[(r + 2 * us) * 8 + f] == 0 then
                            add(sq, (r + 2 * us) * 8 + f, { double = true })
                        end
                    end
                    for _, df in ipairs({ -1, 1 }) do
                        local nf = f + df
                        if nf >= 0 and nf <= 7 then
                            local to = nr * 8 + nf
                            local tv = b[to]
                            if tv ~= 0 and (tv > 0) ~= (us > 0) then
                                pawn_to(to)
                            elseif self.ep and to == self.ep then
                                add(sq, to, { ep = true, captured = -us * PAWN })
                            end
                        end
                    end
                end
            elseif t == KNIGHT or t == KING then
                for _, d in ipairs(t == KNIGHT and KNIGHT_D or KING_D) do
                    local nf, nr = f + d[1], r + d[2]
                    if nf >= 0 and nf < 8 and nr >= 0 and nr < 8 then
                        local to = nr * 8 + nf
                        local tv = b[to]
                        if tv == 0 then
                            if not captures_only then add(sq, to) end
                        elseif (tv > 0) ~= (us > 0) then
                            add(sq, to)
                        end
                    end
                end
            else
                local dirs = (t == BISHOP and BISHOP_D) or (t == ROOK and ROOK_D) or nil
                local function slide(ds)
                    for _, d in ipairs(ds) do
                        local nf, nr = f + d[1], r + d[2]
                        while nf >= 0 and nf < 8 and nr >= 0 and nr < 8 do
                            local to = nr * 8 + nf
                            local tv = b[to]
                            if tv == 0 then
                                if not captures_only then add(sq, to) end
                            else
                                if (tv > 0) ~= (us > 0) then add(sq, to) end
                                break
                            end
                            nf, nr = nf + d[1], nr + d[2]
                        end
                    end
                end
                if dirs then slide(dirs) else slide(BISHOP_D); slide(ROOK_D) end
            end
        end
    end
    -- castling
    if not captures_only then
        local home = (us == 1) and 0 or 56
        local ks, qs = (us == 1) and "K" or "k", (us == 1) and "Q" or "q"
        if b[home + 4] == KING * us and not self:attacked(home + 4, -us) then
            if self.castle[ks] and b[home + 7] == ROOK * us and b[home + 5] == 0 and b[home + 6] == 0
                and not self:attacked(home + 5, -us) and not self:attacked(home + 6, -us) then
                add(home + 4, home + 6, { castle = "K" })
            end
            if self.castle[qs] and b[home] == ROOK * us and b[home + 1] == 0 and b[home + 2] == 0 and b[home + 3] == 0
                and not self:attacked(home + 3, -us) and not self:attacked(home + 2, -us) then
                add(home + 4, home + 2, { castle = "Q" })
            end
        end
    end
    return moves
end

-- Make a move in place; returns an undo record.
function Pos:make(m)
    local b, us = self.b, self.turn
    local u = {
        m = m, ep = self.ep, half = self.half, full = self.full,
        castle = { K = self.castle.K, Q = self.castle.Q, k = self.castle.k, q = self.castle.q },
        captured = b[m.to],
    }
    local piece = b[m.from]
    b[m.from] = 0
    if m.ep then
        local cap = m.to - 8 * us
        u.ep_sq, u.ep_piece = cap, b[cap]
        b[cap] = 0
    end
    b[m.to] = m.promo and (m.promo * us) or piece
    if m.castle then
        local home = (us == 1) and 0 or 56
        if m.castle == "K" then b[home + 5] = b[home + 7]; b[home + 7] = 0
        else b[home + 3] = b[home]; b[home] = 0 end
    end
    -- castling rights
    local function clear(sq)
        if sq == 0 then self.castle.Q = false elseif sq == 7 then self.castle.K = false
        elseif sq == 56 then self.castle.q = false elseif sq == 63 then self.castle.k = false
        elseif sq == 4 then self.castle.K = false; self.castle.Q = false
        elseif sq == 60 then self.castle.k = false; self.castle.q = false end
    end
    clear(m.from); clear(m.to)
    self.ep = m.double and (m.from + 8 * us) or nil
    if math.abs(piece) == PAWN or u.captured ~= 0 or m.ep then self.half = 0 else self.half = self.half + 1 end
    if us == -1 then self.full = self.full + 1 end
    self.turn = -us
    return u
end

function Pos:unmake(u)
    local b = self.b
    local m = u.m
    self.turn = -self.turn
    local us = self.turn
    local piece = m.promo and (PAWN * us) or b[m.to]
    b[m.from] = piece
    b[m.to] = u.captured
    if m.ep then b[u.ep_sq] = u.ep_piece end
    if m.castle then
        local home = (us == 1) and 0 or 56
        if m.castle == "K" then b[home + 7] = b[home + 5]; b[home + 5] = 0
        else b[home] = b[home + 3]; b[home + 3] = 0 end
    end
    self.ep, self.half, self.full, self.castle = u.ep, u.half, u.full, u.castle
end

function Pos:legal_moves(captures_only)
    local out = {}
    local us = self.turn
    for _, m in ipairs(self:pseudo_moves(captures_only)) do
        local u = self:make(m)
        if not self:in_check(us) then out[#out + 1] = m end
        self:unmake(u)
    end
    return out
end

function Pos:legal_from(sq)
    local out = {}
    for _, m in ipairs(self:legal_moves()) do
        if m.from == sq then out[#out + 1] = m end
    end
    return out
end

-- Notation -------------------------------------------------------------------------------
function chess.uci(m)
    local s = chess.sq_name(m.from) .. chess.sq_name(m.to)
    if m.promo then s = s .. LETTER[m.promo]:lower() end
    return s
end

-- Find the legal move matching a UCI string (accepts king-takes-rook castling).
function Pos:find_uci(s)
    if not s or #s < 4 then return nil end
    local from, to = chess.sq_parse(s:sub(1, 2)), chess.sq_parse(s:sub(3, 4))
    if not from or not to then return nil end
    local promo = s:sub(5, 5)
    promo = promo ~= "" and FROM_LETTER[promo:lower()] or nil
    local piece = self.b[from]
    -- king onto own rook => castling
    if math.abs(piece) == KING and self.b[to] == ROOK * self.turn then
        to = (to > from) and from + 2 or from - 2
    end
    for _, m in ipairs(self:legal_moves()) do
        if m.from == from and m.to == to and (m.promo == promo or (not m.promo and not promo)) then
            return m
        end
    end
    return nil
end

function Pos:san(m)
    local piece = math.abs(m.piece or self.b[m.from])
    local s
    if m.castle then
        s = (m.castle == "K") and "O-O" or "O-O-O"
    else
        local capture = (m.captured ~= nil and m.captured ~= 0) or m.ep
        if piece == PAWN then
            s = capture and (string.char(97 + file_of(m.from)) .. "x") or ""
            s = s .. chess.sq_name(m.to)
            if m.promo then s = s .. "=" .. LETTER[m.promo] end
        else
            s = LETTER[piece]
            -- disambiguation
            local same_file, same_rank, other = false, false, false
            for _, o in ipairs(self:legal_moves()) do
                if o.to == m.to and o.from ~= m.from and math.abs(self.b[o.from]) == piece then
                    other = true
                    if file_of(o.from) == file_of(m.from) then same_file = true end
                    if rank_of(o.from) == rank_of(m.from) then same_rank = true end
                end
            end
            if other then
                if not same_file then s = s .. string.char(97 + file_of(m.from))
                elseif not same_rank then s = s .. tostring(rank_of(m.from) + 1)
                else s = s .. chess.sq_name(m.from) end
            end
            if capture then s = s .. "x" end
            s = s .. chess.sq_name(m.to)
        end
    end
    local u = self:make(m)
    if self:in_check() then
        s = s .. ((#self:legal_moves() == 0) and "#" or "+")
    end
    self:unmake(u)
    return s
end

-- Play a move permanently (records SAN, repetition keys).
function Pos:play(m)
    local san = self:san(m)
    self:make(m)
    self.history[#self.history + 1] = { uci = chess.uci(m), san = san, from = m.from, to = m.to }
    local k = self:key()
    self.keys[k] = (self.keys[k] or 0) + 1
    return san
end

function Pos:play_uci(s)
    local m = self:find_uci(s)
    if not m then return nil end
    return self:play(m), m
end

-- Build a position from a FEN plus a space-separated UCI move list.
function chess.replay(initial_fen, moves)
    local p = chess.from_fen(initial_fen)
    for mv in (moves or ""):gmatch("%S+") do
        if not p:play_uci(mv) then return p, mv end
    end
    return p
end

local function insufficient(p)
    local minors, others = {}, 0
    for i = 0, 63 do
        local t = math.abs(p.b[i])
        if t == PAWN or t == ROOK or t == QUEEN then others = others + 1
        elseif t == KNIGHT or t == BISHOP then minors[#minors + 1] = { t, (file_of(i) + rank_of(i)) % 2 } end
    end
    if others > 0 then return false end
    if #minors <= 1 then return true end
    -- only bishops, all on the same color
    for _, mnr in ipairs(minors) do if mnr[1] ~= BISHOP then return false end end
    for _, mnr in ipairs(minors) do if mnr[2] ~= minors[1][2] then return false end end
    return true
end

-- Returns nil while the game goes on, else {result="1-0"|"0-1"|"1/2-1/2", reason=...}
function Pos:outcome()
    local moves = self:legal_moves()
    if #moves == 0 then
        if self:in_check() then
            return { result = self.turn == 1 and "0-1" or "1-0", reason = "checkmate", winner = -self.turn }
        end
        return { result = "1/2-1/2", reason = "stalemate" }
    end
    if insufficient(self) then return { result = "1/2-1/2", reason = "insufficient material" } end
    if self.half >= 100 then return { result = "1/2-1/2", reason = "50-move rule" } end
    if (self.keys[self:key()] or 0) >= 3 then return { result = "1/2-1/2", reason = "threefold repetition" } end
    return nil
end

-- Engine -----------------------------------------------------------------------------------
local VALUE = { 100, 320, 330, 500, 900, 0 }
-- Piece-square tables from white's point of view, a8..h1 order (rank 8 first).
local PST = {
    [PAWN] = { 0, 0, 0, 0, 0, 0, 0, 0, 50, 50, 50, 50, 50, 50, 50, 50, 10, 10, 20, 30, 30, 20, 10, 10, 5, 5, 10, 25, 25, 10, 5, 5,
        0, 0, 0, 20, 20, 0, 0, 0, 5, -5, -10, 0, 0, -10, -5, 5, 5, 10, 10, -20, -20, 10, 10, 5, 0, 0, 0, 0, 0, 0, 0, 0 },
    [KNIGHT] = { -50, -40, -30, -30, -30, -30, -40, -50, -40, -20, 0, 0, 0, 0, -20, -40, -30, 0, 10, 15, 15, 10, 0, -30, -30, 5, 15, 20, 20, 15, 5, -30,
        -30, 0, 15, 20, 20, 15, 0, -30, -30, 5, 10, 15, 15, 10, 5, -30, -40, -20, 0, 5, 5, 0, -20, -40, -50, -40, -30, -30, -30, -30, -40, -50 },
    [BISHOP] = { -20, -10, -10, -10, -10, -10, -10, -20, -10, 0, 0, 0, 0, 0, 0, -10, -10, 0, 5, 10, 10, 5, 0, -10, -10, 5, 5, 10, 10, 5, 5, -10,
        -10, 0, 10, 10, 10, 10, 0, -10, -10, 10, 10, 10, 10, 10, 10, -10, -10, 5, 0, 0, 0, 0, 5, -10, -20, -10, -10, -10, -10, -10, -10, -20 },
    [ROOK] = { 0, 0, 0, 0, 0, 0, 0, 0, 5, 10, 10, 10, 10, 10, 10, 5, -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5,
        -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5, -5, 0, 0, 0, 0, 0, 0, -5, 0, 0, 0, 5, 5, 0, 0, 0 },
    [QUEEN] = { -20, -10, -10, -5, -5, -10, -10, -20, -10, 0, 0, 0, 0, 0, 0, -10, -10, 0, 5, 5, 5, 5, 0, -10, -5, 0, 5, 5, 5, 5, 0, -5,
        0, 0, 5, 5, 5, 5, 0, -5, -10, 5, 5, 5, 5, 5, 0, -10, -10, 0, 5, 0, 0, 0, 0, -10, -20, -10, -10, -5, -5, -10, -10, -20 },
    [KING] = { -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30, -30, -40, -40, -50, -50, -40, -40, -30,
        -20, -30, -30, -40, -40, -30, -30, -20, -10, -20, -20, -20, -20, -20, -20, -10, 20, 20, 0, 0, 0, 0, 20, 20, 20, 30, 10, 0, 0, 10, 30, 20 },
}

local function pst(t, sq, color)
    -- tables are rank 8 first; for white, sq a1=0 maps to index 56
    local r, f = rank_of(sq), file_of(sq)
    local idx = (color == 1) and ((7 - r) * 8 + f) or (r * 8 + f)
    return PST[t][idx + 1]
end

function Pos:evaluate()
    local s = 0
    local b = self.b
    for i = 0, 63 do
        local v = b[i]
        if v ~= 0 then
            local t = math.abs(v)
            local c = v > 0 and 1 or -1
            s = s + c * (VALUE[t] + pst(t, i, c))
        end
    end
    return s * self.turn
end

local function order(moves)
    for _, m in ipairs(moves) do
        local sc = 0
        if m.captured and m.captured ~= 0 then sc = 10 * VALUE[math.abs(m.captured)] - VALUE[math.abs(m.piece)] / 10 end
        if m.promo then sc = sc + VALUE[m.promo] end
        m.score = sc
    end
    table.sort(moves, function(a, b) return a.score > b.score end)
end

local nodes = 0
local function quiesce(p, alpha, beta, depth)
    nodes = nodes + 1
    local stand = p:evaluate()
    if stand >= beta then return beta end
    if stand > alpha then alpha = stand end
    if depth <= 0 then return alpha end
    local moves = p:pseudo_moves(true)
    order(moves)
    local us = p.turn
    for _, m in ipairs(moves) do
        local u = p:make(m)
        if not p:in_check(us) then
            local sc = -quiesce(p, -beta, -alpha, depth - 1)
            p:unmake(u)
            if sc >= beta then return beta end
            if sc > alpha then alpha = sc end
        else
            p:unmake(u)
        end
    end
    return alpha
end

local function negamax(p, depth, alpha, beta, deadline)
    if depth == 0 then return quiesce(p, alpha, beta, 4) end
    nodes = nodes + 1
    local moves = p:pseudo_moves()
    order(moves)
    local us = p.turn
    local legal = 0
    for _, m in ipairs(moves) do
        local u = p:make(m)
        if not p:in_check(us) then
            legal = legal + 1
            local sc = -negamax(p, depth - 1, -beta, -alpha, deadline)
            p:unmake(u)
            if sc >= beta then return beta end
            if sc > alpha then alpha = sc end
            if deadline and nodes % 512 == 0 and os.clock() > deadline then return alpha end
        else
            p:unmake(u)
        end
    end
    if legal == 0 then
        if p:in_check(us) then return -100000 - depth end
        return 0
    end
    return alpha
end

-- Pick a move. level 1..4. Lower levels add randomness.
function chess.best_move(pos, level)
    level = level or 2
    local p = pos:copy()
    local moves = p:legal_moves()
    if #moves == 0 then return nil end
    local depth = ({ 1, 2, 3, 3 })[level] or 2
    local noise = ({ 120, 40, 10, 0 })[level] or 0
    local deadline = os.clock() + ({ 1, 2, 4, 8 })[level]
    order(moves)
    local best, best_sc = moves[1], -math.huge
    nodes = 0
    for _, m in ipairs(moves) do
        local u = p:make(m)
        local sc = -negamax(p, depth - 1, -1e9, 1e9, deadline)
        p:unmake(u)
        if noise > 0 then sc = sc + math.random(-noise, noise) end
        if sc > best_sc then best, best_sc = m, sc end
    end
    return best
end

return chess
