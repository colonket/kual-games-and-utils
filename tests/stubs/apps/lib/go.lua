-- TEMPORARY test stand-in for lua/apps/lib/go.lua (workstream A owns the real one).
-- Implements the SPEC contract with simple rules so the OGS screens can run in the sim.
local go = {}
go.EMPTY, go.BLACK, go.WHITE = 0, 1, 2

local Game = {}
Game.__index = Game

function go.new(w, h)
    h = h or w
    local g = setmetatable({ w = w, h = h, board = {}, turn = go.BLACK, moves = {},
        captures = { [1] = 0, [2] = 0 }, ko = nil }, Game)
    for i = 0, w * h - 1 do g.board[i] = 0 end
    return g
end

function Game:copy()
    local c = go.new(self.w, self.h)
    for i = 0, self.w * self.h - 1 do c.board[i] = self.board[i] end
    c.turn, c.ko = self.turn, self.ko
    c.captures = { [1] = self.captures[1], [2] = self.captures[2] }
    for i, m in ipairs(self.moves) do c.moves[i] = m end
    c.last, c.komi, c.rules, c.phase = self.last, self.komi, self.rules, self.phase
    return c
end

function Game:on(x, y) return x >= 0 and y >= 0 and x < self.w and y < self.h end
function Game:at(x, y) if not self:on(x, y) then return nil end return self.board[y * self.w + x] end

function Game:nbrs(i)
    local w, h = self.w, self.h
    local x, y = i % w, math.floor(i / w)
    local r = {}
    if x > 0 then r[#r + 1] = i - 1 end
    if x < w - 1 then r[#r + 1] = i + 1 end
    if y > 0 then r[#r + 1] = i - w end
    if y < h - 1 then r[#r + 1] = i + w end
    return r
end

local function group_at(g, i)
    local c = g.board[i]
    local seen, list, libs = { [i] = true }, { i }, {}
    local nl = 0
    local k = 1
    while k <= #list do
        for _, n in ipairs(g:nbrs(list[k])) do
            if not seen[n] then
                local v = g.board[n]
                if v == c then seen[n] = true; list[#list + 1] = n
                elseif v == 0 and not libs[n] then libs[n] = true; nl = nl + 1 end
            end
        end
        k = k + 1
    end
    return list, nl
end

function Game:group(x, y) return group_at(self, y * self.w + x) end

local function put(g, i, color)
    g.board[i] = color
    local caps = {}
    for _, n in ipairs(g:nbrs(i)) do
        if g.board[n] == 3 - color then
            local list, libs = group_at(g, n)
            if libs == 0 then
                for _, j in ipairs(list) do g.board[j] = 0; caps[#caps + 1] = j end
            end
        end
    end
    return caps
end

function Game:legal(x, y)
    if not self:on(x, y) then return false, "offboard" end
    local i = y * self.w + x
    if self.board[i] ~= 0 then return false, "occupied" end
    if self.ko == i then return false, "ko" end
    local t = self:copy()
    put(t, i, self.turn)
    local _, libs = group_at(t, i)
    if libs == 0 then return false, "suicide" end
    return true
end

function Game:play(x, y)
    local color = self.turn
    if x == -1 then
        self.moves[#self.moves + 1] = { x = -1, y = -1, color = color }
        self.last = { x = -1, y = -1 }
        self.ko = nil
        self.turn = 3 - color
        return true, {}
    end
    local ok, why = self:legal(x, y)
    if not ok then return false, why end
    local i = y * self.w + x
    local caps = put(self, i, color)
    self.captures[color] = self.captures[color] + #caps
    local list, libs = group_at(self, i)
    self.ko = (#caps == 1 and #list == 1 and libs == 1) and caps[1] or nil
    self.moves[#self.moves + 1] = { x = x, y = y, color = color }
    self.last = { x = x, y = y }
    self.turn = 3 - color
    return true, caps
end

function Game:place(x, y, color) put(self, y * self.w + x, color) end

local A = string.byte("a")
function go.sgf(x, y)
    if x < 0 then return ".." end
    return string.char(A + x) .. string.char(A + y)
end
function go.from_sgf(s)
    if not s or s == "" or s == ".." then return -1, -1 end
    return s:byte(1) - A, s:byte(2) - A
end
function go.parse_points(str, w)
    local set = {}
    for i = 1, #(str or "") - 1, 2 do
        local x, y = go.from_sgf(str:sub(i, i + 1))
        if x >= 0 then set[y * w + x] = true end
    end
    return set
end
function go.points_string(set, w)
    local idx = {}
    for i in pairs(set) do idx[#idx + 1] = i end
    table.sort(idx)
    local out = {}
    for _, i in ipairs(idx) do out[#out + 1] = go.sgf(i % w, math.floor(i / w)) end
    return table.concat(out)
end

function go.from_gamedata(gd)
    local g = go.new(gd.width or 19, gd.height or gd.width or 19)
    local is = gd.initial_state or {}
    for _, p in ipairs({ { is.black, 1 }, { is.white, 2 } }) do
        for i in pairs(go.parse_points(p[1] or "", g.w)) do g.board[i] = p[2] end
    end
    g.turn = gd.initial_player == "white" and 2 or 1
    local free = gd.free_handicap_placement and (gd.handicap or 0) or 0
    for k, m in ipairs(gd.moves or {}) do
        if k <= free then
            g:place(m[1], m[2], 1)
            g.moves[#g.moves + 1] = { x = m[1], y = m[2], color = 1 }
            g.last = { x = m[1], y = m[2] }
            if k == free then g.turn = 2 end
        else
            g:play(m[1], m[2])
        end
    end
    g.komi, g.rules, g.phase = gd.komi, gd.rules, gd.phase
    return g
end

function go.score(g, dead)
    dead = dead or {}
    local w, n = g.w, g.w * g.h
    local b = {}
    local caps = { [1] = g.captures[1], [2] = g.captures[2] }
    for i = 0, n - 1 do
        local v = g.board[i]
        if v ~= 0 and dead[i] then caps[3 - v] = caps[3 - v] + 1; v = 0 end
        b[i] = v
    end
    local territory, dame, seen = {}, {}, {}
    local area = { [1] = 0, [2] = 0 }
    for i = 0, n - 1 do
        if b[i] ~= 0 then area[b[i]] = area[b[i]] + 1 end
        if b[i] == 0 and not seen[i] then
            local list, touch, k = { i }, {}, 1
            seen[i] = true
            while k <= #list do
                for _, nb in ipairs(g:nbrs(list[k])) do
                    if b[nb] == 0 then
                        if not seen[nb] then seen[nb] = true; list[#list + 1] = nb end
                    else touch[b[nb]] = true end
                end
                k = k + 1
            end
            local owner = (touch[1] and not touch[2]) and 1 or (touch[2] and not touch[1]) and 2 or nil
            for _, j in ipairs(list) do
                if owner then territory[j] = owner else dame[j] = true end
            end
        end
    end
    local terr = { [1] = 0, [2] = 0 }
    for _, c in pairs(territory) do terr[c] = terr[c] + 1 end
    local area_rules = g.rules == "chinese" or g.rules == "aga"
    local komi = g.komi or 0
    local black, white
    if area_rules then
        black, white = area[1] + terr[1], area[2] + terr[2] + komi
    else
        black, white = terr[1] + caps[1], terr[2] + caps[2] + komi
    end
    return { black = black, white = white, territory = territory, dame = dame,
        details = { territory = terr, captures = caps, stones = area, komi = komi } }
end

function go.star_points(size)
    local pts = {}
    local list = ({ [9] = { 2, 4, 6 }, [13] = { 3, 6, 9 }, [19] = { 3, 9, 15 } })[size]
    if not list then return pts end
    for _, y in ipairs(list) do for _, x in ipairs(list) do
        if size ~= 9 or (x ~= 4 and y ~= 4) or (x == 4 and y == 4) then pts[#pts + 1] = y * size + x end
    end end
    return pts
end

function go.toggle_group_dead(g, dead, x, y)
    local i = y * g.w + x
    local list = (g.board[i] == 0) and { i } or (group_at(g, i))
    local now_dead = not dead[i]
    for _, j in ipairs(list) do dead[j] = now_dead or nil end
    return list, now_dead
end

return go
