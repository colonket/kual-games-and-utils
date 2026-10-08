local S = require("simlib")
local ui = require("core.ui")
return {
  S.tap_text("Search the web"),
  S.snap("ddg_keyboard_empty"),
  S.tap_text("k"), S.tap_text("i"), S.tap_text("n"), S.tap_text("d"), S.tap_text("l"), S.tap_text("e"),
  S.snap("ddg_keyboard"),
  S.tap_text("DONE"),
  S.snap("ddg_results"),
  S.tap_text("KUAL & KOReader guide"),
  S.wait_until(function() return ui.top().pages ~= nil end, 5000),
  S.snap("ddg_page"),
}
