local S = require("simlib")
local ui = require("core.ui")
local sud = require("apps.sudoku")
return {
  function()
    local t = os.clock()
    for lvl = 1, 4 do
      local p, sol = sud.generate(lvl)
      local blanks = 0
      for i = 1, 81 do if p[i] == 0 then blanks = blanks + 1 end end
      assert(sud.count_solutions(p, 2) == 1, "not unique")
      io.stderr:write(string.format("ok: level %d blanks %d unique\n", lvl, blanks))
    end
    io.stderr:write(string.format("gen time %.2fs\n", os.clock() - t))
  end,
  S.snap("sudoku_new"),
  function()  -- select first empty cell and put the right digit, plus one wrong one
    local scr = ui.top()
    local st = require("core.store").load("sudoku")
    local first, second
    for i = 1, 81 do if st.puzzle[i] == 0 then if not first then first = i elseif not second then second = i break end end end
    scr.sel = first; scr:input(st.solution[first])
    scr.sel = second; scr:input(st.solution[second] % 9 + 1)
    scr.notes_mode = true
    for i = second + 1, 81 do if st.puzzle[i] == 0 then scr.sel = i; scr:input(1); scr:input(5); scr:input(9) break end end
    scr.notes_mode = false
  end,
  S.tap_text("Check"),
  S.snap("sudoku_check"),
}
