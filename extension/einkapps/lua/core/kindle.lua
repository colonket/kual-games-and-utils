-- Kindle platform helpers (lipc, Wi-Fi, battery, power events).
-- Everything degrades to a no-op in the desktop simulator.
local sys = require("core.sys")

local kindle = {}
kindle.sim = os.getenv("EINK_SIM") ~= nil

local function lipc_get(service, prop, flags)
    if kindle.sim then return nil end
    return sys.capture(string.format("lipc-get-prop %s %s %s", flags or "-q", service, prop))
end

local function lipc_set(service, prop, value)
    if kindle.sim then return end
    os.execute(string.format("lipc-set-prop %s %s %s >/dev/null 2>&1", service, prop, sys.quote(value)))
end
kindle.lipc_get, kindle.lipc_set = lipc_get, lipc_set

-- Keep the screensaver from kicking in (clock, life counter, live games).
local prevent = false
function kindle.prevent_screensaver(on)
    if on == prevent then return end
    prevent = on
    lipc_set("com.lab126.powerd", "preventScreenSaver", on and "1" or "0")
end

function kindle.battery()
    if kindle.sim then return 87 end
    local v = sys.read_file("/sys/devices/system/wario_battery/wario_battery0/battery_capacity")
        or sys.read_file("/sys/class/power_supply/bd71827_bat/capacity")
        or lipc_get("com.lab126.powerd", "battLevel")
    return tonumber((v or ""):match("%d+"))
end

function kindle.wifi_connected()
    if kindle.sim then return true end
    local st = lipc_get("com.lab126.wifid", "cmState") or ""
    return st:upper():find("CONNECTED") ~= nil
end

-- Turn Wi-Fi on and wait for a connection. progress(msg) is called while
-- waiting. Returns true on success.
function kindle.ensure_wifi(progress, timeout_s)
    if kindle.wifi_connected() then return true end
    if progress then progress("Turning on Wi-Fi…") end
    lipc_set("com.lab126.cmd", "wirelessEnable", "1")
    local deadline = sys.now() + (timeout_s or 25) * 1000
    while sys.now() < deadline do
        sys.sleep_ms(500)
        if kindle.wifi_connected() then
            -- give DHCP/DNS a moment
            sys.sleep_ms(800)
            return true
        end
    end
    return false
end

-- Background watcher for sleep/wake so we can repaint after the
-- screensaver and release the touchscreen while the device is asleep.
function kindle.power_watcher()
    if kindle.sim then return nil end
    if not sys.file_exists("/usr/bin/lipc-wait-event") then return nil end
    return sys.spawn_reader("lipc-wait-event -m com.lab126.powerd goingToScreenSaver,outOfScreenSaver,exitingScreenSaver 2>/dev/null")
end

function kindle.model()
    if kindle.sim then return "Simulator" end
    return sys.capture("cat /proc/usid 2>/dev/null | cut -c3-4") or "?"
end

-- UTC offset (seconds) of the system's local time.
function kindle.local_offset()
    local t = os.time()
    local l, u = os.date("*t", t), os.date("!*t", t)
    l.isdst = false
    return os.time(l) - os.time(u)
end

return kindle
