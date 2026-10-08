-- Unit tests for apps/lib/go.lua.
-- Run from the repo root: /home/claude/opt/luajit/bin/luajit tests/go_test.lua
package.path = "extension/einkapps/lua/?.lua;" .. package.path
local go = require("apps.lib.go")
local B, W, E = go.BLACK, go.WHITE, go.EMPTY

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1
    else failed = failed + 1; io.stderr:write("FAIL: ", msg, "\n") end
end
local function eq(a, b, msg)
    check(a == b, msg .. " (got " .. tostring(a) .. ", want " .. tostring(b) .. ")")
end
local function setup(size, black, white, turn)
    local g = go.new(size)
    for _, p in ipairs(black or {}) do g:place(p[1], p[2], B) end
    for _, p in ipairs(white or {}) do g:place(p[1], p[2], W) end
    g.turn = turn or B
    return g
end

-- Basics -------------------------------------------------------------------------------
do
    local g = go.new(9)
    eq(g.w, 9, "width"); eq(g.h, 9, "height"); eq(g.turn, B, "black starts")
    eq(g:at(4, 4), E, "empty"); eq(g:at(9, 0), nil, "offboard at")
    local ok, r = g:legal(-1, 3); check(not ok and r == "offboard", "offboard legal")
    check(g:play(4, 4), "play centre"); eq(g:at(4, 4), B, "black stone")
    eq(g.turn, W, "turn switches"); eq(#g.moves, 1, "move recorded")
    eq(g.last.x, 4, "last x")
    ok, r = g:legal(4, 4); check(not ok and r == "occupied", "occupied")
    local c = g:copy(); c:play(0, 0)
    eq(g:at(0, 0), E, "copy is independent"); eq(#g.moves, 1, "copy moves independent")
    local h = go.new(9, 13); eq(h.w * h.h, 117, "rectangular board")
end

-- Liberties on edge/corner ----------------------------------------------------------------
do
    local g = setup(9, { { 0, 0 }, { 4, 0 }, { 4, 4 } })
    local _, l = g:group(0, 0); eq(l, 2, "corner liberties")
    _, l = g:group(4, 0); eq(l, 3, "edge liberties")
    _, l = g:group(4, 4); eq(l, 4, "centre liberties")
    g:place(5, 4, B)
    local grp; grp, l = g:group(4, 4); eq(#grp, 2, "group size"); eq(l, 6, "two-stone liberties")
end

-- Captures --------------------------------------------------------------------------------
do
    -- single corner capture
    local g = setup(9, { { 1, 0 } }, { { 0, 0 } })
    local ok, cap = g:play(0, 1)
    check(ok and #cap == 1 and cap[1] == 0, "corner capture"); eq(g:at(0, 0), E, "captured removed")
    eq(g.captures[B], 1, "capture count")
    -- multi-stone capture
    g = setup(9, { { 0, 1 }, { 1, 1 } }, { { 0, 0 }, { 1, 0 } })
    ok, cap = g:play(2, 0)
    check(ok and #cap == 2, "two-stone capture"); eq(g.captures[B], 2, "two prisoners")
    -- double capture: two separate groups with one move
    g = setup(9, { { 0, 1 }, { 2, 1 }, { 3, 0 } }, { { 0, 0 }, { 2, 0 } })
    ok, cap = g:play(1, 0)
    check(ok and #cap == 2, "double capture"); eq(g:at(0, 0), E, "dbl a"); eq(g:at(2, 0), E, "dbl b")
    eq(g.ko, nil, "double capture is not ko")
    -- white captures too
    g = setup(9, { { 4, 4 } }, { { 3, 4 }, { 5, 4 }, { 4, 3 } }, W)
    ok, cap = g:play(4, 5); check(ok and #cap == 1, "white captures"); eq(g.captures[W], 1, "white prisoners")
end

-- Suicide ---------------------------------------------------------------------------------
do
    local g = setup(9, { { 1, 0 }, { 0, 1 } }, {}, W)
    local ok, r = g:legal(0, 0); check(not ok and r == "suicide", "corner suicide")
    ok, r = g:play(0, 0); check(not ok and r == "suicide", "play refuses suicide")
    eq(g.turn, W, "turn unchanged after illegal"); eq(#g.moves, 0, "no move recorded")
    -- multi-stone suicide (filling own last liberty)
    g = setup(9, { { 2, 0 }, { 1, 1 }, { 0, 2 } }, { { 0, 0 }, { 1, 0 } }, W)
    ok, r = g:legal(0, 1); check(not ok and r == "suicide", "group suicide")
    -- surrounded point that captures is legal (not suicide)
    -- white (0,1): neighbours (0,0)B,(1,1)B,(0,2)W -> fine, and it captures (0,0)
    g = setup(9, { { 0, 0 }, { 1, 1 } }, { { 1, 0 }, { 0, 2 }, { 2, 1 }, { 1, 2 } }, W)
    ok, r = g:legal(0, 1)
    check(ok, "capturing move legal")
    -- truly zero-liberty move that captures: corner (0,0) surrounded, black (1,0) in atari
    g = setup(9, { { 1, 0 }, { 0, 1 } }, { { 2, 0 }, { 1, 1 }, { 0, 2 } }, W)
    local cap; ok, cap = g:play(0, 0)
    check(ok and #cap == 2, "zero-liberty point that captures is legal")
end

-- Ko --------------------------------------------------------------------------------------
do
    -- K=(1,2) surrounded by black (1,1),(0,2),(1,3); L=(2,2) black, surrounded by white (2,1),(3,2),(2,3).
    local g = setup(9, { { 1, 1 }, { 0, 2 }, { 1, 3 }, { 2, 2 } }, { { 2, 1 }, { 3, 2 }, { 2, 3 } }, W)
    local ok, cap = g:play(1, 2)
    check(ok and #cap == 1 and cap[1] == 2 * 9 + 2, "ko capture")
    eq(g.ko, 2 * 9 + 2, "ko point set")
    local r; ok, r = g:legal(2, 2); check(not ok and r == "ko", "immediate retake is ko")
    ok, r = g:play(2, 2); check(not ok and r == "ko", "play refuses ko")
    check(g:play(8, 8), "ko threat"); eq(g.ko, nil, "ko cleared by another move")
    check(g:play(8, 0), "answer")
    ok, cap = g:play(2, 2); check(ok and #cap == 1, "retake after ko lifted")
    eq(g.ko, 2 * 9 + 1, "ko now on the other side")
    -- a pass also lifts ko
    g:play(-1); eq(g.ko, nil, "pass clears ko")
end

-- Passes ----------------------------------------------------------------------------------
do
    local g = go.new(9)
    check(g:play(-1), "black pass"); eq(g.turn, W, "turn after pass")
    eq(g.moves[1].x, -1, "pass recorded"); eq(g.last.x, -1, "last is pass")
end

-- Coordinates -----------------------------------------------------------------------------
do
    eq(go.sgf(3, 3), "dd", "sgf dd"); eq(go.sgf(-1, -1), "..", "sgf pass")
    eq(go.sgf(0, 18), "as", "sgf as")
    local x, y = go.from_sgf("pd"); check(x == 15 and y == 3, "from_sgf pd")
    x, y = go.from_sgf(".."); check(x == -1 and y == -1, "from_sgf pass")
    x, y = go.from_sgf(""); check(x == -1 and y == -1, "from_sgf empty")
    local set = go.parse_points("iiaaee", 9)
    check(set[0] and set[40] and set[80], "parse_points")
    local n = 0; for _ in pairs(set) do n = n + 1 end; eq(n, 3, "parse_points count")
    eq(go.points_string(set, 9), "aaeeii", "points_string sorted")
    local s19 = "pddpdddppp"
    eq(go.points_string(go.parse_points(s19, 19), 19), "ddpddppp", "roundtrip 19 (sorted, deduped)")
    eq(go.points_string({}, 9), "", "empty points")
    eq(go.coord_name(3, 15, 19), "D4", "coord D4"); eq(go.coord_name(8, 0, 19), "J19", "coord skips I")
    eq(#go.star_points(19), 9, "19 hoshi"); eq(#go.star_points(13), 5, "13 hoshi")
    eq(#go.star_points(9), 5, "9 hoshi"); eq(#go.star_points(7), 0, "7 no hoshi")
    eq(go.star_points(9)[3], 40, "9x9 tengen")
end

-- from_gamedata ---------------------------------------------------------------------------
do
    -- fixed handicap via initial_state
    local g = go.from_gamedata({
        width = 19, height = 19, handicap = 2, komi = 0.5, rules = "japanese", phase = "play",
        initial_state = { black = "pddp", white = "" }, initial_player = "white",
        moves = { { 15, 15, 1200 } },
    })
    eq(g:at(15, 3), B, "fixed hcap stone 1"); eq(g:at(3, 15), B, "fixed hcap stone 2")
    eq(g:at(15, 15), W, "white first move"); eq(g.turn, B, "black to play")
    eq(g.komi, 0.5, "komi"); eq(g.rules, "japanese", "rules"); eq(g.phase, "play", "phase")
    check(g.last.x == 15 and g.last.y == 15, "last move")
    -- fixed handicap with empty initial_state falls back to standard points
    g = go.from_gamedata({ width = 19, height = 19, handicap = 3, initial_state = { black = "", white = "" },
        initial_player = "white", moves = {} })
    eq(g:at(15, 3), B, "fallback hcap TR"); eq(g:at(3, 15), B, "fallback hcap BL")
    eq(g:at(15, 15), B, "fallback hcap BR"); eq(g.turn, W, "white after fallback hcap")
    -- free handicap: first 2 moves black, then alternation; includes a pass
    g = go.from_gamedata({
        width = 19, height = 19, handicap = 2, free_handicap_placement = true, komi = 0.5,
        initial_state = { black = "", white = "" }, initial_player = "black",
        moves = { { 3, 3, 1 }, { 15, 15, 1 }, { 15, 3, 1 }, { -1, -1, 1 }, { 2, 2, 1 } },
    })
    eq(g:at(3, 3), B, "free hcap 1"); eq(g:at(15, 15), B, "free hcap 2")
    eq(g:at(15, 3), W, "white after free hcap"); eq(g.moves[4].x, -1, "pass in gamedata")
    eq(g.moves[4].color, B, "black passed"); eq(g:at(2, 2), W, "white after pass")
    eq(g.turn, B, "black to play after free hcap"); check(g.last.x == 2 and g.last.y == 2, "last after free hcap")
    -- last move a pass, plus captures replayed and removed string
    g = go.from_gamedata({ width = 9, height = 9, moves = { { 1, 0 }, { 0, 0 }, { 0, 1 }, { -1, -1 } },
        removed = "aiai", phase = "stone removal", rules = "chinese", komi = 7.5 })
    eq(g:at(0, 0), E, "capture replayed"); eq(g.captures[B], 1, "prisoner from replay")
    eq(g.last.x, -1, "last move pass"); eq(g.turn, B, "turn after pass")
    check(g.removed[8 * 9], "removed parsed"); eq(g.phase, "stone removal", "phase removal")
    -- clock.current_player wins over move parity
    g = go.from_gamedata({ width = 9, height = 9, moves = {}, players = { black = { id = 1 }, white = { id = 2 } },
        clock = { current_player = 2 } })
    eq(g.turn, W, "turn from clock")
    -- rectangular
    g = go.from_gamedata({ width = 13, height = 9, moves = { { 12, 8 } } })
    eq(g.w, 13, "rect w"); eq(g.h, 9, "rect h"); eq(g:at(12, 8), B, "rect corner")
end

-- Scoring ---------------------------------------------------------------------------------
--   x: 0 1 2 3 4 5 6 7 8
--      . . . X . O . . .      X = black wall on column 3 (9 stones)
--      . o . X . O . . .      O = white wall on column 5 (9 stones)
--      . o . X . O . . .      o = dead white stones at (1,1),(1,2)
--      . . . X . O . . .      x = dead black stone at (7,7)
--      . . . X . O . . .      column 4 is dame (9 points)
--      . . . X . O . . .
--      . . . X . O . . .
--      . . . X . O . x .
--      . . . X . O . . .
--  Prisoners before counting: black has captured 3, white has captured 1.
--  Black territory: columns 0-2 = 27 points (incl. the 2 dead-stone points).
--  White territory: columns 6-8 = 27 points (incl. the dead-stone point).
--  Japanese (komi 6.5): black = 27 terr + 3 prisoners + 2 dead = 32
--                       white = 27 terr + 1 prisoner + 1 dead + 6.5 = 35.5
--  Chinese  (komi 7.5): black = 9 stones + 27 terr = 36
--                       white = 9 stones + 27 terr + 7.5 = 43.5
do
    local function position(rules, komi)
        local g = go.new(9)
        for y = 0, 8 do g:place(3, y, B); g:place(5, y, W) end
        g:place(1, 1, W); g:place(1, 2, W); g:place(7, 7, B)
        g.captures = { [1] = 3, [2] = 1 }
        g.rules, g.komi = rules, komi
        return g
    end
    local g = position("japanese", 6.5)
    local dead = {}
    local changed, now = go.toggle_group_dead(g, dead, 1, 2)
    eq(#changed, 2, "toggle whole group"); eq(now, true, "now dead")
    check(dead[1 * 9 + 1] and dead[2 * 9 + 1], "both stones dead")
    changed, now = go.toggle_group_dead(g, dead, 1, 1)
    eq(now, false, "toggle back alive"); check(next(dead) == nil, "dead set emptied")
    go.toggle_group_dead(g, dead, 1, 1)
    go.toggle_group_dead(g, dead, 7, 7)
    local s = go.score(g, dead)
    eq(s.black, 32, "japanese black"); eq(s.white, 35.5, "japanese white")
    eq(s.territory[1 * 9 + 1], B, "dead stone point is black territory")
    eq(s.territory[7 * 9 + 7], W, "dead stone point is white territory")
    eq(s.territory[0], B, "corner black terr"); eq(s.territory[8], W, "corner white terr")
    check(s.dame[4] and s.dame[8 * 9 + 4], "column 4 dame"); eq(s.territory[4], nil, "dame not territory")
    eq(s.details.black.territory, 27, "black terr detail"); eq(s.details.black.dead, 2, "dead white detail")
    eq(s.details.scoring, "territory", "territory scoring")
    g = position("chinese", 7.5)
    s = go.score(g, dead)
    eq(s.black, 36, "chinese black"); eq(s.white, 43.5, "chinese white")
    eq(s.details.scoring, "area", "area scoring")
    -- without marking anything dead, the regions with enemy stones are not territory
    s = go.score(position("japanese", 6.5), {})
    eq(s.territory[0], nil, "region touching live white not territory"); eq(s.black, 3, "only prisoners")
    -- toggle on empty point
    changed, now = go.toggle_group_dead(g, {}, 4, 4); eq(#changed, 1, "empty toggle single"); eq(now, true, "empty now")
    -- empty board: everything dame
    s = go.score(go.new(9), {}); eq(s.black, 0, "empty board black"); check(s.dame[40], "empty board dame")
end

print(string.format("go_test: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
