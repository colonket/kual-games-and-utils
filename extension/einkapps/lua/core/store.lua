-- Tiny persistent key/value storage: one JSON file per namespace in data/.
local json = require("core.json")
local sys = require("core.sys")

local store = {}
local dir

function store.init(data_dir)
    dir = data_dir
    sys.mkdir_p(dir)
end

function store.dir(sub)
    if not sub then return dir end
    local p = dir .. "/" .. sub
    sys.mkdir_p(p)
    return p
end

function store.load(name, defaults)
    local raw = sys.read_file(dir .. "/" .. name .. ".json")
    local t = raw and json.decode(raw) or nil
    if type(t) ~= "table" then t = {} end
    if defaults then
        for k, v in pairs(defaults) do
            if t[k] == nil then t[k] = v end
        end
    end
    return t
end

function store.save(name, t)
    return sys.write_file(dir .. "/" .. name .. ".json", json.encode(t))
end

-- Safe filename from arbitrary text.
function store.slug(s, maxlen)
    s = tostring(s):gsub("[^%w%-_ ]", ""):gsub("%s+", "_")
    if s == "" then s = "untitled" end
    return s:sub(1, maxlen or 60)
end

return store
