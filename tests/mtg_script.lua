local S = require("simlib")
local ui = require("core.ui")
local input = require("core.input")
local mtg = require("apps.mtg")
local W, H = 1072, 1448
local function menu(n)
  return function()
    local _, j = mtg._layout(W, H, n)
    input.inject({ type = "tap", x = math.floor(j[1]), y = math.floor(j[2]) })
  end
end
-- tap at a point in panel i's local coords (fractions)
local function ptap(n, i, fx, fy, kind)
  return function()
    local rects = mtg._layout(W, H, n)
    local r = rects[i]
    local rot = ui.top().rects and require("core.store").load("mtg").players[i].rot or 0
    -- invert to_local: search the pixel
    for y = r[2], r[2] + r[4] - 1, 4 do
      for x = r[1], r[1] + r[3] - 1, 4 do
        local lx, ly, lw, lh = mtg._to_local(r, rot, x, y)
        if math.abs(lx - fx * lw) < 4 and math.abs(ly - fy * lh) < 4 then
          input.inject({ type = kind or "tap", x = x, y = y }); return
        end
      end
    end
    error("point not found")
  end
end
return {
  S.snap("m1_setup"),
  S.tap_text("Start"),
  S.snap("m2_4p"),
  ptap(4, 1, 0.25, 0.5), ptap(4, 1, 0.25, 0.5), ptap(4, 1, 0.25, 0.5),
  ptap(4, 3, 0.75, 0.5, "hold"),
  S.snap("m3_changed"),
  ptap(4, 2, 0.5, 0.95),
  S.snap("m4_detail"),
  S.tap_text("−10"), S.tap_text("−10"),
  function() -- commander damage from player 1: tap + 21 times
     for k = 1, 3 do end
  end,
  S.tap_text("Done"),
  S.snap("m5_after_detail"),
  menu(4),
  S.snap("m6_menu"),
  S.tap_text("New game setup"),
  S.tap_text("6"),
  S.tap_text("Start"),
  S.snap("m7_6p"),
  menu(6), S.tap_text("New game setup"), S.tap_text("3"), S.tap_text("Start"),
  S.snap("m8_3p"),
  menu(3), S.tap_text("New game setup"), S.tap_text("2"), S.tap_text("Start"),
  S.snap("m9_2p"),
}
