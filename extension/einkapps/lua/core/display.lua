-- Screen output. On the Kindle we hand finished regions to FBInk (which
-- ships with KOReader) as PGM images over a pipe; FBInk takes care of the
-- framebuffer format, rotation and e-ink refresh ioctls. In the simulator
-- each refresh is written out as a PGM file instead.
local ffi = require("ffi")
local bit = require("bit")
local sys = require("core.sys")
local gfx = require("core.gfx")

local display = {}
display.flash_every = 24      -- partial refreshes between automatic flashes
display.partials = 0
display.frame_no = 0

local FBINK_CANDIDATES = {
    "/mnt/us/koreader/fbink",
    "/mnt/us/libkh/bin/fbink",
    "/mnt/us/usbnet/bin/fbink",
    "/usr/bin/fbink",
    "/usr/local/bin/fbink",
}

local function find_fbink()
    local env = os.getenv("EINK_FBINK")
    if env and sys.file_exists(env) then return env end
    for _, p in ipairs(FBINK_CANDIDATES) do
        if sys.file_exists(p) then return p end
    end
    local w = sys.capture("command -v fbink")
    if w and w ~= "" then return w end
    return nil
end

local ffi_ok = pcall(ffi.cdef, [[
long pwrite(int fd, const void *buf, size_t count, long offset);
]])

local function num(info, key, default)
    return tonumber(info:match(key .. "=(%-?%d+)")) or default
end

function display.init()
    local sim = os.getenv("EINK_SIM")
    if sim and sim ~= "" then
        display.sim_dir = sim
        sys.mkdir_p(sim)
        display.w = tonumber(os.getenv("EINK_SIM_W") or "1072")
        display.h = tonumber(os.getenv("EINK_SIM_H") or "1448")
        display.dpi = tonumber(os.getenv("EINK_SIM_DPI") or "300")
        display.log = io.open(sim .. "/refresh.log", "w")
    else
        display.fbink = find_fbink()
        if not display.fbink then
            error("FBInk not found. Install KOReader (it ships /mnt/us/koreader/fbink).")
        end
        local info = sys.capture(display.fbink .. " -e") or ""
        display.info = info
        display.w = num(info, "viewWidth", 1072)
        display.h = num(info, "viewHeight", 1448)
        display.dpi = num(info, "DPI", 300)
        display.device = info:match("deviceName='([^']*)'") or "Kindle"
        -- Framebuffer geometry for direct writes
        display.bpp = num(info, "BPP", 8)
        display.line = num(info, "lineLength", display.w * display.bpp / 8)
        display.xoff = num(info, "viewHoriOrigin", 0)
        display.yoff = num(info, "viewVertOrigin", 0)
        display.inverted = num(info, "invertedGrayscale", 0) == 1
        display.rota = num(info, "currentRota", 0)
        local fbdev = os.getenv("EINK_FBDEV") or "/dev/fb0"
        display.fd = ffi.C.open(fbdev, 2)   -- O_RDWR
        if display.fd < 0 then error("cannot open " .. fbdev .. ": " .. sys.errno_str()) end
        local sw, sh = num(info, "screenWidth", display.w), num(info, "screenHeight", display.h)
        if sw < display.w + display.xoff or sh < display.h + display.yoff then
            -- The panel is rotated relative to the framebuffer; not supported.
            error(string.format("unsupported framebuffer layout %dx%d rota %d", sw, sh, display.rota))
        end
        display.row = ffi.new("uint8_t[?]", display.w * 4)
    end
    display.surface = gfx.Surface.new(display.w, display.h, 255)
    display.prev = nil
    -- Layout scale relative to a Kindle Paperwhite 3 (1072 px wide, 300 dpi).
    display.scale = math.min(display.w, display.h) / 1072
    return display.surface
end

-- Copy a region of the surface into the framebuffer.
local function write_fb(x, y, w, h)
    local surf = display.surface
    local bpp, line, row = display.bpp, display.line, display.row
    local C = ffi.C
    for j = 0, h - 1 do
        local src = surf.buf + (y + j) * surf.w + x
        local off = (y + j + display.yoff) * line + (x + display.xoff) * (bpp / 8)
        if bpp == 8 then
            if display.inverted then
                for i = 0, w - 1 do row[i] = 255 - src[i] end
                C.pwrite(display.fd, row, w, off)
            else
                C.pwrite(display.fd, src, w, off)
            end
        elseif bpp == 32 then
            for i = 0, w - 1 do
                local v = src[i]
                row[4 * i], row[4 * i + 1], row[4 * i + 2], row[4 * i + 3] = v, v, v, 255
            end
            C.pwrite(display.fd, row, w * 4, off)
        elseif bpp == 16 then
            for i = 0, w - 1 do
                local v = src[i]
                local p = bit.bor(bit.lshift(bit.rshift(v, 3), 11), bit.lshift(bit.rshift(v, 2), 5), bit.rshift(v, 3))
                row[2 * i], row[2 * i + 1] = bit.band(p, 0xFF), bit.rshift(p, 8)
            end
            C.pwrite(display.fd, row, w * 2, off)
        end
    end
end

local function send_region(x, y, w, h, flash)
    if display.sim_dir then
        display.frame_no = display.frame_no + 1
        if display.log then
            display.log:write(string.format("%d %d %d %d %d %s\n", display.frame_no, x, y, w, h, flash and "flash" or "partial"))
            display.log:flush()
        end
        return
    end
    write_fb(x, y, w, h)
    -- Ask the e-ink controller to show it (FBInk: refresh only, no drawing).
    os.execute(string.format("%s -q -s top=%d,left=%d,width=%d,height=%d %s >/dev/null 2>&1",
        display.fbink, y, x, w, h, flash and "-f -W GC16" or ""))
end

-- Save the whole surface as a PGM (simulator frames, debug screenshots).
function display.save_pgm(path)
    local surf = display.surface
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(string.format("P5\n%d %d\n255\n", surf.w, surf.h))
    f:write(ffi.string(surf.buf, surf.w * surf.h))
    f:close()
    return true
end

-- Find the changed regions between the current surface and what's on screen.
local function diff_regions()
    local surf, prev = display.surface, display.prev
    local W, H = surf.w, surf.h
    local buf, pbuf = surf.buf, prev
    local bands = {}
    local cur = nil
    for y = 0, H - 1 do
        if ffi.C.memcmp(buf + y * W, pbuf + y * W, W) ~= 0 then
            if cur and y - cur[2] <= 48 then
                cur[2] = y
            else
                cur = { y, y }
                bands[#bands + 1] = cur
            end
        end
    end
    local regions = {}
    for _, b in ipairs(bands) do
        local x0, x1 = W, -1
        for y = b[1], b[2] do
            local row = y * W
            -- scan from the left
            local i = 0
            while i < x0 and buf[row + i] == pbuf[row + i] do i = i + 1 end
            if i < x0 then x0 = i end
            local k = W - 1
            while k > x1 and buf[row + k] == pbuf[row + k] do k = k - 1 end
            if k > x1 then x1 = k end
        end
        if x1 >= x0 then
            regions[#regions + 1] = { x0, b[1], x1 - x0 + 1, b[2] - b[1] + 1 }
        end
    end
    return regions
end

-- Push changes to the screen.
--   opts.full  : refresh the whole screen
--   opts.flash : force a flashing (ghost-clearing) refresh
function display.flush(opts)
    opts = opts or {}
    local surf = display.surface
    local W, H = surf.w, surf.h
    if not display.prev then
        display.prev = ffi.new("uint8_t[?]", W * H)
        opts.full = true
        opts.flash = true
    end
    if display.sim_dir then
        -- Always keep the latest full frame on disk for inspection.
        display.save_pgm(display.sim_dir .. "/latest.pgm")
    end
    local regions
    if opts.full then
        regions = { { 0, 0, W, H } }
    else
        regions = diff_regions()
    end
    if #regions == 0 then return 0 end
    local flash = opts.flash
    if not flash and not opts.quiet then
        display.partials = display.partials + 1
        if display.partials >= display.flash_every then flash = true end
    end
    if flash then display.partials = 0 end
    for _, r in ipairs(regions) do
        send_region(r[1], r[2], r[3], r[4], flash)
    end
    ffi.copy(display.prev, surf.buf, W * H)
    return #regions
end

-- Forget what is on screen so the next flush repaints everything.
function display.invalidate()
    display.prev = nil
end

return display
