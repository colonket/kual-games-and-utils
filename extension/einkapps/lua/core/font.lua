-- Pre-baked bitmap fonts (see tools/build_assets.py for the format).
local ffi = require("ffi")
local bit = require("bit")
local sys = require("core.sys")

local band, rshift = bit.band, bit.rshift
local floor = math.floor

local font = {}
local Font = {}
Font.__index = Font

local cache = {}
local sizes_by_family = nil
local root_dir

function font.init(assets_dir)
    root_dir = assets_dir .. "/fonts/"
    sizes_by_family = {}
    for _, name in ipairs(sys.list_dir(root_dir)) do
        local fam, px = name:match("^(%w+)_(%d+)%.efn$")
        if fam then
            sizes_by_family[fam] = sizes_by_family[fam] or {}
            table.insert(sizes_by_family[fam], tonumber(px))
        end
    end
    for _, list in pairs(sizes_by_family) do table.sort(list) end
end

local function load(fam, px)
    local key = fam .. "_" .. px
    if cache[key] then return cache[key] end
    local data = sys.read_file(root_dir .. key .. ".efn")
    if not data or data:sub(1, 4) ~= "EFN1" then error("bad font " .. key) end
    local p = ffi.cast("const uint8_t*", data)
    local function u16(o) return p[o] + p[o + 1] * 256 end
    local function i16(o) local v = u16(o) if v >= 32768 then v = v - 65536 end return v end
    local function u32(o) return p[o] + p[o + 1] * 256 + p[o + 2] * 65536 + p[o + 3] * 16777216 end
    local f = setmetatable({
        family = fam, px = u16(4), ascent = i16(6), descent = i16(8),
        data = data, ptr = p, glyphs = {},
    }, Font)
    local n = u32(12)
    local tbl = 16
    local base = tbl + n * 20
    for i = 0, n - 1 do
        local o = tbl + i * 20
        f.glyphs[u32(o)] = { adv = i16(o + 4), xoff = i16(o + 6), yoff = i16(o + 8), w = u16(o + 10), h = u16(o + 12), off = base + u32(o + 16) }
    end
    f.height = f.ascent + f.descent
    f.line_height = floor(f.height * 1.18 + 0.5)
    local space = f.glyphs[32]
    f.space = space and space.adv or floor(px / 3)
    cache[key] = f
    return f
end

-- Get the closest baked size of a family (fam: sans, bold, serif, serifb, num).
function font.get(fam, px)
    local list = sizes_by_family[fam]
    if not list then error("no font family " .. tostring(fam)) end
    local best, bd = list[1], math.huge
    for _, s in ipairs(list) do
        local d = math.abs(s - px)
        if d < bd or (d == bd and s < best) then best, bd = s, d end
    end
    local f = load(fam, best)
    if not f.fallback and fam ~= "sans" then
        f.fallback = font.get("sans", best)
    end
    return f
end

-- Largest size of family whose text fits in maxw (and optional maxh).
function font.fit(fam, text, maxw, maxh, upto)
    local list = sizes_by_family[fam]
    for i = #list, 1, -1 do
        local s = list[i]
        if not upto or s <= upto then
            local f = font.get(fam, s)
            if f:width(text) <= maxw and (not maxh or f.height <= maxh) then return f end
        end
    end
    return font.get(fam, list[1])
end

function Font:glyph(cp)
    local g = self.glyphs[cp]
    if g then return g, self end
    if self.fallback then
        g = self.fallback.glyphs[cp]
        if g then return g, self.fallback end
    end
    -- curly quotes etc. that a font lacks
    if cp == 0x2019 or cp == 0x2018 then return self:glyph(39) end
    if cp == 0x201C or cp == 0x201D then return self:glyph(34) end
    if cp == 0xA0 then return self:glyph(32) end
    return self.glyphs[63] or self.glyphs[32], self
end

function Font:width(text)
    local w = 0
    for _, cp in sys.utf8_codes(text) do
        local g = self:glyph(cp)
        w = w + g.adv
    end
    return w
end

local function draw_glyph(surf, f, g, x, y, color)
    if g.w == 0 then return end
    local p = f.ptr
    local rowbytes = rshift(g.w + 1, 1)
    local buf, W = surf.buf, surf.w
    local cx0, cy0, cx1, cy1 = surf.cx0, surf.cy0, surf.cx1, surf.cy1
    local gx, gy = x + g.xoff, y + g.yoff
    for j = 0, g.h - 1 do
        local ty = gy + j
        if ty >= cy0 and ty < cy1 then
            local src = g.off + j * rowbytes
            local row = ty * W
            for i = 0, g.w - 1 do
                local tx = gx + i
                if tx >= cx0 and tx < cx1 then
                    local b = p[src + rshift(i, 1)]
                    local v = (band(i, 1) == 0) and rshift(b, 4) or band(b, 15)
                    if v == 15 then
                        buf[row + tx] = color
                    elseif v > 0 then
                        local d = buf[row + tx]
                        buf[row + tx] = d + (color - d) * v / 15 + 0.5
                    end
                end
            end
        end
    end
end

-- Draw with the pen on the baseline. Returns the end x.
function Font:draw(surf, x, y, text, color)
    color = color or 0
    x, y = floor(x), floor(y)
    for _, cp in sys.utf8_codes(text) do
        local g, f = self:glyph(cp)
        draw_glyph(surf, f, g, x, y, color)
        x = x + g.adv
    end
    return x
end

-- Draw with y as the top of the line box.
function Font:draw_top(surf, x, y, text, color)
    return self:draw(surf, x, y + self.ascent, text, color)
end

-- Draw centered in a box (both axes), using cap-height-ish centering.
function Font:draw_center(surf, x, y, w, h, text, color)
    local tw = self:width(text)
    local tx = x + (w - tw) / 2
    -- Center the visual body (ascent dominated) in the box.
    local ty = y + (h - self.height) / 2 + self.ascent
    return self:draw(surf, tx, ty, text, color)
end

-- Visual centering for digits/caps: uses the actual glyph bounds.
function Font:ink_bounds(text)
    local top, bottom = math.huge, -math.huge
    for _, cp in sys.utf8_codes(text) do
        local g = self:glyph(cp)
        if g.h > 0 then
            top = math.min(top, g.yoff)
            bottom = math.max(bottom, g.yoff + g.h)
        end
    end
    if top == math.huge then return -self.ascent, 0 end
    return top, bottom
end

function Font:draw_center_ink(surf, x, y, w, h, text, color)
    local tw = self:width(text)
    local top, bottom = self:ink_bounds(text)
    local ty = y + (h - (bottom - top)) / 2 - top
    return self:draw(surf, x + (w - tw) / 2, ty, text, color)
end

-- Truncate text to fit in maxw, adding an ellipsis.
function Font:ellipsize(text, maxw)
    if self:width(text) <= maxw then return text end
    local ell = "…"
    local ew = self:width(ell)
    local out, w = {}, 0
    for pos, cp in sys.utf8_codes(text) do
        local g = self:glyph(cp)
        if w + g.adv + ew > maxw then break end
        w = w + g.adv
        out[#out + 1] = sys.utf8_char(cp)
    end
    return table.concat(out) .. ell
end

-- Word-wrap text into lines no wider than maxw. Honors "\n".
function Font:wrap(text, maxw)
    local lines = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        local line, lw = "", 0
        for word in para:gmatch("%S+") do
            local ww = self:width(word)
            if lw > 0 and lw + self.space + ww <= maxw then
                line = line .. " " .. word
                lw = lw + self.space + ww
            elseif lw == 0 and ww <= maxw then
                line, lw = word, ww
            else
                if lw > 0 then lines[#lines + 1] = line end
                if ww <= maxw then
                    line, lw = word, ww
                else
                    -- break a long word by characters
                    local chunk, cw = "", 0
                    for _, cp in sys.utf8_codes(word) do
                        local g = self:glyph(cp)
                        if cw + g.adv > maxw and cw > 0 then
                            lines[#lines + 1] = chunk
                            chunk, cw = "", 0
                        end
                        chunk = chunk .. sys.utf8_char(cp)
                        cw = cw + g.adv
                    end
                    line, lw = chunk, cw
                end
            end
        end
        lines[#lines + 1] = line
    end
    return lines
end

return font
