local S = require("simlib")
local ui = require("core.ui")
return {
  S.tap_text("Search Wikipedia"),
  function() ui.top().text = "magic" end,
  S.tap_text("DONE"),
  S.snap("wiki_results"),
  S.tap_text("Magic: The Gathering"),
  S.wait_until(function() return ui.top().pages ~= nil end, 5000),
  S.snap("wiki_page1"),
  S.tap(900, 700), S.tap(900, 700),
  S.snap("wiki_page3"),
  S.tap_text("☰"), S.tap_text("Save for offline"),
  S.tap_text("☰"), S.tap_text("Export to Kindle"),
  S.wait(100),
  function() ui.back() end,
  S.snap("wiki_home"),
}
