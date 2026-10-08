-- OGS screens against the stub API (tests/ogs_stub_api.lua).
-- Run:  tests/sim.sh calculator tests/scripts/ogs_ui.lua /tmp/sim_ogs [W H DPI]
-- (starts in another app because the registry loads apps.ogs.app lazily)
local S = require("simlib")
local ui = require("core.ui")
local input = require("core.input")

-- Until workstream A's go.lua/goboard.lua exist, use the stand-ins in tests/stubs.
local root = os.getenv("EINK_APPS_ROOT")
local real = io.open(root .. "/lua/apps/lib/go.lua", "r")
if real then real:close() else
    package.path = root .. "/../../tests/stubs/?.lua;" .. package.path
end
os.remove(root .. "/data/ogs_prefs.json") -- start from default challenge settings

local api
local function top() return ui.top() end
local function called(name)
    for _, c in ipairs(api.calls) do if c[1] == name then return c end end
end
local function last_call(name)
    for i = #api.calls, 1, -1 do if api.calls[i][1] == name then return api.calls[i] end end
end
local function tap_pt(x, y)
    return function()
        if ui.rt.dirty then ui.render_now() end
        local px, py = top().board:point_xy(x, y)
        input.inject({ type = "tap", x = px, y = py })
    end
end
local function at(x, y) local g = top().g; return g.board[y * g.w + x] end

return {
  function()
    package.loaded["apps.ogs.api"] = require("ogs_stub_api")
    api = package.loaded["apps.ogs.api"]
    require("apps.registry").open("ogs")
  end,
  S.wait_until(function() return top().games ~= nil end, 3000),
  S.snap("01_lobby"),
  S.check(function() return #top().games == 2 and top().games[1].id == 1001 end, "lobby lists my-turn game first"),
  S.tap_text("sensei"),
  S.wait_until(function() return top().g ~= nil and top().subscribed end, 3000),
  S.wait(150),
  S.snap("02_game9"),
  S.check(function() return top().my_color == 1 and top():my_turn() end, "my turn as black"),
  -- pending stone, then move it, then an illegal tap
  tap_pt(6, 4),
  S.check(function() local p = top().pending; return p and p.x == 6 and p.y == 4 end, "pending set"),
  tap_pt(4, 6),
  S.check(function() local p = top().pending; return p and p.x == 4 and p.y == 6 end, "pending moved"),
  S.snap("03_pending"),
  tap_pt(4, 4),
  S.check(function() return ui.rt.toast_msg ~= nil and top().pending.x == 4 end, "occupied point -> toast"),
  S.snap("04_illegal"),
  S.tap_text("Confirm", 1),
  S.check(function() return at(4, 6) == 1 end, "optimistic stone shown"),
  S.wait_until(function() return top().nmoves == 8 and top().sent == nil end, 3000),
  S.wait(100),
  S.snap("05_reply"),
  S.check(function() local c = last_call("move"); return c[3] == 4 and c[4] == 6 end, "rt:move sent E3"),
  -- a failed send reverts the optimistic stone
  function() api.fail_moves = true end,
  tap_pt(8, 8), tap_pt(8, 8),
  S.check(function() return at(8, 8) == 0 and top().nmoves == 8 and top().sent == nil end, "failed move reverted"),
  S.snap("06_revert"),
  function() api.fail_moves = false; ui.rt.toast_msg = nil; ui.redraw() end,
  -- pass -> opponent passes -> stone removal
  S.tap_text("Pass"),
  S.snap("07_pass_confirm"),
  S.tap_text("Pass"),
  S.wait_until(function() return top().phase == "stone removal" and next(top().dead) ~= nil end, 3000),
  S.wait(100),
  S.snap("08_removal"),
  tap_pt(2, 2),
  S.check(function() local c = last_call("removed_set"); return c and c[3] == true and c[4] == "cc" end, "removed_set sent for C7"),
  S.wait(150),
  S.snap("09_removal_toggled"),
  tap_pt(2, 2),
  S.check(function() local c = last_call("removed_set"); return c[3] == false end, "toggled back alive"),
  S.wait(150),
  S.tap_text("Accept score"),
  S.wait_until(function() return top().phase == "finished" and top().result ~= nil end, 3000),
  S.wait(100),
  S.snap("10_finished"),
  S.check(function() return top():result_text():find("^You") ~= nil end, "result text: " .. "you won/lost"),
  S.tap_text("Back to games"),
  S.wait(100),
  S.snap("11_lobby_after"),
  S.check(function() return top().games ~= nil and #top().games == 1 end, "finished game dropped from list"),
  -- accept the incoming challenge -> its game opens; resign it
  S.tap_text("Accept"),
  S.wait_until(function() return top().id == 1003 and top().g ~= nil end, 3000),
  S.wait(150),
  S.snap("12_challenge_game13"),
  S.tap_text("Resign"),
  S.snap("13_resign_confirm"),
  S.tap_text("Resign"),
  S.wait_until(function() return top().phase == "finished" and top().result ~= nil end, 3000),
  S.wait(100),
  S.snap("14_resigned"),
  S.check(function() return top():result_text() == "You lost by resignation" end, "resign result"),
  S.tap_text("Back to games"),
  -- the live 19x19 game, opponent to move
  S.wait(100),
  S.tap_text("tengen"),
  S.wait_until(function() return top().g ~= nil and top().subscribed end, 3000),
  S.wait(150),
  S.snap("15_game19"),
  tap_pt(10, 10),
  S.check(function() return top().pending == nil and ui.rt.toast_msg ~= nil end, "not my turn -> toast"),
  S.wait(1100),
  S.snap("16_game19_tick"),
  S.tap_text("back"),
  -- challenge a friend
  S.wait(100),
  S.tap_text("Challenge a friend"),
  S.snap("17_challenge"),
  S.tap_text("Tap to type…"),
  S.tap_text("b"), S.tap_text("o"), S.tap_text("b"), S.tap_text("DONE"),
  S.tap_text("13×13"), S.tap_text("Corresp. 3 days"), S.tap_text("White"), S.tap_text("Ranked game"),
  S.snap("18_challenge_filled"),
  S.tap_text("Send challenge"),
  S.check(function()
    local c = api.last_challenge
    local o = c and c.opts
    return o and c.player_id == 77 and o.size == 13 and o.speed == "correspondence" and o.main_time == 259200
      and o.increment == 86400 and o.color == "white" and o.ranked == true
  end, "challenge_player opts"),
  S.wait(100),
  S.snap("19_challenge_sent"),
  -- sign out -> login screen -> bad then good credentials
  function() ui.rt.toast_msg = nil; ui.redraw() end,
  S.tap_text("Sign out"),
  S.tap_text("Sign out"),
  S.wait(100),
  S.snap("20_login"),
  function() local t = top(); t.client_id, t.username, t.password = "test-client", "kindle", "wrong"; ui.redraw() end,
  S.tap_text("Sign in"),
  S.check(function() return top().msg ~= nil and top().password == "" end, "bad login shows error, clears password"),
  S.snap("21_login_error"),
  function() top().password = "hunter2"; ui.redraw() end,
  S.tap_text("Sign in"),
  S.wait_until(function() return top().games ~= nil end, 3000),
  S.check(function() local c = last_call("login"); return c[2] == "test-client" end, "signed in again"),
  S.snap("22_lobby_again"),
}
