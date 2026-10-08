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
  -- the HN "Comments" link in the item summary opens the discussion
  S.tap_text("Comments"),
  S.wait_until(function() return S.find_hit("reply") ~= nil end, 5000),
  S.snap("rss_hn_comments"),
  S.check(function() return S.find_hit("reply").data.href == "item?id=4243" end, "HN comments page has its reply link"),
  -- relative links resolve against the page they're on
  S.tap_text("reply"),
  S.wait_until(function() return ui.top().pages ~= nil and S.find_hit("reply") == nil end, 5000),
  S.check(function() return ui.top().pages[1][1].text:find("Reply thread", 1, true) ~= nil end, "relative link opened"),
  function() ui.back(); ui.back() end,
  S.tap_text("☰"), S.tap_text("Download full article"),
  S.wait_until(function() return ui.top().pages ~= nil and ui.top().pages[1] ~= nil end, 5000),
  S.snap("rss_full"),
  function() ui.back(); ui.back() end,
  S.tap_text("r/kindle"),
  S.tap_text("Just jailbroke"),
  S.snap("rss_reddit"),
}
