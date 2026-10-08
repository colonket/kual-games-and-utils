-- RFC 6455 WebSocket client on top of core/net (LuaSocket + LuaSec).
--
--   local conn, err = ws.connect("wss://host/", {
--       on_message = function(text) end, on_close = function(reason) end,
--       headers = {}, timeout = 20 })
--   conn:send(text); ui.add_stream(conn)
--
-- The opening handshake is blocking; afterwards the socket is non-blocking
-- and :pump() (called by ui.run like net.Stream) reads whatever has arrived,
-- reassembles frames that span several reads, answers pings and handles the
-- close handshake.
local ffi = require("ffi")
local bit = require("bit")
local net = require("core.net")
local sys = require("core.sys")

local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
local lshift, rshift, rol, tobit = bit.lshift, bit.rshift, bit.rol, bit.tobit
local byte, char, floor = string.byte, string.char, math.floor

local ws = {}
ws.GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
ws.max_message = 16 * 1024 * 1024

-- SHA-1 (pure Lua, bit ops) --------------------------------------------------------
local function u32be(n)
    return char(band(rshift(n, 24), 255), band(rshift(n, 16), 255), band(rshift(n, 8), 255), band(n, 255))
end

function ws.sha1(msg)
    local h0, h1, h2, h3, h4 = tobit(0x67452301), tobit(0xEFCDAB89), tobit(0x98BADCFE), tobit(0x10325476), tobit(0xC3D2E1F0)
    local ml = #msg
    local pad = (55 - ml) % 64
    local bits = ml * 8
    msg = msg .. "\128" .. string.rep("\0", pad)
        .. u32be(floor(bits / 4294967296)) .. u32be(bits % 4294967296)
    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            local a, b, c, d = byte(msg, chunk + i * 4, chunk + i * 4 + 3)
            w[i] = bor(lshift(a, 24), lshift(b, 16), lshift(c, 8), d)
        end
        for i = 16, 79 do
            w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
        end
        local a, b, c, d, e = h0, h1, h2, h3, h4
        for i = 0, 79 do
            local f, k
            if i < 20 then
                f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
            elseif i < 40 then
                f, k = bxor(b, c, d), 0x6ED9EBA1
            elseif i < 60 then
                f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
            else
                f, k = bxor(b, c, d), 0xCA62C1D6
            end
            local t = tobit(rol(a, 5) + f + e + k + w[i])
            e, d, c, b, a = d, c, rol(b, 30), a, t
        end
        h0, h1, h2, h3, h4 = tobit(h0 + a), tobit(h1 + b), tobit(h2 + c), tobit(h3 + d), tobit(h4 + e)
    end
    return u32be(h0) .. u32be(h1) .. u32be(h2) .. u32be(h3) .. u32be(h4)
end

-- Base64 ------------------------------------------------------------------------------
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function ws.base64(s)
    local out = {}
    for i = 1, #s, 3 do
        local a, b, c = byte(s, i, i + 2)
        local n = lshift(a, 16) + lshift(b or 0, 8) + (c or 0)
        local q1 = band(rshift(n, 18), 63) + 1
        local q2 = band(rshift(n, 12), 63) + 1
        local q3 = band(rshift(n, 6), 63) + 1
        local q4 = band(n, 63) + 1
        out[#out + 1] = B64:sub(q1, q1) .. B64:sub(q2, q2)
            .. (b and B64:sub(q3, q3) or "=") .. (c and B64:sub(q4, q4) or "=")
    end
    return table.concat(out)
end

-- Random bytes ------------------------------------------------------------------------
local seeded = false
function ws.random_bytes(n)
    local f = io.open("/dev/urandom", "rb")
    if f then
        local s = f:read(n)
        f:close()
        if s and #s == n then return s end
    end
    if not seeded then
        math.randomseed(sys.now() % 2147483647)
        seeded = true
    end
    local t = {}
    for i = 1, n do t[i] = char(math.random(0, 255)) end
    return table.concat(t)
end

function ws.accept_for(key)
    return ws.base64(ws.sha1(key .. ws.GUID))
end

-- XOR `data` with a 4-byte mask (used for client frames and, rarely, masked server frames)
local function apply_mask(data, mask)
    local n = #data
    if n == 0 then return "" end
    local buf = ffi.new("uint8_t[?]", n)
    ffi.copy(buf, data, n)
    local m0, m1, m2, m3 = byte(mask, 1, 4)
    local m = { [0] = m0, m1, m2, m3 }
    for i = 0, n - 1 do
        buf[i] = bxor(buf[i], m[i % 4])
    end
    return ffi.string(buf, n)
end
ws._apply_mask = apply_mask

local function frame(opcode, payload, fin)
    payload = payload or ""
    local n = #payload
    local head = char(bor(fin == false and 0 or 0x80, opcode))
    if n < 126 then
        head = head .. char(bor(0x80, n))
    elseif n < 65536 then
        head = head .. char(0x80 + 126, rshift(n, 8), band(n, 255))
    else
        head = head .. char(0x80 + 127) .. u32be(floor(n / 4294967296)) .. u32be(n % 4294967296)
    end
    local mask = ws.random_bytes(4)
    return head .. mask .. apply_mask(payload, mask)
end
ws._frame = frame

-- Connection --------------------------------------------------------------------------
local Conn = {}
Conn.__index = Conn

local function host_header(u)
    local default = (u.scheme == "wss") and 443 or 80
    if u.port == default then return u.host end
    return u.host .. ":" .. u.port
end

function ws.connect(url, opts)
    opts = opts or {}
    local u, perr = net.parse_url(url)
    if not u then return nil, perr end
    if u.scheme ~= "ws" and u.scheme ~= "wss" then
        return nil, "not a ws:// or wss:// url: " .. tostring(url)
    end
    local timeout = opts.timeout or net.timeout
    local sock, cerr = net.connect_socket(u, timeout)
    if not sock then return nil, cerr end
    local key = ws.base64(ws.random_bytes(16))
    local h = {
        "GET " .. u.path .. " HTTP/1.1",
        "Host: " .. host_header(u),
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: " .. key,
        "Sec-WebSocket-Version: 13",
        "User-Agent: " .. net.user_agent,
    }
    for k, v in pairs(opts.headers or {}) do h[#h + 1] = k .. ": " .. v end
    local ok, serr = net.send_all(sock, table.concat(h, "\r\n") .. "\r\n\r\n")
    if not ok then sock:close() return nil, "ws send: " .. tostring(serr) end
    local status, rh = net.read_head(sock)
    if not status then sock:close() return nil, "ws handshake: " .. tostring(rh) end
    if status ~= 101 then
        sock:close()
        return nil, "ws handshake: HTTP " .. status, status
    end
    if not (rh.upgrade or ""):lower():find("websocket", 1, true) then
        sock:close()
        return nil, "ws handshake: missing Upgrade: websocket"
    end
    local accept = (rh["sec-websocket-accept"] or ""):match("^%s*(.-)%s*$")
    if accept ~= ws.accept_for(key) then
        sock:close()
        return nil, "ws handshake: bad Sec-WebSocket-Accept"
    end
    sock:settimeout(0)
    return setmetatable({
        sock = sock, url = url,
        buf = "", frags = nil, frag_op = nil,
        on_message = opts.on_message, on_close = opts.on_close, on_binary = opts.on_binary,
        last_data = sys.now(), closed = false, send_timeout = timeout,
    }, Conn)
end

-- Write all of `data` to the non-blocking socket, waiting (briefly) while
-- the kernel buffer is full. Gives up after send_timeout seconds.
function Conn:_send_raw(data)
    local i = 1
    local deadline = sys.now() + (self.send_timeout or 15) * 1000
    while i <= #data do
        local sent, err, last = self.sock:send(data, i)
        if sent then
            i = sent + 1
        elseif err == "timeout" or err == "wantwrite" or err == "wantread" then
            i = (last or i - 1) + 1
            if i <= #data then
                if sys.now() > deadline then return nil, "send timeout" end
                sys.sleep_ms(5)
            end
        else
            return nil, err
        end
    end
    return true
end

-- Send a text message as one masked frame. Returns true or nil, err.
function Conn:send(text)
    if self.closed then return nil, "closed" end
    local ok, err = self:_send_raw(frame(0x1, tostring(text)))
    if not ok then
        self:close("send: " .. tostring(err))
        return nil, err
    end
    return true
end

function Conn:ping(data)
    if self.closed then return nil, "closed" end
    return self:_send_raw(frame(0x9, data or ""))
end

-- Parse as many complete frames from self.buf as possible.
function Conn:_parse()
    while not self.closed do
        local buf = self.buf
        local n = #buf
        if n < 2 then return end
        local b1, b2 = byte(buf, 1, 2)
        local fin = band(b1, 0x80) ~= 0
        local op = band(b1, 0x0F)
        local masked = band(b2, 0x80) ~= 0
        local len = band(b2, 0x7F)
        local pos = 3
        if len == 126 then
            if n < 4 then return end
            local x, y = byte(buf, 3, 4)
            len = x * 256 + y
            pos = 5
        elseif len == 127 then
            if n < 10 then return end
            local a, b, c, d, e, f, g, h = byte(buf, 3, 10)
            local hi = ((a * 256 + b) * 256 + c) * 256 + d
            local lo = ((e * 256 + f) * 256 + g) * 256 + h
            len = hi * 4294967296 + lo
            pos = 11
        end
        if len > ws.max_message then return self:close("frame too large") end
        local mask
        if masked then
            if n < pos + 3 then return end
            mask = buf:sub(pos, pos + 3)
            pos = pos + 4
        end
        if n < pos + len - 1 then return end
        local payload = buf:sub(pos, pos + len - 1)
        self.buf = buf:sub(pos + len)
        if mask then payload = apply_mask(payload, mask) end
        self:_frame(fin, op, payload)
    end
end

function Conn:_deliver(op, data)
    if op == 0x1 then
        if self.on_message then self.on_message(data) end
    elseif op == 0x2 then
        if self.on_binary then self.on_binary(data) end
    end
end

function Conn:_frame(fin, op, payload)
    if op >= 0x8 then
        if op == 0x8 then
            -- Close: echo the status code back, then drop the connection.
            local code = 1005
            if #payload >= 2 then code = byte(payload, 1) * 256 + byte(payload, 2) end
            local reason = payload:sub(3)
            if not self.close_sent then
                self.close_sent = true
                pcall(self._send_raw, self, frame(0x8, payload:sub(1, 2)))
            end
            self:_shutdown("server closed (" .. code .. (reason ~= "" and (" " .. reason) or "") .. ")")
        elseif op == 0x9 then
            pcall(self._send_raw, self, frame(0xA, payload))
        end
        -- 0xA pong: last_data was already refreshed.
        return
    end
    if op == 0x0 then
        if not self.frags then return self:close("unexpected continuation") end
        self.frags[#self.frags + 1] = payload
        self.frag_len = self.frag_len + #payload
        if self.frag_len > ws.max_message then return self:close("message too large") end
        if fin then
            local data = table.concat(self.frags)
            local fop = self.frag_op
            self.frags, self.frag_op = nil, nil
            self:_deliver(fop, data)
        end
        return
    end
    if fin then
        self:_deliver(op, payload)
    else
        self.frags, self.frag_op, self.frag_len = { payload }, op, #payload
    end
end

-- Read whatever is available. Returns true if any bytes arrived.
function Conn:pump()
    if self.closed then return false end
    local got = false
    local parts = {}
    local dead
    for _ = 1, 64 do
        local data, err, partial = self.sock:receive(8192)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            got = true
            parts[#parts + 1] = chunk
        end
        if err == "closed" then dead = true break end
        if err and err ~= "timeout" and err ~= "wantread" and err ~= "wantwrite" then
            dead = err
            break
        end
        if not data then break end
    end
    if got then
        self.last_data = sys.now()
        self.buf = self.buf .. table.concat(parts)
        self:_parse()
    end
    if dead and not self.closed then
        self:_shutdown(dead == true and "closed" or tostring(dead))
    end
    return got
end

function Conn:getfd()
    if self.closed then return nil end
    local ok, fd = pcall(function() return self.sock:getfd() end)
    if ok then return fd end
    return nil
end

function Conn:_shutdown(reason)
    if self.closed then return end
    self.closed = true
    pcall(function() self.sock:close() end)
    if self.on_close then self.on_close(reason or "closed") end
end

-- Close the connection (sends a 1000 close frame if still possible).
function Conn:close(reason)
    if self.closed then return end
    if not self.close_sent then
        self.close_sent = true
        pcall(self._send_raw, self, frame(0x8, char(0x03, 0xE8)))
    end
    self:_shutdown(reason or "closed")
end

ws.Conn = Conn
return ws
