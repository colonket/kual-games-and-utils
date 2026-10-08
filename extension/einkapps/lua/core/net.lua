-- HTTP(S) client on top of LuaSocket + LuaSec (both ship with KOReader).
-- Blocking requests for simple calls, plus non-blocking line streams for
-- APIs like Lichess that push NDJSON events.
local socket = require("socket")
local ok_ssl, ssl = pcall(require, "ssl")
local sys = require("core.sys")

local net = {}
net.user_agent = "KindleEinkApps/1.0 (+https://github.com/; KUAL)"
net.cafile = nil
net.insecure = false     -- Settings' "skip certificate checks"; never applies to net.always_verify
net.timeout = 25
-- Hosts (and their subdomains) that carry account credentials: certificate
-- checks stay on for these even when net.insecure is set.
net.always_verify = { "online-go.com", "lichess.org" }

function net.has_tls() return ok_ssl end

function net.urlencode(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function net.urldecode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

function net.form(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if v ~= nil then
            if type(v) == "boolean" then v = v and "true" or "false" end
            parts[#parts + 1] = net.urlencode(k) .. "=" .. net.urlencode(v)
        end
    end
    return table.concat(parts, "&")
end

local REDIRECT = os.getenv("EINK_NET_REDIRECT")   -- simulator: route all traffic to a mock

-- Scheme of the redirect target switched to WebSocket (http->ws, https->wss).
local WS_REDIRECT = REDIRECT and (REDIRECT:gsub("^(%a+)://", function(s)
    return (s:lower() == "https" and "wss" or "ws") .. "://"
end))

local DEFAULT_PORT = { http = 80, https = 443, ws = 80, wss = 443 }
local TLS_SCHEMES = { https = true, wss = true }

local function parse_url(url)
    if REDIRECT and not url:find(REDIRECT, 1, true) then
        local sch = (url:match("^(%a+)://") or ""):lower()
        if sch == "ws" or sch == "wss" then
            -- wss://host/path -> ws://<redirect host>/host/path
            if not url:find(WS_REDIRECT, 1, true) then
                url = url:gsub("^%a+://", WS_REDIRECT .. "/")
            end
        else
            url = url:gsub("^%a+://", REDIRECT .. "/")
        end
    end
    local scheme, rest = url:match("^(%a+)://(.+)$")
    if not scheme then return nil, "bad url: " .. tostring(url) end
    scheme = scheme:lower()
    local hostport, path = rest:match("^([^/?#]+)(.*)$")
    if not hostport then return nil, "bad url" end
    if path == "" then path = "/" end
    path = path:gsub("#.*$", "")
    -- the path goes into the request line verbatim: escape spaces and control
    -- characters so a crafted link can't inject CR/LF (extra headers)
    path = path:gsub("[%c ]", function(c) return string.format("%%%02X", c:byte()) end)
    local host, port = hostport:match("^(.-):(%d+)$")
    host = host or hostport
    -- plain hostnames, IPv4 or [IPv6] only (no userinfo "user@", spaces or CR/LF)
    if not (host:match("^[%w%.%-_]+$") or host:match("^%[[%x:%.]+%]$")) then
        return nil, "bad host in url: " .. host:gsub("%c", "?")
    end
    port = tonumber(port) or DEFAULT_PORT[scheme] or 80
    return { scheme = scheme, host = host, port = port, path = path }
end
net.parse_url = parse_url

-- Does a certificate name (possibly "*.example.com") cover host? RFC 6125:
-- a wildcard is only the whole leftmost label and needs two labels after it.
local function name_matches(pattern, host)
    pattern = tostring(pattern):lower():gsub("%.$", "")
    host = host:lower():gsub("%.$", "")
    if pattern == host then return true end
    local rest = pattern:match("^%*%.(.+)$")
    if not rest or not rest:find(".", 1, true) then return false end
    local tail = host:match("^[^.]+%.(.+)$")
    return tail == rest
end
net.name_matches = name_matches

-- Check the peer certificate's subjectAltName against the host we dialled.
-- LuaSec verifies the chain but not the name, so without this any valid
-- certificate for any domain would be accepted.
local function verify_host(conn, host)
    local cert = conn.getpeercertificate and conn:getpeercertificate()
    if not cert then return nil, "no peer certificate" end
    local ok, ext = pcall(cert.extensions, cert)
    local san = ok and type(ext) == "table" and ext["2.5.29.17"]
    if type(san) ~= "table" then return nil, "certificate has no subjectAltName" end
    local bare = host:match("^%[(.*)%]$")
    if bare or host:match("^%d+%.%d+%.%d+%.%d+$") then
        for _, ip in ipairs(san.iPAddress or {}) do
            if tostring(ip):lower() == (bare or host):lower() then return true end
        end
    else
        for _, name in ipairs(san.dNSName or {}) do
            if name_matches(name, host) then return true end
        end
    end
    return nil, "certificate is not for " .. host
end

local function must_verify(host)
    if not net.insecure then return true end
    host = host:lower()
    for _, d in ipairs(net.always_verify) do
        if host == d or host:sub(-(#d + 1)) == "." .. d then return true end
    end
    return false
end
net.must_verify = must_verify

-- Resolve a possibly relative URL against a base URL.
function net.resolve(base, href)
    if not href or href == "" then return base end
    if href:match("^%a+://") then return href end
    local u = parse_url(base)
    if not u then return href end
    local origin = u.scheme .. "://" .. u.host .. ((u.port == 80 or u.port == 443) and "" or (":" .. u.port))
    if href:sub(1, 2) == "//" then return u.scheme .. ":" .. href end
    if href:sub(1, 1) == "/" then return origin .. href end
    local dir = u.path:gsub("[?#].*$", ""):gsub("[^/]*$", "")
    return origin .. dir .. href
end

-- Open a TCP connection (TLS-wrapped for https/wss) to a parsed URL.
-- Returns a blocking socket with `timeout` set, or nil, err. Shared by
-- requests, NDJSON streams and core/ws.lua.
local function connect(u, timeout)
    local sock = socket.tcp()
    sock:settimeout(timeout)
    local ok, err = sock:connect(u.host, u.port)
    if not ok then sock:close() return nil, "connect " .. u.host .. ": " .. tostring(err) end
    if TLS_SCHEMES[u.scheme] then
        if not ok_ssl then sock:close() return nil, "TLS not available (LuaSec missing)" end
        local params = {
            mode = "client",
            protocol = "any",
            options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1", "no_tlsv1_1" },
            verify = "none",
        }
        local verify = must_verify(u.host)
        if verify then
            -- fail closed: a missing bundle must not quietly turn checks off
            if not (net.cafile and sys.file_exists(net.cafile)) then
                sock:close()
                return nil, "tls: certificate bundle missing (" .. tostring(net.cafile) .. ")"
            end
            params.verify = "peer"
            params.cafile = net.cafile
        end
        local conn, werr = ssl.wrap(sock, params)
        if not conn then sock:close() return nil, "tls: " .. tostring(werr) end
        if conn.sni then conn:sni(u.host) end
        conn:settimeout(timeout)
        local hok, herr = conn:dohandshake()
        if not hok then
            conn:close()
            local msg = tostring(herr)
            if msg:find("certificate") then
                msg = msg .. " (is the Kindle's date/time correct?)"
            end
            return nil, "tls handshake: " .. msg
        end
        if verify then
            local vok, verr = verify_host(conn, u.host)
            if not vok then
                conn:close()
                return nil, "tls: " .. verr
            end
        end
        return conn
    end
    return sock
end

net.connect_socket = connect

local function send_all(sock, data)
    local i = 1
    while i <= #data do
        local sent, err, last = sock:send(data, i)
        if sent then i = sent + 1
        elseif err == "timeout" or err == "wantwrite" or err == "wantread" then
            i = (last or i - 1) + 1
            socket.sleep(0.01)
        else
            return nil, err
        end
    end
    return true
end

local function build_request(method, u, headers, body)
    local h = {
        string.format("%s %s HTTP/1.1", method, u.path),
        "Host: " .. u.host,
        "User-Agent: " .. net.user_agent,
        "Accept-Encoding: identity",
    }
    local has = {}
    for k, v in pairs(headers or {}) do
        h[#h + 1] = k .. ": " .. v
        has[k:lower()] = true
    end
    if not has["connection"] then h[#h + 1] = "Connection: close" end
    if body then
        if not has["content-type"] then h[#h + 1] = "Content-Type: application/x-www-form-urlencoded" end
        h[#h + 1] = "Content-Length: " .. #body
    elseif method == "POST" then
        h[#h + 1] = "Content-Length: 0"
    end
    return table.concat(h, "\r\n") .. "\r\n\r\n" .. (body or "")
end

local function read_head(sock)
    local line, err = sock:receive("*l")
    if not line then return nil, "no response: " .. tostring(err) end
    local status = tonumber(line:match("^HTTP/%d%.?%d?%s+(%d+)"))
    if not status then return nil, "bad status line: " .. line end
    local headers = {}
    while true do
        local l, e = sock:receive("*l")
        if not l then return nil, "headers: " .. tostring(e) end
        if l == "" then break end
        local k, v = l:match("^([^:]+):%s*(.*)$")
        if k then
            k = k:lower()
            if headers[k] then headers[k] = headers[k] .. ", " .. v else headers[k] = v end
        end
    end
    return status, headers
end

net.send_all = send_all
net.read_head = read_head

local function read_body(sock, headers, max_bytes)
    max_bytes = max_bytes or 16 * 1024 * 1024
    local te = (headers["transfer-encoding"] or ""):lower()
    if te:find("chunked") then
        local parts, total = {}, 0
        while true do
            local line, err = sock:receive("*l")
            if not line then return nil, "chunk: " .. tostring(err) end
            local size = tonumber(line:match("^%s*(%x+)"), 16)
            if not size then return nil, "bad chunk size" end
            if size == 0 then
                -- trailers
                repeat line = sock:receive("*l") until not line or line == ""
                break
            end
            local data, e2 = sock:receive(size)
            if not data then return nil, "chunk data: " .. tostring(e2) end
            parts[#parts + 1] = data
            total = total + size
            sock:receive("*l")
            if total > max_bytes then return nil, "response too large" end
        end
        return table.concat(parts)
    end
    local len = tonumber(headers["content-length"])
    if len then
        if len == 0 then return "" end
        if len > max_bytes then return nil, "response too large" end
        local data, err, partial = sock:receive(len)
        if not data then
            if partial and #partial > 0 then return partial end
            return nil, "body: " .. tostring(err)
        end
        return data
    end
    -- no length: read to EOF, but still within max_bytes
    local parts, total = {}, 0
    while true do
        local data, err, partial = sock:receive(65536)
        local piece = data or partial
        if piece and #piece > 0 then
            total = total + #piece
            if total > max_bytes then return nil, "response too large" end
            parts[#parts + 1] = piece
        end
        if not data then
            if err == "closed" then break end
            return nil, "body: " .. tostring(err)
        end
    end
    return table.concat(parts)
end

-- What to do with a redirect from `from` to `to`: "follow", "strip" (follow
-- without credentials, because the origin changed), or nil and a reason.
-- Credentials and request bodies never cross to another origin or down to http.
local CRED_HEADERS = { authorization = true, cookie = true, ["proxy-authorization"] = true }
function net.redirect_policy(from, to, has_creds, has_body)
    local a, b = parse_url(from), parse_url(to)
    if not a or not b then return nil, "bad redirect" end
    local downgrade = TLS_SCHEMES[a.scheme] and not TLS_SCHEMES[b.scheme]
    local cross = downgrade or a.host:lower() ~= b.host:lower() or a.port ~= b.port
    if downgrade and (has_creds or has_body) then return nil, "refused redirect from HTTPS to HTTP" end
    if cross and has_body then return nil, "refused to resend the request body to another site" end
    if cross and has_creds then return "strip" end
    return "follow"
end

-- Blocking request. opts: url, method, headers, body, timeout, max_bytes
-- Returns resp {status, headers, body, url} or nil, err
function net.request(opts)
    local url = opts.url
    local method = opts.method or (opts.body and "POST" or "GET")
    for _ = 1, 6 do
        local u, perr = parse_url(url)
        if not u then return nil, perr end
        local sock, cerr = connect(u, opts.timeout or net.timeout)
        if not sock then return nil, cerr end
        local ok, serr = send_all(sock, build_request(method, u, opts.headers, opts.body))
        if not ok then sock:close() return nil, "send: " .. tostring(serr) end
        local status, headers = read_head(sock)
        if not status then sock:close() return nil, headers end
        if status >= 300 and status < 400 and headers.location and not opts.no_redirect then
            sock:close()
            local to = net.resolve(url, headers.location)
            if status == 303 or ((status == 301 or status == 302) and method == "POST") then
                method, opts = "GET", setmetatable({ body = false }, { __index = opts })
            end
            local has_creds = false
            for k in pairs(opts.headers or {}) do
                if CRED_HEADERS[k:lower()] then has_creds = true end
            end
            local policy, why = net.redirect_policy(url, to, has_creds, opts.body and opts.body ~= "")
            if not policy then return nil, why end
            if policy == "strip" then
                local h = {}
                for k, v in pairs(opts.headers) do
                    if not CRED_HEADERS[k:lower()] then h[k] = v end
                end
                opts = setmetatable({ headers = h }, { __index = opts })
            end
            url = to
        else
            local body, berr = read_body(sock, headers, opts.max_bytes)
            sock:close()
            if not body then return nil, berr end
            return { status = status, headers = headers, body = body, url = url }
        end
    end
    return nil, "too many redirects"
end

function net.get(url, headers, timeout)
    return net.request({ url = url, headers = headers, timeout = timeout })
end

-- Streams ---------------------------------------------------------------------
local Stream = {}
Stream.__index = Stream

-- opts: url, method, headers, body, on_line(line), on_close(reason, status)
-- Connects and reads the response head synchronously, then reads the body
-- incrementally via :pump() (non-blocking).
function net.stream(opts)
    local u, perr = parse_url(opts.url)
    if not u then return nil, perr end
    local sock, cerr = connect(u, opts.timeout or net.timeout)
    if not sock then return nil, cerr end
    local headers = {}
    for k, v in pairs(opts.headers or {}) do headers[k] = v end
    headers["Connection"] = "keep-alive"
    local ok, serr = send_all(sock, build_request(opts.method or "GET", u, headers, opts.body))
    if not ok then sock:close() return nil, "send: " .. tostring(serr) end
    local status, rh = read_head(sock)
    if not status then sock:close() return nil, rh end
    if status >= 400 then
        local body = read_body(sock, rh, 65536) or ""
        sock:close()
        return nil, "HTTP " .. status .. " " .. body:sub(1, 200), status
    end
    sock:settimeout(0)
    local s = setmetatable({
        sock = sock, status = status, headers = rh,
        chunked = (rh["transfer-encoding"] or ""):lower():find("chunked") ~= nil,
        remaining = tonumber(rh["content-length"]),
        raw = "", payload = "", state = "size", chunk_left = 0,
        on_line = opts.on_line, on_close = opts.on_close,
        last_data = sys.now(), closed = false,
    }, Stream)
    return s
end

net.max_line = 4 * 1024 * 1024   -- one NDJSON event; a server sending more without a newline is broken

function Stream:_feed_payload(data)
    self.payload = self.payload .. data
    if #self.payload > net.max_line and not self.payload:find("\n", 1, true) then
        return self:close("line too long")
    end
    while true do
        local i = self.payload:find("\n", 1, true)
        if not i then break end
        local line = self.payload:sub(1, i - 1):gsub("\r$", "")
        self.payload = self.payload:sub(i + 1)
        if line ~= "" and self.on_line then self.on_line(line) end
        if self.closed then return end
    end
end

function Stream:_decode()
    if not self.chunked then
        local d = self.raw
        self.raw = ""
        self:_feed_payload(d)
        return
    end
    while not self.closed do
        if self.state == "size" then
            local i = self.raw:find("\r\n", 1, true)
            if not i then return end
            local size = tonumber(self.raw:sub(1, i - 1):match("^%s*(%x+)"), 16)
            self.raw = self.raw:sub(i + 2)
            if not size then return self:close("bad chunk") end
            if size == 0 then return self:close("end") end
            self.chunk_left = size
            self.state = "data"
        elseif self.state == "data" then
            if #self.raw == 0 then return end
            local take = math.min(self.chunk_left, #self.raw)
            local piece = self.raw:sub(1, take)
            self.raw = self.raw:sub(take + 1)
            self.chunk_left = self.chunk_left - take
            if self.chunk_left == 0 then self.state = "crlf" end
            self:_feed_payload(piece)
        elseif self.state == "crlf" then
            if #self.raw < 2 then return end
            self.raw = self.raw:sub(3)
            self.state = "size"
        end
    end
end

-- Read whatever is available. Returns true if any bytes arrived.
function Stream:pump()
    if self.closed then return false end
    local got = false
    for _ = 1, 32 do
        local data, err, partial = self.sock:receive(8192)
        local chunk = data or partial
        if chunk and #chunk > 0 then
            got = true
            self.raw = self.raw .. chunk
            self.last_data = sys.now()
        end
        if err == "closed" then
            self:_decode()
            self:close("closed")
            return got
        end
        if not data then break end
    end
    if got then self:_decode() end
    return got
end

function Stream:getfd()
    if self.closed then return nil end
    local ok, fd = pcall(function() return self.sock:getfd() end)
    if ok then return fd end
    return nil
end

function Stream:close(reason)
    if self.closed then return end
    self.closed = true
    pcall(function() self.sock:close() end)
    if self.on_close then self.on_close(reason or "closed", self.status) end
end

return net
