local S = require("simlib")
local ui = require("core.ui")
return {
  S.snap("rss_empty"),
  S.tap_text("⟲"),
  S.wait(200),
  S.snap("rss_feeds"),
  S.tap_text("ycombinator"),
  S.snap("rss_items"),
  S.tap_text("Show HN"),
  S.snap("rss_summary"),
  S.tap_text("☰"), S.tap_text("Download full article"),
  S.wait_until(function() return ui.top().pages ~= nil and ui.top().pages[1] ~= nil end, 5000),
  S.snap("rss_full"),
  function() ui.back(); ui.back() end,
  S.tap_text("r/kindle"),
  S.tap_text("Just jailbroke"),
  S.snap("rss_reddit"),
}
