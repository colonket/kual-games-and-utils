-- core/ws.lua tests. Run through tests/ws_test.sh, which starts
-- tests/ws_echo_server.py (plain on WS_PORT, TLS on WSS_PORT) and sets
-- WS_CERT to the self-signed certificate.
local sys = require("core.sys")
local net = require("core.net")
local ws = require("core.ws")

local WS_PORT = os.getenv("WS_PORT") or "8723"
local WSS_PORT = os.getenv("WSS_PORT") or "8724"
local CERT = os.getenv("WS_CERT")

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then
        passed = passed + 1
        io.stderr:write("ok: ", msg, "\n")
    else
        failed = failed + 1
        io.stderr:write("FAIL: ", msg, "\n")
    end
end

local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

-- Pump until pred() or timeout; returns pred()
local function wait(conn, pred, ms)
    local deadline = sys.now() + (ms or 5000)
    while sys.now() < deadline do
        if pred() then return true end
        local fd = conn:getfd()
        if fd then sys.poll({ fd }, 20) else sys.sleep_ms(5) end
        conn:pump()
    end
    return pred()
end

local function open(url)
    local st = { msgs = {}, closed = nil }
    local conn, err = ws.connect(url, {
        timeout = 5,
        on_message = function(t) st.msgs[#st.msgs + 1] = t end,
        on_close = function(r) st.closed = r end,
    })
    st.conn = conn
    return st, err
end

-- Next unread message (a cursor, so several messages from one read work)
local function next_msg(st, ms)
    st.rd = st.rd or 0
    if wait(st.conn, function() return #st.msgs > st.rd or st.closed end, ms) and #st.msgs > st.rd then
        st.rd = st.rd + 1
        return st.msgs[st.rd]
    end
end

local function pattern(n, unit)
    return (string.rep(unit, math.floor(n / #unit) + 1)):sub(1, n)
end

-- Redirect mode: run with EINK_NET_REDIRECT set ------------------------------------
if os.getenv("EINK_NET_REDIRECT") then
    local redir = os.getenv("EINK_NET_REDIRECT")
    local u = net.parse_url("wss://online-go.com/")
    check(u.scheme == "ws" and u.host == "127.0.0.1" and u.port == tonumber(WS_PORT)
        and u.path == "/online-go.com/", "redirect maps wss://host/ to ws://<redirect>/host/ (" .. u.scheme .. " " .. u.path .. ")")
    local h = net.parse_url("https://online-go.com/api/v1/me")
    check(h.scheme == "http" and h.path == "/online-go.com/api/v1/me", "redirect still maps https to http")
    local same = net.parse_url(redir .. "/x")
    check(same.path == "/x", "urls already on the redirect host are untouched")
    local st, err = open("wss://online-go.com/")
    check(st.conn ~= nil, "wss url connects through redirect: " .. tostring(err))
    if st.conn then
        st.conn:send("via-redirect")
        check(next_msg(st) == "via-redirect", "echo through redirect")
        st.conn:close()
    end
    io.stderr:write(string.format("ws redirect tests: %d passed, %d failed\n", passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

-- Primitives -----------------------------------------------------------------------
check(hex(ws.sha1("abc")) == "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 abc")
check(hex(ws.sha1("")) == "da39a3ee5e6b4b0d3255bfef95601890afd80709", "sha1 empty")
check(hex(ws.sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"))
    == "84983e441c3bd26ebaae4aa1f95129e5e54670f1", "sha1 448-bit")
check(hex(ws.sha1(string.rep("a", 1000000))) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f", "sha1 million a")
check(ws.base64("") == "" and ws.base64("f") == "Zg==" and ws.base64("fo") == "Zm8="
    and ws.base64("foo") == "Zm9v" and ws.base64("foobar") == "Zm9vYmFy", "base64 vectors")
check(ws.accept_for("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "RFC 6455 accept example")
local f = ws._frame(1, "Hi")
check(#f == 2 + 4 + 2 and f:byte(1) == 0x81 and f:byte(2) == 0x82, "client frame is masked")
check(ws._apply_mask(f:sub(7), f:sub(3, 6)) == "Hi", "mask round-trips")
check(#ws._frame(1, string.rep("x", 126)) == 2 + 2 + 4 + 126, "16-bit length frame")
check(#ws._frame(1, string.rep("x", 65536)) == 2 + 8 + 4 + 65536, "64-bit length frame")

local u = net.parse_url("wss://example.org/socket")
check(u.scheme == "wss" and u.port == 443 and u.path == "/socket", "parse wss default port")
local u2 = net.parse_url("ws://example.org:81")
check(u2.port == 81 and u2.path == "/", "parse ws explicit port")
local u3 = net.parse_url("https://example.org/a")
check(u3.port == 443, "https default port unchanged")

-- Plain ws -------------------------------------------------------------------------
local base = "ws://127.0.0.1:" .. WS_PORT
local st, err = open(base .. "/")
check(st.conn ~= nil, "connect " .. base .. " " .. tostring(err))
if st.conn then
    local c = st.conn
    check(c:send("hello"), "send")
    check(next_msg(st) == "hello", "echo small text")
    local m200 = pattern(200, "0123456789")
    c:send(m200)
    check(next_msg(st) == m200, "echo 200-byte (16-bit length)")
    local big = pattern(70000, "The quick brown fox ")
    c:send(big)
    check(next_msg(st) == big, "echo 70000-byte (64-bit length)")
    local utf = "Go 囲碁 ★ \"quotes\""
    c:send(utf)
    check(next_msg(st) == utf, "echo utf-8")

    c:send("frag:100000")
    local fr = next_msg(st)
    check(fr == pattern(100000, "0123456789"), "fragmented message reassembled (" .. tostring(fr and #fr) .. " bytes)")

    c:send("trickle:300")
    check(next_msg(st) == pattern(300, "abcdefghij"), "partial frame across reads (300)")
    check(next_msg(st) == "t1" and next_msg(st) == "t2", "two frames in one read")
    c:send("trickle:70000")
    check(next_msg(st, 10000) == pattern(70000, "abcdefghij"), "partial 64-bit frame across reads")
    check(next_msg(st) == "t1" and next_msg(st) == "t2", "two frames in one read again")

    c:send("ping:abc")
    check(next_msg(st) == "pong:abc", "server ping answered with matching pong")

    c:send("stats")
    check(next_msg(st) == "unmasked:0", "server saw only masked frames")

    local before = c.last_data
    sys.sleep_ms(20)
    c:send("x")
    next_msg(st)
    check(c.last_data > before, "last_data advances")
    check(type(c:getfd()) == "number", "getfd")

    c:send("close")
    check(wait(c, function() return st.closed ~= nil end), "server close handled")
    check(c.closed and tostring(st.closed):find("1000", 1, true) ~= nil, "close reason has code: " .. tostring(st.closed))
    check(c:getfd() == nil and c:send("late") == nil, "closed conn rejects send")
end

-- client-initiated close
local st2 = open(base .. "/")
if st2.conn then
    st2.conn:close("bye")
    check(st2.conn.closed and st2.closed == "bye", "client close calls on_close")
end

-- Handshake failures
local s1 = open(base .. "/bad-accept")
check(s1.conn == nil, "bad Sec-WebSocket-Accept rejected")
local c1, e2 = ws.connect(base .. "/bad-accept", { timeout = 3 })
check(c1 == nil and tostring(e2):find("Accept"), "error mentions Accept: " .. tostring(e2))
local c3, e3 = ws.connect(base .. "/plain", { timeout = 3 })
check(c3 == nil and tostring(e3):find("HTTP 200"), "non-101 rejected: " .. tostring(e3))
local c4, e4 = ws.connect("http://127.0.0.1:" .. WS_PORT .. "/", { timeout = 3 })
check(c4 == nil, "http:// url refused: " .. tostring(e4))
local c5, e5 = ws.connect("ws://127.0.0.1:1/", { timeout = 3 })
check(c5 == nil, "connection refused reported: " .. tostring(e5))

-- server going away without a close frame
-- (covered by the mock_ogs reconnect test)

-- TLS ------------------------------------------------------------------------------
if CERT and net.has_tls() then
    net.cafile = CERT
    net.insecure = false
    local sx, ex = open("wss://127.0.0.1:" .. WSS_PORT .. "/")
    check(sx.conn ~= nil, "wss connect with cafile=self-signed cert: " .. tostring(ex))
    if sx.conn then
        sx.conn:send("secure hello")
        check(next_msg(sx) == "secure hello", "wss echo")
        local big = pattern(70000, "TLS!")
        sx.conn:send(big)
        check(next_msg(sx) == big, "wss 70000-byte echo")
        sx.conn:send("frag:20000")
        check(next_msg(sx) == pattern(20000, "0123456789"), "wss fragmented")
        sx.conn:send("trickle:5000")
        check(next_msg(sx) == pattern(5000, "abcdefghij"), "wss trickle (wantread)")
        check(next_msg(sx) == "t1" and next_msg(sx) == "t2", "wss two frames")
        sx.conn:close()
    end
    -- wrong trust anchor: must fail verification
    local other = os.getenv("WS_OTHER_CA")
    if other then
        net.cafile = other
        local sy, ey = open("wss://127.0.0.1:" .. WSS_PORT .. "/")
        check(sy.conn == nil and tostring(ey):find("tls"), "untrusted cert rejected: " .. tostring(ey))
    end
    net.cafile = nil
else
    io.stderr:write("skip: TLS tests (no WS_CERT or LuaSec)\n")
end

io.stderr:write(string.format("ws tests: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
