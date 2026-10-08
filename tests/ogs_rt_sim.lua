-- Simulator script: the OGS realtime socket driven by ui.run (ui.add_stream,
-- ui.every, ui.after). Run by tests/ogs_test.sh with OGS_BASE/OGS_WS pointing
-- at tests/mock_ogs.py. Uses the calculator app as a host and pushes a
-- minimal screen; doesn't depend on the OGS app screens.
local S = require("simlib")
local ui = require("core.ui")
local net = require("core.net")
local json = require("core.json")
local api = require("apps.ogs.api")
api.RECONNECT_MS = { 300, 600, 900 }

local BASE = os.getenv("OGS_BASE")
local st = { gamedata = 0, pongs = 0, connected = 0, log = {} }

local scr = {}
function scr:enter()
    api.load()
    local ok, err = api.login("test-client", "", "kindle", "hunter2")
    assert(ok, err)
    local rt = api.realtime()
    self.rt = rt
    rt:on("game/1001/gamedata", function(d)
        st.gamedata = st.gamedata + 1
        st.phase, st.nmoves = d.phase, #d.moves
    end)
    rt:on("game/1001/move", function(d)
        st.last = d
        st.log[#st.log + 1] = string.format("move %d: %d,%d", d.move_number, d.move[1], d.move[2])
    end)
    rt:on("net/pong", function() st.pongs = st.pongs + 1 end)
    rt:on("rt/connected", function() st.connected = st.connected + 1 end)
    assert(rt:connect())
    assert(rt:game_connect(1001))
end
function scr:leave() if self.rt then self.rt:close() end end
function scr:render(ctx)
    ctx:header("OGS realtime test")
    local y = ui.HEADER_H + ui.dp(30)
    local rt = self.rt
    ctx:text(ui.M, y, "socket: " .. ((rt and rt.connected) and "online" or "offline"))
    y = y + ui.dp(60)
    ctx:text(ui.M, y, "phase: " .. tostring(st.phase) .. "   moves: " .. tostring(st.nmoves))
    for _, l in ipairs(st.log) do
        y = y + ui.dp(50)
        ctx:text(ui.M, y, l)
    end
end

local function post(path) net.request({ method = "POST", url = BASE .. path }) end

return {
    function()
        post("/_mock/reset")
        ui.push(scr)
    end,
    S.wait_until(function() return st.phase == "play" end, 5000),
    S.check(function() return scr.rt.connected and ui.rt.streams[scr.rt.conn] end, "socket pumped by ui.run"),
    S.check(function()
        local t = ui.rt.timers[scr.rt.ping_timer]
        return t and t.every == 20000
    end, "ping timer registered with ui.every"),
    function() scr.rt:move(1001, 4, 2) end,
    S.wait_until(function() return st.last and st.last.move_number == 6 end, 5000),
    S.check(function() return st.last.move[1] == 4 and st.last.move[2] == 4 end, "opponent reply arrives via ui.run"),
    S.snap("ogs_rt"),
    function() scr.rt:_ping() end,
    S.wait_until(function() return st.pongs >= 1 end, 3000),
    S.check(function() return true end, "net/pong via ui.run"),
    function() post("/_mock/drop") end,
    S.wait_until(function() return st.connected >= 1 and st.gamedata >= 2 end, 6000),
    S.check(function() return scr.rt.connected end, "reconnected by ui.after backoff, game re-sent"),
    S.snap("ogs_rt_reconnected"),
}
