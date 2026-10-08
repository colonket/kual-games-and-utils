-- Touch input from the evdev touchscreen, turned into simple gestures:
--   {type="tap", x=, y=}, {type="hold", x=, y=},
--   {type="swipe", dir="left"|"right"|"up"|"down", x=, y=, x2=, y2=}
-- The device is grabbed (EVIOCGRAB) so the Kindle UI underneath doesn't
-- react to our taps; the grab is released automatically if we crash.
local ffi = require("ffi")
local bit = require("bit")
local sys = require("core.sys")

ffi.cdef[[
struct ea_input_event { struct ea_timeval time; unsigned short type; unsigned short code; int value; };
struct ea_absinfo { int value; int minimum; int maximum; int fuzz; int flat; int resolution; };
]]
local C = ffi.C

local EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
local SYN_REPORT = 0
local ABS_X, ABS_Y = 0x00, 0x01
local ABS_MT_SLOT, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x2f, 0x35, 0x36, 0x39
local BTN_TOUCH = 0x14a

local function IOC(dir, nr, size) return dir * 0x40000000 + size * 0x10000 + 0x45 * 0x100 + nr end
local EVIOCGNAME = IOC(2, 0x06, 256)
local EVIOCGBIT_ABS = IOC(2, 0x20 + EV_ABS, 8)
local function EVIOCGABS(code) return IOC(2, 0x40 + code, 24) end
local EVIOCGRAB = IOC(1, 0x90, 4)

local input = {}
input.HOLD_MS = 550
input.queue = {}
input.fds = {}

local dev = nil           -- the touchscreen
local W, H = 1072, 1448
local cfg = {}

local function test_bit(buf, n)
    local byte = buf[math.floor(n / 8)]
    return bit.band(byte, bit.lshift(1, n % 8)) ~= 0
end

local function absinfo(fd, code)
    local ai = ffi.new("struct ea_absinfo")
    if C.ioctl(fd, EVIOCGABS(code), ai) < 0 then return nil end
    return { min = ai.minimum, max = ai.maximum }
end

local function score_device(name, has_mt, has_xy)
    local n = name:lower()
    if n:find("accel") or n:find("gyro") or n:find("hall") or n:find("light") then return -1 end
    local s = 0
    if has_mt then s = s + 10 elseif has_xy then s = s + 3 else return -1 end
    if n:find("touch") or n:find("cyttsp") or n:find("zforce") or n:find("_mt")
        or n:find("elan") or n:find("pt_mt") or n:find("goodix") then s = s + 5 end
    return s
end

function input.init(screen_w, screen_h, settings)
    W, H = screen_w, screen_h
    cfg = settings or {}
    if os.getenv("EINK_SIM") then
        input.sim = true
        return true
    end
    local best, best_score = nil, -1
    local paths = {}
    if cfg.touch_dev then paths[1] = cfg.touch_dev end
    for i = 0, 15 do paths[#paths + 1] = "/dev/input/event" .. i end
    for _, path in ipairs(paths) do
        local fd = C.open(path, bit.bor(sys.O_RDONLY, sys.O_NONBLOCK))
        if fd >= 0 then
            local name = ffi.new("char[256]")
            C.ioctl(fd, EVIOCGNAME, name)
            local nm = ffi.string(name)
            local bits = ffi.new("uint8_t[8]")
            C.ioctl(fd, EVIOCGBIT_ABS, bits)
            local has_mt = test_bit(bits, ABS_MT_POSITION_X) and test_bit(bits, ABS_MT_POSITION_Y)
            local has_xy = test_bit(bits, ABS_X) and test_bit(bits, ABS_Y)
            local sc = score_device(nm, has_mt, has_xy)
            if path == cfg.touch_dev then sc = sc + 100 end
            if sc > best_score then
                if best then C.close(best.fd) end
                best, best_score = { fd = fd, path = path, name = nm, mt = has_mt }, sc
            else
                C.close(fd)
            end
        end
    end
    if not best or best_score < 0 then return false, "no touchscreen found" end
    dev = best
    local xi = absinfo(dev.fd, dev.mt and ABS_MT_POSITION_X or ABS_X)
    local yi = absinfo(dev.fd, dev.mt and ABS_MT_POSITION_Y or ABS_Y)
    dev.xmin, dev.xmax = xi and xi.min or 0, xi and xi.max or (W - 1)
    dev.ymin, dev.ymax = yi and yi.min or 0, yi and yi.max or (H - 1)
    if dev.xmax <= dev.xmin then dev.xmax = dev.xmin + W - 1 end
    if dev.ymax <= dev.ymin then dev.ymax = dev.ymin + H - 1 end
    input.grab(true)
    input.fds = { dev.fd }
    dev.ev = ffi.new("struct ea_input_event[64]")
    dev.slots = {}
    dev.slot = 0
    return true, dev
end

function input.grab(on)
    if dev then C.ioctl(dev.fd, EVIOCGRAB, ffi.cast("long", on and 1 or 0)) end
end

function input.device_info()
    if not dev then return "simulator" end
    return string.format("%s (%s) x:%d..%d y:%d..%d", dev.name, dev.path, dev.xmin, dev.xmax, dev.ymin, dev.ymax)
end

-- Raw panel coordinates -> screen pixels, with optional user overrides.
local function to_screen(rx, ry)
    local nx = (rx - dev.xmin) / (dev.xmax - dev.xmin)
    local ny = (ry - dev.ymin) / (dev.ymax - dev.ymin)
    if cfg.touch_swap_xy then nx, ny = ny, nx end
    if cfg.touch_mirror_x then nx = 1 - nx end
    if cfg.touch_mirror_y then ny = 1 - ny end
    return math.floor(nx * (W - 1) + 0.5), math.floor(ny * (H - 1) + 0.5)
end

-- Gesture tracking for the primary contact
local touch = nil   -- {x0,y0,t0,x,y,held}

local function contact_down()
    -- Primary contact: lowest active slot, or the single-touch state
    local best = nil
    for s, st in pairs(dev.slots) do
        if st.active and st.x and st.y and (best == nil or s < best) then best = s end
    end
    if best then return dev.slots[best] end
    return nil
end

local function emit(ev) input.queue[#input.queue + 1] = ev end

local function on_frame(now)
    local c = contact_down()
    if c then
        local x, y = to_screen(c.x, c.y)
        if not touch then
            touch = { x0 = x, y0 = y, t0 = now, x = x, y = y }
        else
            touch.x, touch.y = x, y
        end
    elseif touch then
        local t = touch
        touch = nil
        if t.held then return end
        local dx, dy = t.x - t.x0, t.y - t.y0
        local dist = math.sqrt(dx * dx + dy * dy)
        local slop = math.max(30, W * 0.045)
        if dist < slop then
            emit({ type = "tap", x = t.x0, y = t.y0 })
        else
            local dir
            if math.abs(dx) > math.abs(dy) then dir = dx > 0 and "right" or "left"
            else dir = dy > 0 and "down" or "up" end
            emit({ type = "swipe", dir = dir, x = t.x0, y = t.y0, x2 = t.x, y2 = t.y })
        end
    end
end

-- Read pending events; call after poll() says the fd is readable.
function input.read()
    if not dev then return end
    local size = ffi.sizeof("struct ea_input_event")
    while true do
        local n = tonumber(C.read(dev.fd, dev.ev, size * 64))
        if not n or n <= 0 then break end
        local count = math.floor(n / size)
        for i = 0, count - 1 do
            local e = dev.ev[i]
            local t, code, val = e.type, e.code, e.value
            if t == EV_ABS then
                if code == ABS_MT_SLOT then
                    dev.slot = val
                else
                    local st = dev.slots[dev.slot]
                    if not st then st = {}; dev.slots[dev.slot] = st end
                    if code == ABS_MT_TRACKING_ID then
                        st.active = val >= 0
                        if not st.active then st.x, st.y = nil, nil end
                    elseif code == ABS_MT_POSITION_X or code == ABS_X then
                        st.x = val
                        if not dev.mt or st.active == nil then st.active = st.active or dev.btn_down end
                    elseif code == ABS_MT_POSITION_Y or code == ABS_Y then
                        st.y = val
                        if not dev.mt or st.active == nil then st.active = st.active or dev.btn_down end
                    end
                end
            elseif t == EV_KEY and code == BTN_TOUCH then
                dev.btn_down = val ~= 0
                if not dev.mt then
                    local st = dev.slots[0] or {}
                    dev.slots[0] = st
                    st.active = dev.btn_down
                elseif val == 0 then
                    -- Some panels never send TRACKING_ID -1; BTN_TOUCH 0 means all up.
                    for _, st in pairs(dev.slots) do st.active = false end
                else
                    -- Panels that skip TRACKING_ID: treat BTN_TOUCH as contact.
                    for _, st in pairs(dev.slots) do
                        if st.active == nil or (st.active == false and st.x) then st.active = true end
                    end
                end
            elseif t == EV_SYN and code == SYN_REPORT then
                on_frame(sys.now())
            end
        end
    end
end

-- Called regularly from the main loop to emit "hold" while still pressed.
function input.update(now)
    if touch and not touch.held and now - touch.t0 >= input.HOLD_MS then
        local dx, dy = touch.x - touch.x0, touch.y - touch.y0
        if math.sqrt(dx * dx + dy * dy) < math.max(30, W * 0.045) then
            touch.held = true
            emit({ type = "hold", x = touch.x0, y = touch.y0 })
        end
    end
end

function input.pressed()
    return touch ~= nil and not touch.held
end

function input.pop()
    if #input.queue == 0 then return nil end
    return table.remove(input.queue, 1)
end

function input.inject(ev)
    input.queue[#input.queue + 1] = ev
end

function input.close()
    if dev then
        input.grab(false)
        C.close(dev.fd)
        dev = nil
    end
end

return input
