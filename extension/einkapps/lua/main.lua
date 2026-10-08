-- Entry point:  luajit main.lua [app-id]
-- Run by bin/run.sh (from KUAL) with KOReader's LuaJIT.
local root = os.getenv("EINK_APPS_ROOT")
if not root then
    local script = arg and arg[0] or "lua/main.lua"
    root = script:match("^(.*)/lua/main%.lua$") or "."
end
local ko = os.getenv("KOREADER_DIR") or "/mnt/us/koreader"

package.path = root .. "/lua/?.lua;" .. (os.getenv("EINK_LUA_PATH") or "") .. ko .. "/common/?.lua;" .. package.path
package.cpath = (os.getenv("EINK_LUA_CPATH") or "") .. ko .. "/common/?.so;" .. ko .. "/libs/?.so;" .. package.cpath

-- Some KOReader builds link their C modules into one "monolibtic" library.
do
    local mono = ko .. "/libs/libkoreader-monolibtic.so"
    local f = io.open(mono, "rb")
    if f then
        f:close()
        table.insert(package.loaders, function(name)
            return package.loadlib(mono, "luaopen_" .. name:gsub("%.", "_"))
        end)
    end
end

local ui = require("core.ui")
local store = require("core.store")
local input = require("core.input")
local display = require("core.display")
local net = require("core.net")

ui.init(root)
store.init(root .. "/data")
local settings = store.load("settings", { flash_every = 24 })
display.flash_every = settings.flash_every or 24
net.cafile = root .. "/assets/cacert.pem"
-- "Skip HTTPS certificate checks" only lasts until the app exits; older
-- versions saved it, so clear it here
net.insecure = false
if settings.insecure_tls ~= nil then
    settings.insecure_tls = nil
    store.save("settings", settings)
end

local ok, info = input.init(display.w, display.h, settings)
if not ok then
    ui.log("input: " .. tostring(info))
end
ui.log(string.format("start app=%s screen=%dx%d dpi=%d input=%s", tostring(arg[1]), display.w, display.h,
    display.dpi or 0, input.device_info()))

local app_id = arg[1] or "home"
local registry = require("apps.registry")
local ok_app, err = pcall(function()
    registry.open(app_id, true)
end)
if not ok_app then
    ui.log("open failed: " .. tostring(err))
    ui.alert("Couldn't start " .. app_id, tostring(err), { { "Exit", ui.quit } })
end

local script = nil
local script_path = os.getenv("EINK_SIM_SCRIPT")
if script_path and script_path ~= "" then script = dofile(script_path) end
local run_ok, run_err = xpcall(function() ui.run({ script = script }) end, debug.traceback)
if not run_ok then
    ui.log("fatal: " .. tostring(run_err))
    io.stderr:write(tostring(run_err), "\n")
end
input.close()
if ui.rt.sim_failed then os.exit(1) end
if os.getenv("EINK_SIM") and (ui.rt.errors or 0) > 0 then os.exit(2) end
