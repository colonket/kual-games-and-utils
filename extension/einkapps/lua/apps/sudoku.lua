-- Sudoku (ported from CrossPoint Apps' SudokuActivity). Puzzles are
-- generated on the device with a guaranteed unique solution; tap a cell,
-- then a number. Notes mode, mistakes check, and auto-save.
local ui = require("core.ui")
local gfx = require("core.gfx")
local sys = require("core.sys")
local store = require("core.store")
local bit = require("bit")

local dp = ui.dp
local BLACK, WHITE, DARK, GRAY, PALE, LIGHT = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.GRAY, gfx.PALE, gfx.LIGHT

local M = {}

-- Solver: counts solutions up to `limit` (cells is a 1..81 array, 0 = empty).
local function box_of(i) local r, c = math.floor((i - 1) / 9), (i - 1) % 9; return math.floor(r / 3) * 3 + math.floor(c / 3) end

local function count_solutions(cells, limit)
    local g = {}
    for i = 1, 81 do g[i] = cells[i] end
    local rows, cols, boxes = {}, {}, {}
    for k = 0, 8 do rows[k], cols[k], boxes[k] = 0, 0, 0 end
    for i = 1, 81 do
        local v = g[i]
        if v ~= 0 then
            local m = bit.lshift(1, v)
            local r, c, b = math.floor((i - 1) / 9), (i - 1) % 9, box_of(i)
            if bit.band(rows[r], m) ~= 0 or bit.band(cols[c], m) ~= 0 or bit.band(boxes[b], m) ~= 0 then return 0 end
            rows[r], cols[c], boxes[b] = bit.bor(rows[r], m), bit.bor(cols[c], m), bit.bor(boxes[b], m)
        end
    end
    local count = 0
    local function solve()
        -- pick the empty cell with the fewest candidates
        local best, best_n, best_mask = nil, 10, 0
        for i = 1, 81 do
            if g[i] == 0 then
                local r, c, b = math.floor((i - 1) / 9), (i - 1) % 9, box_of(i)
                local used = bit.bor(rows[r], cols[c], boxes[b])
                local n = 0
                for v = 1, 9 do if bit.band(used, bit.lshift(1, v)) == 0 then n = n + 1 end end
                if n < best_n then best, best_n, best_mask = i, n, used end
                if n == 0 then return end
            end
        end
        if not best then
            count = count + 1
            return
        end
        local r, c, b = math.floor((best - 1) / 9), (best - 1) % 9, box_of(best)
        for v = 1, 9 do
            local m = bit.lshift(1, v)
            if bit.band(best_mask, m) == 0 then
                g[best] = v
                rows[r], cols[c], boxes[b] = bit.bor(rows[r], m), bit.bor(cols[c], m), bit.bor(boxes[b], m)
                solve()
                rows[r], cols[c], boxes[b] = bit.bxor(rows[r], m), bit.bxor(cols[c], m), bit.bxor(boxes[b], m)
                g[best] = 0
                if count >= limit then return end
            end
        end
    end
    solve()
    return count
end
M.count_solutions = count_solutions

local function shuffle(t)
    for i = #t, 2, -1 do
        local j = math.random(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- Full grid from the classic base pattern, shuffled (digits, rows/cols
-- within bands, bands and stacks) — the same idea as the original app.
local function full_grid()
    local function pattern(r, c) return (3 * (r % 3) + math.floor(r / 3) + c) % 9 end
    local bands = shuffle({ 0, 1, 2 })
    local rows = {}
    for _, b in ipairs(bands) do for _, r in ipairs(shuffle({ 0, 1, 2 })) do rows[#rows + 1] = b * 3 + r end end
    local stacks = shuffle({ 0, 1, 2 })
    local cols = {}
    for _, s in ipairs(stacks) do for _, c in ipairs(shuffle({ 0, 1, 2 })) do cols[#cols + 1] = s * 3 + c end end
    local digits = shuffle({ 1, 2, 3, 4, 5, 6, 7, 8, 9 })
    local g = {}
    for r = 0, 8 do
        for c = 0, 8 do
            g[r * 9 + c + 1] = digits[pattern(rows[r + 1], cols[c + 1]) + 1]
        end
    end
    return g
end

local DIFF = { { "Easy", 38 }, { "Medium", 46 }, { "Hard", 52 }, { "Expert", 58 } }

function M.generate(level)
    local target = DIFF[level][2]
    local sol = full_grid()
    local puzzle = {}
    for i = 1, 81 do puzzle[i] = sol[i] end
    local order = {}
    for i = 1, 81 do order[i] = i end
    shuffle(order)
    local removed = 0
    for _, i in ipairs(order) do
        if removed >= target then break end
        local keep = puzzle[i]
        puzzle[i] = 0
        if count_solutions(puzzle, 2) ~= 1 then
            puzzle[i] = keep
        else
            removed = removed + 1
        end
    end
    return puzzle, sol
end

function M.new()
    local st = store.load("sudoku")
    local scr = { sel = 41, notes_mode = false, checked = false }

    local function save() store.save("sudoku", st) end

    local function new_puzzle(level)
        ui.busy("Generating puzzle…")
        local p, sol = M.generate(level)
        st = { level = level, puzzle = p, solution = sol, cells = {}, notes = {}, started = os.time(), won = false }
        for i = 1, 81 do st.cells[i] = p[i]; st.notes[i] = 0 end
        scr.sel, scr.checked = 41, false
        save()
        ui.redraw(true)
    end

    local function won()
        for i = 1, 81 do if st.cells[i] ~= st.solution[i] then return false end end
        return true
    end

    function scr:enter()
        math.randomseed(sys.now() % 2147483647)
        if not st.puzzle then new_puzzle(st.level or 1) end
    end

    function scr:input(v)
        local i = self.sel
        if not i or st.puzzle[i] ~= 0 or st.won then return end
        if self.notes_mode and v > 0 then
            st.notes[i] = bit.bxor(st.notes[i] or 0, bit.lshift(1, v))
            st.cells[i] = 0
        else
            st.cells[i] = (st.cells[i] == v) and 0 or v
            st.notes[i] = 0
            if v > 0 then
                -- clear this digit from notes in the same row/col/box
                local r, c, b = math.floor((i - 1) / 9), (i - 1) % 9, box_of(i)
                for j = 1, 81 do
                    local rj, cj = math.floor((j - 1) / 9), (j - 1) % 9
                    if rj == r or cj == c or box_of(j) == b then
                        st.notes[j] = bit.band(st.notes[j] or 0, bit.bnot(bit.lshift(1, v)))
                    end
                end
            end
        end
        if won() then
            st.won = true
            ui.alert("Solved!", string.format("%s puzzle in %d min.", DIFF[st.level][1],
                math.floor((os.time() - (st.started or os.time())) / 60)))
        end
        save()
        ui.redraw()
    end

    function scr:render(ctx)
        local s = ctx.s
        local top = ctx:header("Sudoku · " .. DIFF[st.level or 1][1], { right = { "New", function()
            ui.choose("New puzzle", { "Easy", "Medium", "Hard", "Expert" }, function(i) new_puzzle(i) end, { selected = st.level })
        end, size = 34 } })
        local W = ctx.W
        local size = math.floor((W - 2 * dp(30)) / 9) * 9
        local cs = size / 9
        local gx, gy = math.floor((W - size) / 2), top + dp(26)
        local selv = self.sel and st.cells[self.sel] or 0
        local sr, sc, sb = -1, -1, -1
        if self.sel then sr, sc, sb = math.floor((self.sel - 1) / 9), (self.sel - 1) % 9, box_of(self.sel) end
        local given_f = ui.font("bold", 64 * size / 1008)
        local user_f = ui.font("sans", 64 * size / 1008)
        local note_f = ui.font("sans", 24 * size / 1008)
        for i = 1, 81 do
            local r, c = math.floor((i - 1) / 9), (i - 1) % 9
            local x, y = math.floor(gx + c * cs), math.floor(gy + r * cs)
            local w = math.floor(gx + (c + 1) * cs) - x
            local v = st.cells[i]
            local bg = WHITE
            if i == self.sel then bg = LIGHT
            elseif r == sr or c == sc or box_of(i) == sb then bg = 0xEE end
            if selv ~= 0 and v == selv and i ~= self.sel then bg = PALE end
            s:fill_rect(x, y, w, w, bg)
            if v ~= 0 then
                local f = (st.puzzle[i] ~= 0) and given_f or user_f
                local wrong = self.checked and st.puzzle[i] == 0 and v ~= st.solution[i]
                f:draw_center_ink(s, x, y, w, w, tostring(v), BLACK)
                if wrong then s:line(x + w * 0.2, y + w * 0.8, x + w * 0.8, y + w * 0.2, BLACK, dp(5)) end
            elseif (st.notes[i] or 0) ~= 0 then
                for d = 1, 9 do
                    if bit.band(st.notes[i], bit.lshift(1, d)) ~= 0 then
                        local nr, nc = math.floor((d - 1) / 3), (d - 1) % 3
                        note_f:draw_center_ink(s, x + nc * w / 3, y + nr * w / 3, w / 3, w / 3, tostring(d), DARK)
                    end
                end
            end
            local idx = i
            ctx:hit(x, y, w, w, function() self.sel = idx; ui.redraw() end)
        end
        for k = 0, 9 do
            local t = (k % 3 == 0) and dp(6) or dp(2)
            s:fill_rect(gx + k * cs - math.floor(t / 2), gy, t, size, BLACK)
            s:fill_rect(gx, gy + k * cs - math.floor(t / 2), size, t, BLACK)
        end
        -- number pad
        local y = gy + size + dp(30)
        local gap = dp(12)
        local pad = {}
        for d = 1, 9 do
            local count = 0
            for i = 1, 81 do if st.cells[i] == d then count = count + 1 end end
            pad[#pad + 1] = { tostring(d), function() self:input(d) end, { style = count >= 9 and "light" or "outline", size = 48 } }
        end
        local bw = math.floor((W - 2 * ui.M - gap * 8) / 9)
        local bh = math.min(dp(120), ctx.H - y - ui.BTN_H - dp(70))
        for k, it in ipairs(pad) do
            ctx:button(ui.M + (k - 1) * (bw + gap), y, bw, bh, it[1], it[2], it[3])
        end
        y = y + bh + dp(24)
        ctx:button_row(ui.M, y, W - 2 * ui.M, math.min(ui.BTN_H, ctx.H - y - dp(20)), {
            { "Erase", function() self:input(0) end, { size = 32 } },
            { self.notes_mode and "Notes: on" or "Notes: off", function() self.notes_mode = not self.notes_mode; ui.redraw() end,
                { selected = self.notes_mode, size = 32 } },
            { self.checked and "Hide check" or "Check", function() self.checked = not self.checked; ui.redraw() end, { size = 32 } },
        })
    end
    return scr
end

return M
