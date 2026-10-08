-- Lichess Board API client (https://lichess.org/api#tag/Board).
local net = require("core.net")
local json = require("core.json")
local sys = require("core.sys")
local store = require("core.store")
local kindle = require("core.kindle")

local api = {}
api.base = os.getenv("LICHESS_BASE") or "https://lichess.org"
api.token = nil

function api.token_file()
    return store.dir() .. "/lichess_token.txt"
end

-- Token: data/lichess.json (saved from the app) or data/lichess_token.txt
-- (a file you can drop on the Kindle over USB).
function api.load_token()
    local cfg = store.load("lichess")
    local t = cfg.token
    if not t or t == "" then
        local raw = sys.read_file(api.token_file())
        if raw then t = raw:match("(lip_[%w_]+)") or raw:match("^%s*(%S+)") end
    end
    api.token = (t and t ~= "") and t or nil
    return api.token
end

function api.save_token(t)
    local cfg = store.load("lichess")
    cfg.token = t
    store.save("lichess", cfg)
    api.token = t
end

function api.forget_token()
    local cfg = store.load("lichess")
    cfg.token = nil
    store.save("lichess", cfg)
    os.remove(api.token_file())
    api.token = nil
end

local function headers(extra)
    local h = { Accept = "application/json" }
    if api.token then h.Authorization = "Bearer " .. api.token end
    for k, v in pairs(extra or {}) do h[k] = v end
    return h
end

function api.ensure_online()
    if kindle.wifi_connected() then return true end
    if not kindle.ensure_wifi(nil, 25) then
        return nil, "Wi-Fi is off or not connected."
    end
    return true
end

local function error_text(resp)
    local body = resp.body or ""
    local d = json.decode(body)
    if type(d) == "table" then
        if d.error then
            if type(d.error) == "table" then
                local parts = {}
                for k, v in pairs(d.error) do
                    parts[#parts + 1] = (type(v) == "table" and table.concat(v, ", ") or tostring(v))
                end
                return table.concat(parts, "; ")
            end
            return tostring(d.error)
        end
        if d.message then return tostring(d.message) end
    end
    return "HTTP " .. resp.status .. (body ~= "" and (": " .. body:sub(1, 160)) or "")
end

-- Returns decoded JSON (or true for empty bodies), or nil, err, status
function api.call(method, path, form)
    local ok, oerr = api.ensure_online()
    if not ok then return nil, oerr end
    local body = form and net.form(form) or nil
    local resp, err = net.request({
        method = method, url = api.base .. path, headers = headers(), body = body,
    })
    if not resp then return nil, err end
    if resp.status == 401 then return nil, "Token rejected by Lichess (401). Check the token and its scopes.", 401 end
    if resp.status >= 400 then return nil, error_text(resp), resp.status end
    if resp.body == "" then return true end
    local d = json.decode(resp.body)
    if d == nil then return true end
    return d
end

function api.account() return api.call("GET", "/api/account") end
function api.playing() return api.call("GET", "/api/account/playing?nb=30") end

function api.challenge_ai(p) return api.call("POST", "/api/challenge/ai", p) end
function api.challenge_user(username, p) return api.call("POST", "/api/challenge/" .. net.urlencode(username), p) end
function api.accept(id) return api.call("POST", "/api/challenge/" .. id .. "/accept") end
function api.decline(id, reason) return api.call("POST", "/api/challenge/" .. id .. "/decline", reason and { reason = reason } or nil) end
function api.cancel_challenge(id) return api.call("POST", "/api/challenge/" .. id .. "/cancel") end

function api.move(game, uci, offering_draw)
    local q = offering_draw and "?offeringDraw=true" or ""
    return api.call("POST", "/api/board/game/" .. game .. "/move/" .. uci .. q)
end
function api.resign(game) return api.call("POST", "/api/board/game/" .. game .. "/resign") end
function api.abort(game) return api.call("POST", "/api/board/game/" .. game .. "/abort") end
function api.draw(game, yes) return api.call("POST", "/api/board/game/" .. game .. "/draw/" .. (yes and "yes" or "no")) end
function api.takeback(game, yes) return api.call("POST", "/api/board/game/" .. game .. "/takeback/" .. (yes and "yes" or "no")) end
function api.claim_victory(game) return api.call("POST", "/api/board/game/" .. game .. "/claim-victory") end
function api.chat(game, text) return api.call("POST", "/api/board/game/" .. game .. "/chat", { room = "player", text = text }) end

local function open_stream(method, path, form, on_event, on_close)
    local ok, oerr = api.ensure_online()
    if not ok then return nil, oerr end
    return net.stream({
        method = method,
        url = api.base .. path,
        headers = headers({ Accept = "application/x-ndjson" }),
        body = form and net.form(form) or nil,
        on_line = function(line)
            local d = json.decode(line)
            if type(d) == "table" then on_event(d) end
        end,
        on_close = on_close,
    })
end

function api.event_stream(on_event, on_close)
    return open_stream("GET", "/api/stream/event", nil, on_event, on_close)
end

function api.game_stream(game, on_event, on_close)
    return open_stream("GET", "/api/board/game/stream/" .. game, nil, on_event, on_close)
end

-- Real-time seeks stay open as a stream; correspondence seeks return an id.
function api.seek(p, on_close)
    if p.days then
        return api.call("POST", "/api/board/seek", p)
    end
    return open_stream("POST", "/api/board/seek", p, function() end, on_close)
end

return api
