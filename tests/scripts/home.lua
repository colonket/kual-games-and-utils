-- The app launcher (also used for the README screenshot).
local S = require("simlib")
local ui = require("core.ui")
return {
  S.snap("home"),
  S.check(function() return S.find_hit("Lichess") ~= nil and S.find_hit("Sudoku") ~= nil end, "launcher lists the apps"),
}
