-- Small JSON encoder/decoder (UTF-8, \u escapes incl. surrogate pairs).
local sys = require("core.sys")
local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k <= 0 or k % 1 ~= 0 then return false end
        n = math.max(n, k)
    end
    return n == #t, n
end

local function encode(v, out)
    local tv = type(v)
    if v == nil or v == json.null then out[#out + 1] = "null"
    elseif tv == "boolean" then out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
        elseif v % 1 == 0 and math.abs(v) < 1e15 then out[#out + 1] = string.format("%d", v)
        else out[#out + 1] = string.format("%.14g", v) end
    elseif tv == "string" then out[#out + 1] = encode_string(v)
    elseif tv == "table" then
        local arr = is_array(v)
        if arr and (#v > 0 or next(v) == nil and getmetatable(v) ~= json.object_mt) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encode(v[i], out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = encode_string(k)
                out[#out + 1] = ":"
                local val = v[k]
                if val == nil then val = v[tonumber(k)] end
                encode(val, out)
            end
            out[#out + 1] = "}"
        end
    else
        error("cannot encode " .. tv)
    end
end

json.object_mt = {}
function json.object(t) return setmetatable(t or {}, json.object_mt) end

function json.encode(v)
    local out = {}
    encode(v, out)
    return table.concat(out)
end

-- Decoder -------------------------------------------------------------------
local decode_value

local function skip_ws(s, i)
    return s:find("[^ \t\r\n]", i) or #s + 1
end

local function decode_error(s, i, msg)
    error(string.format("json: %s at %d near %q", msg, i, s:sub(i, i + 20)), 0)
end

local function decode_string(s, i)
    -- s:sub(i,i) == '"'
    local out = {}
    local j = i + 1
    while true do
        local k = s:find('["\\]', j)
        if not k then decode_error(s, i, "unterminated string") end
        out[#out + 1] = s:sub(j, k - 1)
        local c = s:sub(k, k)
        if c == '"' then return table.concat(out), k + 1 end
        local e = s:sub(k + 1, k + 1)
        if e == "u" then
            local cp = tonumber(s:sub(k + 2, k + 5), 16)
            if not cp then decode_error(s, k, "bad \\u escape") end
            local nxt = k + 6
            if cp >= 0xD800 and cp <= 0xDBFF and s:sub(nxt, nxt + 1) == "\\u" then
                local lo = tonumber(s:sub(nxt + 2, nxt + 5), 16)
                if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                    cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    nxt = nxt + 6
                end
            end
            out[#out + 1] = sys.utf8_char(cp)
            j = nxt
        else
            local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            out[#out + 1] = map[e] or e
            j = k + 2
        end
    end
end

decode_value = function(s, i)
    i = skip_ws(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            i = skip_ws(s, i)
            if s:sub(i, i) ~= '"' then decode_error(s, i, "expected key") end
            local key
            key, i = decode_string(s, i)
            i = skip_ws(s, i)
            if s:sub(i, i) ~= ":" then decode_error(s, i, "expected ':'") end
            local val
            val, i = decode_value(s, i + 1)
            obj[key] = val
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "}" then return obj, i + 1 end
            if d ~= "," then decode_error(s, i, "expected ',' or '}'") end
            i = i + 1
        end
    elseif c == "[" then
        local arr = {}
        i = skip_ws(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            local val
            val, i = decode_value(s, i)
            arr[#arr + 1] = val
            i = skip_ws(s, i)
            local d = s:sub(i, i)
            if d == "]" then return arr, i + 1 end
            if d ~= "," then decode_error(s, i, "expected ',' or ']'") end
            i = i + 1
        end
    elseif c == '"' then
        return decode_string(s, i)
    elseif c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4
    elseif c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5
    elseif c == "n" and s:sub(i, i + 3) == "null" then return nil, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not num or num == "" then decode_error(s, i, "unexpected character") end
        return tonumber(num), i + #num
    end
end

function json.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local ok, v = pcall(function()
        local val, i = decode_value(s, 1)
        return val
    end)
    if ok then return v end
    return nil, v
end

return json
