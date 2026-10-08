-- 8-bit grayscale drawing surface with the primitives the apps need.
-- Colors are 0 (black) .. 255 (white). E-ink shows 16 levels.
local ffi = require("ffi")
local floor, ceil, sqrt, min, max, abs = math.floor, math.ceil, math.sqrt, math.min, math.max, math.abs

local gfx = {}
gfx.BLACK, gfx.DARK, gfx.GRAY, gfx.MID, gfx.LIGHT, gfx.PALE, gfx.WHITE = 0, 0x44, 0x77, 0x99, 0xBB, 0xDD, 0xFF

local Surface = {}
Surface.__index = Surface
gfx.Surface = Surface

function Surface.new(w, h, color)
    local s = setmetatable({ w = w, h = h }, Surface)
    s.buf = ffi.new("uint8_t[?]", w * h)
    ffi.fill(s.buf, w * h, color or 255)
    s.cx0, s.cy0, s.cx1, s.cy1 = 0, 0, w, h
    s.clips = {}
    return s
end

function Surface:fill(c)
    ffi.fill(self.buf, self.w * self.h, c)
end

function Surface:push_clip(x, y, w, h)
    self.clips[#self.clips + 1] = { self.cx0, self.cy0, self.cx1, self.cy1 }
    self.cx0 = max(self.cx0, x)
    self.cy0 = max(self.cy0, y)
    self.cx1 = min(self.cx1, x + w)
    self.cy1 = min(self.cy1, y + h)
end

function Surface:pop_clip()
    local c = table.remove(self.clips)
    if c then self.cx0, self.cy0, self.cx1, self.cy1 = c[1], c[2], c[3], c[4] end
end

function Surface:fill_rect(x, y, w, h, c)
    x, y = floor(x), floor(y)
    local x0, y0 = max(x, self.cx0), max(y, self.cy0)
    local x1, y1 = min(x + floor(w), self.cx1), min(y + floor(h), self.cy1)
    if x1 <= x0 or y1 <= y0 then return end
    local buf, sw, len = self.buf, self.w, x1 - x0
    for yy = y0, y1 - 1 do
        ffi.fill(buf + yy * sw + x0, len, c)
    end
end

function Surface:invert_rect(x, y, w, h)
    x, y = floor(x), floor(y)
    local x0, y0 = max(x, self.cx0), max(y, self.cy0)
    local x1, y1 = min(x + floor(w), self.cx1), min(y + floor(h), self.cy1)
    local buf, sw = self.buf, self.w
    for yy = y0, y1 - 1 do
        local row = yy * sw
        for xx = x0, x1 - 1 do buf[row + xx] = 255 - buf[row + xx] end
    end
end

-- Blend a single pixel toward color c by alpha a (0..1).
local function blend(self, x, y, c, a)
    if x < self.cx0 or y < self.cy0 or x >= self.cx1 or y >= self.cy1 or a <= 0 then return end
    local i = y * self.w + x
    if a >= 1 then
        self.buf[i] = c
    else
        local d = self.buf[i]
        self.buf[i] = d + (c - d) * a + 0.5
    end
end
Surface.blend = blend

function Surface:pixel(x, y)
    if x < 0 or y < 0 or x >= self.w or y >= self.h then return 255 end
    return self.buf[y * self.w + x]
end

function Surface:rect(x, y, w, h, c, t)
    t = t or 1
    self:fill_rect(x, y, w, t, c)
    self:fill_rect(x, y + h - t, w, t, c)
    self:fill_rect(x, y + t, t, h - 2 * t, c)
    self:fill_rect(x + w - t, y + t, t, h - 2 * t, c)
end

-- Anti-aliased filled circle.
function Surface:fill_circle(cx, cy, r, c)
    if r <= 0 then return end
    local y0, y1 = floor(cy - r - 1), ceil(cy + r + 1)
    for y = y0, y1 do
        local dy = y + 0.5 - cy
        local inner2 = (r - 0.7) * (r - 0.7) - dy * dy
        local outer2 = (r + 0.7) * (r + 0.7) - dy * dy
        if outer2 > 0 then
            local xo = sqrt(outer2)
            local xi = inner2 > 0 and sqrt(inner2) or 0
            local xa, xb = floor(cx - xo), ceil(cx + xo)
            if inner2 > 0 then
                local fa, fb = ceil(cx - xi), floor(cx + xi) - 1
                if fb >= fa then self:fill_rect(fa, y, fb - fa + 1, 1, c) end
                for x = xa, fa - 1 do
                    local dx = x + 0.5 - cx
                    blend(self, x, y, c, min(1, max(0, r + 0.5 - sqrt(dx * dx + dy * dy))))
                end
                for x = max(fb + 1, fa), xb do
                    local dx = x + 0.5 - cx
                    blend(self, x, y, c, min(1, max(0, r + 0.5 - sqrt(dx * dx + dy * dy))))
                end
            else
                for x = xa, xb do
                    local dx = x + 0.5 - cx
                    blend(self, x, y, c, min(1, max(0, r + 0.5 - sqrt(dx * dx + dy * dy))))
                end
            end
        end
    end
end

-- Anti-aliased ring (outline circle) of thickness t, drawn inward from r.
function Surface:circle(cx, cy, r, c, t)
    t = t or 1
    local ri = r - t
    local y0, y1 = floor(cy - r - 1), ceil(cy + r + 1)
    for y = y0, y1 do
        local dy = y + 0.5 - cy
        local outer2 = (r + 0.7) ^ 2 - dy * dy
        if outer2 > 0 then
            local xo = sqrt(outer2)
            local in2 = (ri - 0.7) ^ 2 - dy * dy
            local xi = in2 > 0 and sqrt(in2) or -1
            local function span(xa, xb)
                for x = xa, xb do
                    local dx = x + 0.5 - cx
                    local d = sqrt(dx * dx + dy * dy)
                    local a = min(1, max(0, r + 0.5 - d)) - min(1, max(0, ri + 0.5 - d))
                    blend(self, x, y, c, a)
                end
            end
            if xi < 0 then
                span(floor(cx - xo), ceil(cx + xo))
            else
                span(floor(cx - xo), ceil(cx - xi))
                span(floor(cx + xi), ceil(cx + xo))
            end
        end
    end
end

-- Coverage of a point relative to a rounded-rect corner circle.
local function corner_cov(px, py, ccx, ccy, r)
    local dx, dy = px - ccx, py - ccy
    return min(1, max(0, r + 0.5 - sqrt(dx * dx + dy * dy)))
end

function Surface:fill_round_rect(x, y, w, h, r, c)
    x, y, w, h = floor(x), floor(y), floor(w), floor(h)
    r = min(floor(r), floor(w / 2), floor(h / 2))
    if r <= 0 then return self:fill_rect(x, y, w, h, c) end
    self:fill_rect(x, y + r, w, h - 2 * r, c)
    self:fill_rect(x + r, y, w - 2 * r, r, c)
    self:fill_rect(x + r, y + h - r, w - 2 * r, r, c)
    for j = 0, r - 1 do
        for i = 0, r - 1 do
            local a = corner_cov(i + 0.5, j + 0.5, r, r, r)
            blend(self, x + i, y + j, c, a)
            blend(self, x + w - 1 - i, y + j, c, a)
            blend(self, x + i, y + h - 1 - j, c, a)
            blend(self, x + w - 1 - i, y + h - 1 - j, c, a)
        end
    end
end

function Surface:round_rect(x, y, w, h, r, c, t)
    t = t or 1
    x, y, w, h = floor(x), floor(y), floor(w), floor(h)
    r = min(floor(r), floor(w / 2), floor(h / 2))
    if r <= 0 then return self:rect(x, y, w, h, c, t) end
    self:fill_rect(x + r, y, w - 2 * r, t, c)
    self:fill_rect(x + r, y + h - t, w - 2 * r, t, c)
    self:fill_rect(x, y + r, t, h - 2 * r, c)
    self:fill_rect(x + w - t, y + r, t, h - 2 * r, c)
    local ri = r - t
    for j = 0, r - 1 do
        for i = 0, r - 1 do
            local px, py = i + 0.5, j + 0.5
            local a = corner_cov(px, py, r, r, r)
            if ri > 0 then a = a - corner_cov(px, py, r, r, ri) end
            if a > 0 then
                blend(self, x + i, y + j, c, a)
                blend(self, x + w - 1 - i, y + j, c, a)
                blend(self, x + i, y + h - 1 - j, c, a)
                blend(self, x + w - 1 - i, y + h - 1 - j, c, a)
            end
        end
    end
end

-- Scanline polygon fill (pixel centers), with 4x vertical supersampling
-- and exact horizontal edge coverage for smooth diagonal edges.
function Surface:fill_polygon(pts, c)
    local n = #pts
    if n < 3 then return end
    local miny, maxy = math.huge, -math.huge
    for i = 1, n do
        miny = min(miny, pts[i][2])
        maxy = max(maxy, pts[i][2])
    end
    local SUB = 4
    local ys, ye = max(floor(miny), self.cy0), min(ceil(maxy), self.cy1 - 1)
    for y = ys, ye do
        local cmin, cmax = math.huge, -math.huge
        local acc = {}
        for s = 0, SUB - 1 do
            local sy = y + (s + 0.5) / SUB
            local xs = {}
            local j = n
            for i = 1, n do
                local xi, yi = pts[i][1], pts[i][2]
                local xj, yj = pts[j][1], pts[j][2]
                if (yi <= sy and yj > sy) or (yj <= sy and yi > sy) then
                    xs[#xs + 1] = xi + (sy - yi) / (yj - yi) * (xj - xi)
                end
                j = i
            end
            table.sort(xs)
            for k = 1, #xs - 1, 2 do
                local xa, xb = xs[k], xs[k + 1]
                local ia, ib = floor(xa), floor(xb)
                cmin, cmax = min(cmin, ia), max(cmax, ib)
                if ia == ib then
                    acc[ia] = (acc[ia] or 0) + (xb - xa)
                else
                    acc[ia] = (acc[ia] or 0) + (ia + 1 - xa)
                    for x = ia + 1, ib - 1 do acc[x] = (acc[x] or 0) + 1 end
                    acc[ib] = (acc[ib] or 0) + (xb - ib)
                end
            end
        end
        if cmin <= cmax then
            for x = cmin, cmax do
                local a = acc[x]
                if a then blend(self, x, y, c, a / SUB) end
            end
        end
    end
end

-- Thick line with round caps.
function Surface:line(x0, y0, x1, y1, c, t)
    t = t or 1
    if x0 == x1 or y0 == y1 then
        local x, y = min(x0, x1), min(y0, y1)
        local w, h = abs(x1 - x0), abs(y1 - y0)
        if x0 == x1 then return self:fill_rect(x - floor(t / 2), y, t, h + 1, c) end
        return self:fill_rect(x, y - floor(t / 2), w + 1, t, c)
    end
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    local nx, ny = -dy / len * t / 2, dx / len * t / 2
    self:fill_polygon({ { x0 + nx, y0 + ny }, { x1 + nx, y1 + ny }, { x1 - nx, y1 - ny }, { x0 - nx, y0 - ny } }, c)
    if t >= 3 then
        self:fill_circle(x0, y0, t / 2, c)
        self:fill_circle(x1, y1, t / 2, c)
    end
end

-- Copy a region from another surface.
function Surface:blit(src, dx, dy, sx, sy, sw, sh)
    sx, sy = sx or 0, sy or 0
    sw, sh = sw or src.w, sh or src.h
    dx, dy = floor(dx), floor(dy)
    -- clip
    if dx < self.cx0 then sx = sx + (self.cx0 - dx); sw = sw - (self.cx0 - dx); dx = self.cx0 end
    if dy < self.cy0 then sy = sy + (self.cy0 - dy); sh = sh - (self.cy0 - dy); dy = self.cy0 end
    sw = min(sw, self.cx1 - dx)
    sh = min(sh, self.cy1 - dy)
    if sw <= 0 or sh <= 0 then return end
    for j = 0, sh - 1 do
        ffi.copy(self.buf + (dy + j) * self.w + dx, src.buf + (sy + j) * src.w + sx, sw)
    end
end

-- Blit a whole surface rotated clockwise by rot (0, 90, 180, 270) degrees.
function Surface:blit_rotated(src, dx, dy, rot)
    rot = (rot or 0) % 360
    if rot == 0 then return self:blit(src, dx, dy) end
    local sw, sh, sbuf = src.w, src.h, src.buf
    local dw, dh = sw, sh
    if rot == 90 or rot == 270 then dw, dh = sh, sw end
    local buf, W = self.buf, self.w
    for y = 0, dh - 1 do
        local ty = dy + y
        if ty >= self.cy0 and ty < self.cy1 then
            local row = ty * W
            for x = 0, dw - 1 do
                local tx = dx + x
                if tx >= self.cx0 and tx < self.cx1 then
                    local px, py
                    if rot == 90 then px, py = y, sh - 1 - x
                    elseif rot == 180 then px, py = sw - 1 - x, sh - 1 - y
                    else px, py = sw - 1 - y, x end
                    buf[row + tx] = sbuf[py * sw + px]
                end
            end
        end
    end
end

-- Draw a (gray, alpha) sprite: data is a pointer to size*size*2 bytes.
function Surface:blit_ga(data, sw, sh, dx, dy)
    dx, dy = floor(dx), floor(dy)
    local buf, W = self.buf, self.w
    for y = 0, sh - 1 do
        local ty = dy + y
        if ty >= self.cy0 and ty < self.cy1 then
            local row = ty * W
            local srow = y * sw * 2
            for x = 0, sw - 1 do
                local tx = dx + x
                local a = data[srow + 2 * x + 1]
                if a > 0 and tx >= self.cx0 and tx < self.cx1 then
                    local g = data[srow + 2 * x]
                    if a >= 255 then
                        buf[row + tx] = g
                    else
                        local d = buf[row + tx]
                        buf[row + tx] = d + (g - d) * a / 255 + 0.5
                    end
                end
            end
        end
    end
end

-- Box-filter downscale of a (gray, alpha) sprite into a new buffer.
function gfx.scale_ga(data, ssize, dsize)
    local out = ffi.new("uint8_t[?]", dsize * dsize * 2)
    local ratio = ssize / dsize
    for y = 0, dsize - 1 do
        local sy0, sy1 = floor(y * ratio), max(floor(y * ratio) + 1, floor((y + 1) * ratio))
        for x = 0, dsize - 1 do
            local sx0, sx1 = floor(x * ratio), max(floor(x * ratio) + 1, floor((x + 1) * ratio))
            local ga, aa, cnt = 0, 0, 0
            for yy = sy0, min(sy1, ssize) - 1 do
                local base = yy * ssize * 2
                for xx = sx0, min(sx1, ssize) - 1 do
                    local a = data[base + 2 * xx + 1]
                    ga = ga + data[base + 2 * xx] * a
                    aa = aa + a
                    cnt = cnt + 1
                end
            end
            local o = (y * dsize + x) * 2
            if aa > 0 then
                out[o] = floor(ga / aa + 0.5)
                out[o + 1] = floor(aa / cnt + 0.5)
            end
        end
    end
    return out
end

-- Dotted/dashed horizontal separator.
function Surface:dotted_hline(x, y, w, c, t, gap)
    gap = gap or 8
    t = t or 2
    local xx = x
    while xx < x + w do
        self:fill_rect(xx, y, min(gap, x + w - xx), t, c)
        xx = xx + gap * 2
    end
end

return gfx
