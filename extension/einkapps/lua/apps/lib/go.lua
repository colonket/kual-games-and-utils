-- Go rules engine: board state, captures, ko, OGS gamedata import and scoring.
-- Pure Lua (no UI). Board index i = y*w + x, 0-based x/y, origin top-left.
local bit = require("bit")
local go = {}

local EMPTY, BLACK, WHITE = 0, 1, 2
go.EMPTY, go.BLACK, go.WHITE = EMPTY, BLACK, WHITE

local floor = math.floor
local byte, char = string.byte, string.char
local A = byte("a")

local function other(c) return 3 - c end
go.other = other

local Game = {}
Game.__index = Game
go.Game = Game

function go.new(size, height)
    size = size or 19
    local g = setmetatable({
        w = size, h = height or size,
        board = {}, turn = BLACK, moves = {},
        captures = { [1] = 0, [2] = 0 },
        ko = nil, last = nil,
        komi = 0, rules = "japanese", phase = "play", handicap = 0,
    }, Game)
    for i = 0, g.w * g.h - 1 do g.board[i] = EMPTY end
    return g
end

function Game:copy()
    local c = setmetatable({}, Game)
    for k, v in pairs(self) do c[k] = v end
    c.board = {}
    for i = 0, self.w * self.h - 1 do c.board[i] = self.board[i] end
    c.moves = {}
    for k, m in ipairs(self.moves) do c.moves[k] = { x = m.x, y = m.y, color = m.color } end
    c.captures = { [1] = self.captures[1], [2] = self.captures[2] }
    if self.last then c.last = { x = self.last.x, y = self.last.y, color = self.last.color } end
    if self.removed then
        c.removed = {}
        for k, v in pairs(self.removed) do c.removed[k] = v end
    end
    return c
end

function Game:on_board(x, y)
    return x >= 0 and y >= 0 and x < self.w and y < self.h
end

function Game:at(x, y)
    if not self:on_board(x, y) then return nil end
    return self.board[y * self.w + x]
end

-- Calls fn(j) for each orthogonal neighbour index of i.
local function each_neighbor(w, h, i, fn)
    local x, y = i % w, floor(i / w)
    if x > 0 then fn(i - 1) end
    if x < w - 1 then fn(i + 1) end
    if y > 0 then fn(i - w) end
    if y < h - 1 then fn(i + w) end
end
go.each_neighbor = each_neighbor

-- Group containing index i on board b: list of indices, liberty count.
local function group_at(b, w, h, i)
    local color = b[i]
    local seen, libs = { [i] = true }, {}
    local list, n = { i }, 0
    local k = 1
    while k <= #list do
        local cur = list[k]
        each_neighbor(w, h, cur, function(j)
            local v = b[j]
            if v == color then
                if not seen[j] then seen[j] = true; list[#list + 1] = j end
            elseif v == EMPTY then
                if not libs[j] then libs[j] = true; n = n + 1 end
            end
        end)
        k = k + 1
    end
    return list, n
end

function Game:group(x, y)
    if not self:on_board(x, y) then return {}, 0 end
    local i = y * self.w + x
    if self.board[i] == EMPTY then return { i }, 0 end
    return group_at(self.board, self.w, self.h, i)
end

-- Put a stone of `color` at i on board b and remove opponent groups left without
-- liberties. Returns the list of captured indices and whether the placed stone's
-- own group has no liberties (suicide). Does not undo anything.
local function put(b, w, h, i, color)
    b[i] = color
    local opp = other(color)
    local captured = {}
    each_neighbor(w, h, i, function(j)
        if b[j] == opp then
            local grp, libs = group_at(b, w, h, j)
            if libs == 0 then
                for _, k in ipairs(grp) do
                    if b[k] == opp then
                        b[k] = EMPTY
                        captured[#captured + 1] = k
                    end
                end
            end
        end
    end)
    local own, libs = group_at(b, w, h, i)
    return captured, libs == 0, own
end

function Game:legal(x, y)
    if not self:on_board(x, y) then return false, "offboard" end
    local i = y * self.w + x
    if self.board[i] ~= EMPTY then return false, "occupied" end
    if self.ko == i then return false, "ko" end
    local b = {}
    for k = 0, self.w * self.h - 1 do b[k] = self.board[k] end
    local _, suicide = put(b, self.w, self.h, i, self.turn)
    if suicide then return false, "suicide" end
    return true
end

-- Play for g.turn. x == -1 passes. Returns ok, reason_or_captured_list.
function Game:play(x, y)
    local color = self.turn
    if x == nil or x < 0 then
        self.moves[#self.moves + 1] = { x = -1, y = -1, color = color }
        self.last = { x = -1, y = -1, color = color }
        self.ko = nil
        self.turn = other(color)
        return true, {}
    end
    local ok, reason = self:legal(x, y)
    if not ok then return false, reason end
    local w, h = self.w, self.h
    local i = y * w + x
    local captured, _, own = put(self.board, w, h, i, color)
    self.captures[color] = self.captures[color] + #captured
    -- Simple ko: a single stone captured a single stone and is left in atari.
    self.ko = nil
    if #captured == 1 and #own == 1 then
        local _, libs = group_at(self.board, w, h, i)
        if libs == 1 then self.ko = captured[1] end
    end
    self.moves[#self.moves + 1] = { x = x, y = y, color = color }
    self.last = { x = x, y = y, color = color }
    self.turn = other(color)
    return true, captured
end

-- Place a stone (with captures) without switching turn or recording a move.
-- A placement that leaves its own group without liberties removes that group
-- (credited to the opponent), as under rule sets that allow suicide.
function Game:place(x, y, color)
    if not self:on_board(x, y) then return false, "offboard" end
    local w, h = self.w, self.h
    local i = y * w + x
    local captured, suicide, own = put(self.board, w, h, i, color)
    self.captures[color] = self.captures[color] + #captured
    if suicide then
        for _, k in ipairs(own) do self.board[k] = EMPTY end
        self.captures[other(color)] = self.captures[other(color)] + #own
    end
    return true, captured
end

-- Coordinates -------------------------------------------------------------------------
function go.sgf(x, y)
    if x == nil or x < 0 or y == nil or y < 0 then return ".." end
    return char(A + x, A + y)
end

function go.from_sgf(s)
    if not s or #s < 2 or s:sub(1, 2) == ".." then return -1, -1 end
    return byte(s, 1) - A, byte(s, 2) - A
end

function go.parse_points(str, w)
    local set = {}
    if type(str) ~= "string" then return set end
    for k = 1, #str - 1, 2 do
        local x, y = byte(str, k) - A, byte(str, k + 1) - A
        if x >= 0 and y >= 0 and x < 26 and y < 26 and x < w then
            set[y * w + x] = true
        end
    end
    return set
end

function go.points_string(set, w)
    local idx = {}
    for i, v in pairs(set or {}) do if v then idx[#idx + 1] = i end end
    table.sort(idx)
    local out = {}
    for k, i in ipairs(idx) do out[k] = go.sgf(i % w, floor(i / w)) end
    return table.concat(out)
end

-- Human coordinate like "D4" (columns A..Z skipping I, rows counted from the bottom).
local COLS = "ABCDEFGHJKLMNOPQRSTUVWXYZ"
go.COLS = COLS
function go.coord_name(x, y, h)
    if not x or x < 0 then return "pass" end
    return COLS:sub(x + 1, x + 1) .. tostring((h or 19) - y)
end

-- Handicap / star points ----------------------------------------------------------------
local function star_lines(size)
    if size == 19 then return { 3, 9, 15 } end
    if size == 13 then return { 3, 6, 9 } end
    if size == 9 then return { 2, 4, 6 } end
    return nil
end

function go.star_points(size)
    local L = star_lines(size)
    if not L then return {} end
    local out = {}
    if size == 9 then
        -- corners plus centre
        for _, p in ipairs({ { 2, 2 }, { 6, 2 }, { 4, 4 }, { 2, 6 }, { 6, 6 } }) do
            out[#out + 1] = p[2] * size + p[1]
        end
        return out
    end
    for _, y in ipairs(L) do
        for _, x in ipairs(L) do out[#out + 1] = y * size + x end
    end
    return out
end

-- Standard fixed handicap placement (only used if gamedata gives none).
local function fixed_handicap(size, n)
    local L = star_lines(size)
    if not L or n < 2 then return {} end
    local lo, mid, hi = L[1], L[2], L[3]
    local pts = { { hi, lo }, { lo, hi }, { hi, hi }, { lo, lo } }
    local out = {}
    for k = 1, math.min(n, 4) do out[k] = pts[k] end
    if n >= 6 then out[#out + 1] = { lo, mid }; out[#out + 1] = { hi, mid } end
    if n >= 8 then out[#out + 1] = { mid, lo }; out[#out + 1] = { mid, hi } end
    if n >= 5 and n % 2 == 1 then out[#out + 1] = { mid, mid } end
    return out
end
go.fixed_handicap = fixed_handicap

-- OGS gamedata ------------------------------------------------------------------------
function go.from_gamedata(gd)
    local w = tonumber(gd.width) or 19
    local h = tonumber(gd.height) or w
    local g = go.new(w, h)
    g.komi = tonumber(gd.komi) or 0
    g.rules = gd.rules or "japanese"
    g.phase = gd.phase or "play"
    g.handicap = tonumber(gd.handicap) or 0
    g.free_handicap = gd.free_handicap_placement and true or false

    local placed_black = 0
    local init = gd.initial_state
    if type(init) == "table" then
        for i in pairs(go.parse_points(init.black, w)) do
            g:place(i % w, floor(i / w), BLACK); placed_black = placed_black + 1
        end
        for i in pairs(go.parse_points(init.white, w)) do
            g:place(i % w, floor(i / w), WHITE)
        end
    end
    g.turn = (gd.initial_player == "white") and WHITE or BLACK

    -- Fixed handicap with no stones supplied: lay out the standard points.
    if g.handicap >= 2 and not g.free_handicap and placed_black == 0 then
        local pts = fixed_handicap(w, g.handicap)
        if w == h and #pts == g.handicap then
            for _, p in ipairs(pts) do g:place(p[1], p[2], BLACK) end
            g.turn = WHITE
        end
    end

    for k, m in ipairs(gd.moves or {}) do
        local x, y
        if type(m) == "table" then
            x, y = tonumber(m[1] or m.x), tonumber(m[2] or m.y)
        elseif type(m) == "string" then
            x, y = go.from_sgf(m)
        end
        x, y = x or -1, y or -1
        if g.free_handicap and k <= g.handicap then g.turn = BLACK end
        local ok = g:play(x, y)
        if not ok then
            -- Trust the server (e.g. rule sets allowing suicide): force the stone.
            local color = g.turn
            g:place(x, y, color)
            g.ko = nil
            g.moves[#g.moves + 1] = { x = x, y = y, color = color }
            g.last = { x = x, y = y, color = color }
            g.turn = other(color)
        end
    end

    g.removed = go.parse_points(gd.removed, w)
    if gd.clock and gd.players and gd.clock.current_player then
        local cp = gd.clock.current_player
        if gd.players.black and gd.players.black.id == cp then g.turn = BLACK
        elseif gd.players.white and gd.players.white.id == cp then g.turn = WHITE end
    end
    return g
end

-- Scoring -----------------------------------------------------------------------------
local AREA_RULES = { chinese = true, aga = true, nz = true, ing = true }

-- dead_set: {[i]=true} stones to remove before counting.
function go.score(g, dead_set)
    dead_set = dead_set or {}
    local w, h, n = g.w, g.h, g.w * g.h
    local b = {}
    local dead = { [1] = 0, [2] = 0 }        -- dead stones OF that color
    local stones = { [1] = 0, [2] = 0 }
    for i = 0, n - 1 do
        local v = g.board[i]
        if v ~= EMPTY and dead_set[i] then
            dead[v] = dead[v] + 1
            v = EMPTY
        elseif v ~= EMPTY then
            stones[v] = stones[v] + 1
        end
        b[i] = v
    end
    local territory, dame = {}, {}
    local terr = { [1] = 0, [2] = 0 }
    local seen = {}
    for i = 0, n - 1 do
        if b[i] == EMPTY and not seen[i] then
            local region, borders = { i }, 0
            seen[i] = true
            local k = 1
            while k <= #region do
                each_neighbor(w, h, region[k], function(j)
                    local v = b[j]
                    if v == EMPTY then
                        if not seen[j] then seen[j] = true; region[#region + 1] = j end
                    else
                        borders = bit.bor(borders, v)
                    end
                end)
                k = k + 1
            end
            if borders == BLACK or borders == WHITE then
                for _, j in ipairs(region) do territory[j] = borders end
                terr[borders] = terr[borders] + #region
            else
                for _, j in ipairs(region) do dame[j] = true end
            end
        end
    end
    local rules = (g.rules or "japanese"):lower()
    local area = AREA_RULES[rules] or false
    local komi = tonumber(g.komi) or 0
    local hcap = 0
    if area and (g.handicap or 0) > 1 then
        hcap = (rules == "aga") and (g.handicap - 1) or g.handicap
    end
    local details = {
        rules = rules, scoring = area and "area" or "territory", komi = komi, handicap = hcap,
        black = { territory = terr[1], stones = stones[1], prisoners = g.captures[1], dead = dead[2] },
        white = { territory = terr[2], stones = stones[2], prisoners = g.captures[2], dead = dead[1] },
    }
    local black, white
    if area then
        black = stones[1] + terr[1]
        white = stones[2] + terr[2] + komi + hcap
    else
        black = terr[1] + g.captures[1] + dead[2]
        white = terr[2] + g.captures[2] + dead[1] + komi
    end
    return { black = black, white = white, territory = territory, dame = dame, details = details }
end

-- Toggle the dead/alive state of the group at (x, y) (or the single empty point).
-- Returns changed_indices, now_dead.
function go.toggle_group_dead(g, dead_set, x, y)
    if not g:on_board(x, y) then return {}, false end
    local i = y * g.w + x
    local list
    if g.board[i] == EMPTY then list = { i }
    else list = group_at(g.board, g.w, g.h, i) end
    local now_dead = not dead_set[i]
    for _, j in ipairs(list) do dead_set[j] = now_dead or nil end
    return list, now_dead
end

return go
