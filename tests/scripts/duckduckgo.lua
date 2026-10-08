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
  -- links on a result page open in DuckDuckGo's reader, with its Save action
  S.check(function() return S.find_hit("KUAL") == nil end, "#fragment links aren't tappable"),
  -- "Discuss on HN" wraps, so it's two tap areas with the same target
  S.check(function()
    local a, b = S.find_hit("Discuss on"), S.find_hit("HN")
    return a and b and a.data.href == b.data.href and a.y ~= b.y
  end, "a link wrapped across lines is tappable on both lines"),
  S.tap_text("Discuss on"),
  S.wait_until(function() return S.find_hit("reply") ~= nil end, 5000),
  S.snap("ddg_hn_comments"),
  S.tap_text("☰"),
  S.check(function() return S.find_hit("Save for offline reading") ~= nil end, "linked page can be saved"),
}
