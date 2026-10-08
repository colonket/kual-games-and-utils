local S = require("simlib")
local ui = require("core.ui")
return {
  S.wait_until(function() return require("apps.lichess.app").session.events_ok end, 5000),
  S.tap_text("Quick pairing"),
  S.tap_text("15+10"),
  S.snap("s1_seek"),
  S.tap_text("Find opponent"),
  S.wait(400),
  S.snap("s2_seeking"),
  S.wait_until(function() local t = ui.top(); return t and t.pos and #t.pos.history == 1 end, 8000),
  S.wait(200),
  S.snap("s3_paired_black"),
  S.check(function() return ui.top().board.flipped end, "board flipped for black"),
}
