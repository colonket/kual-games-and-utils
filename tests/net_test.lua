-- core/net.lua security tests: URL sanitising, certificate name matching,
-- redirect policy, and bounded reads. Run through tests/net_test.sh, which
-- starts tests/mock_web.py on WEB_PORT.
local net = require("core.net")

local PORT = os.getenv("WEB_PORT") or "8770"
local A = "http://127.0.0.1:" .. PORT   -- the same mock under two host names,
local B = "http://localhost:" .. PORT   -- so A -> B is a cross-origin redirect

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1; io.stderr:write("ok: ", msg, "\n")
    else failed = failed + 1; io.stderr:write("FAIL: ", msg, "\n") end
end
local json = require("core.json")
local function echo(resp) return resp and resp.status == 200 and json.decode(resp.body) or {} end

-- URL parsing (L2): no CR/LF or spaces reach the request line; odd hosts are refused
local u = net.parse_url("http://example.com/a b\r\nX-Evil: 1")
check(u and not u.path:find("[%c ]") and u.path == "/a%20b%0D%0AX-Evil:%201", "path control chars escaped: " .. tostring(u and u.path))
check(net.parse_url("http://user@evil.com/") == nil, "userinfo in host refused")
check(net.parse_url("http://ex\r\nample.com/") == nil, "CR/LF in host refused")
check(net.parse_url("https://[::1]:8443/x").host == "[::1]", "IPv6 literal host kept")
local r = echo(net.request({ url = A .. "/_echo?q=a b\r\nX-Evil: 1" }))
check(r.headers and r.headers["x-evil"] == nil and r.path == "/_echo?q=a%20b%0D%0AX-Evil:%201",
    "crafted link can't add request headers: " .. tostring(r.path))

-- certificate name matching (H1)
local M = net.name_matches
check(M("lichess.org", "lichess.org") and M("LICHESS.org", "lichess.org.") , "exact match, case and trailing dot")
check(M("*.badssl.com", "self.badssl.com"), "wildcard covers one label")
check(not M("*.badssl.com", "wrong.host.badssl.com"), "wildcard doesn't cover two labels")
check(not M("*.badssl.com", "badssl.com"), "wildcard doesn't cover the bare domain")
check(not M("*.com", "example.com") and not M("*", "example"), "no top-level wildcards")
check(not M("online-go.com.evil.net", "online-go.com"), "suffix tricks rejected")

-- protected hosts (M3): the Settings toggle never applies to them
net.insecure = true
check(net.must_verify("online-go.com") and net.must_verify("api.lichess.org") and not net.must_verify("example.com"),
    "insecure mode skips checks only for unprotected hosts")
check(net.must_verify("lichess.org.evil.com") == false and net.must_verify("evillichess.org") == false,
    "protected-host suffix match is by whole label")
net.insecure = false
check(net.must_verify("example.com"), "checks on by default")

-- redirect policy (M1)
local P = net.redirect_policy
check(P("https://a.com/x", "https://a.com/y", true, false) == "follow", "same origin keeps credentials")
check(P("https://a.com/x", "https://b.com/y", true, false) == "strip", "cross-host strips credentials")
check(P("https://a.com/x", "https://a.com:8443/y", true, false) == "strip", "port change strips credentials")
check(P("https://a.com/x", "http://a.com/y", true, false) == nil, "https->http refused with credentials")
check(P("https://a.com/x", "http://a.com/y", false, false) == "follow", "https->http allowed for a plain public GET")
check(P("https://a.com/x", "https://b.com/y", false, true) == nil, "body never replayed to another host")
local tok = { Authorization = "Bearer secret-token", Accept = "application/json" }
r = echo(net.request({ url = A .. "/_redir?to=" .. net.urlencode("/_echo"), headers = tok }))
check(r.headers and r.headers.authorization == "Bearer secret-token", "same-origin redirect: Authorization kept")
r = echo(net.request({ url = A .. "/_redir?to=" .. net.urlencode(B .. "/_echo"), headers = tok }))
check(r.headers and r.headers.authorization == nil and r.headers.accept == "application/json",
    "cross-origin redirect: Authorization dropped, other headers kept")
local resp, err = net.request({ method = "POST", url = A .. "/_redir?code=307&to=" .. net.urlencode(B .. "/_echo"),
    body = "password=hunter2" })
check(resp == nil and tostring(err):find("another site"), "307 to another host: body not resent (" .. tostring(err) .. ")")
resp = net.request({ method = "POST", url = A .. "/_redir?code=307&to=" .. net.urlencode("/_echo"), body = "x=1" })
check(echo(resp).body == "x=1", "307 same origin: body resent")
resp = net.request({ url = A .. "/_redir?to=" .. net.urlencode(B .. "/_echo"), no_redirect = true, headers = tok })
check(resp and resp.status == 302, "no_redirect returns the 3xx untouched")

-- bounded reads (L3): a response without Content-Length can't exceed max_bytes
resp, err = net.request({ url = A .. "/_nolength?n=3000000", max_bytes = 1000000 })
check(resp == nil and err == "response too large", "unbounded body capped: " .. tostring(err))
resp = net.request({ url = A .. "/_nolength?n=200000" })
check(resp and #resp.body == 200000, "body without length still read to EOF")

io.stderr:write(string.format("net tests: %d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
