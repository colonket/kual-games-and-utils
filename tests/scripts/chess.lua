local S = require("simlib")
local ui = require("core.ui")
return {
  S.tap_text("New game"), S.tap_text("Play White vs computer"),
  S.tap_square("e2"), S.tap_square("e4"),
  S.wait_until(function() return #ui.top().pos.history == 2 end, 20000),
  S.tap_square("d1"), S.tap_square("h5"),
  S.wait_until(function() return #ui.top().pos.history == 4 end, 20000),
  S.tap_square("f1"), S.tap_square("c4"),
  S.wait_until(function() return #ui.top().pos.history == 6 end, 20000),
  S.snap("chess_local"),
  S.tap_text("Undo"),
  S.check(function() return #ui.top().pos.history == 4 end, "undo takes back a full move vs computer"),
}
