local S = require("simlib")
local ui = require("core.ui")
return {
  S.wait(200),
  S.tap_text("Search for a place"),
  function() local kb = ui.top(); kb.text = "Chicago" end,
  S.tap_text("DONE"),
  S.wait(300),
  S.tap_text("Chicago"),
  S.wait_until(function() return ui.top().data ~= nil end, 5000),
  S.snap("weather"),
}
