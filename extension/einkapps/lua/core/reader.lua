-- Paginated text reader used by Wikipedia, RSS and DuckDuckGo.
-- reader.open{title=, blocks={ {kind="h"|"p"|"li", text=, links=} }, subtitle=, actions={ {label, fn} },
--              base=, on_link=}
-- Tap the right side (or swipe left) for the next page, left side for the
-- previous one. Underlined links (block.links from html.to_blocks) open with
-- on_link(url), or reader.open_url by default; relative hrefs resolve against base.
local ui = require("core.ui")
local gfx = require("core.gfx")
local store = require("core.store")
local net = require("core.net")
local html = require("core.html")
local kindle = require("core.kindle")

local dp = ui.dp
local BLACK, WHITE, DARK, GRAY, LIGHT = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.GRAY, gfx.LIGHT

local reader = {}
local SIZES = { 26, 30, 34, 38, 44, 52 }

-- Where each wrapped line of a block starts in its text, or nil if the lines
-- can't be matched back (then the block's links just aren't tappable).
local function line_starts(text, lines)
    local starts, pos = {}, 1
    for i, l in ipairs(lines) do
        local st = text:find("%S", pos) or pos
        if text:sub(st, st + #l - 1) ~= l then return nil end
        starts[i] = st
        pos = st + #l
    end
    return starts
end

-- The parts of block links that fall on one line: { {x0, x1, href, label} }
local function line_links(f, text, links, st, line)
    local out, en = {}, st + #line - 1
    for _, lk in ipairs(links) do
        local a, b = math.max(lk.s, st), math.min(lk.e, en)
        if a <= b then
            local x0 = f:width(text:sub(st, a - 1))
            out[#out + 1] = { x0, x0 + f:width(text:sub(a, b)), lk.href, text:sub(a, b) }
        end
    end
    return #out > 0 and out or nil
end

local prefs = nil
local function get_prefs()
    if not prefs then prefs = store.load("reader", { size = 3, flash_every = 6 }) end
    return prefs
end

function reader.open(opts)
    local p = get_prefs()
    local scr = { page = 1, turns = 0 }

    local function layout(W, H, top)
        local body = ui.font("serif", SIZES[p.size])
        local head = ui.font("serifb", SIZES[p.size] * 1.25)
        local margin = dp(48)
        local width = W - 2 * margin
        local avail = H - top - dp(30) - dp(80)
        local pages, cur, y = {}, {}, 0
        local function push_line(item, h)
            if y + h > avail and #cur > 0 then
                pages[#pages + 1] = cur
                cur, y = {}, 0
            end
            item.y = y
            cur[#cur + 1] = item
            y = y + h
        end
        -- title block
        local tfont = ui.font("serifb", SIZES[p.size] * 1.45)
        for _, l in ipairs(tfont:wrap(opts.title or "", width)) do
            push_line({ text = l, font = tfont }, tfont.line_height)
        end
        if opts.subtitle and opts.subtitle ~= "" then
            local sf = ui.font("sans", 26)
            for _, l in ipairs(sf:wrap(opts.subtitle, width)) do
                push_line({ text = l, font = sf, color = DARK }, sf.line_height)
            end
        end
        y = y + dp(24)
        for _, b in ipairs(opts.blocks or {}) do
            local f = (b.kind == "h") and head or body
            local indent = (b.kind == "li") and dp(36) or 0
            local text = b.text
            local lines = f:wrap(text, width - indent)
            local starts = b.links and line_starts(text, lines)
            if b.kind == "h" then y = y + dp(18) end
            for k, l in ipairs(lines) do
                local item = { text = l, font = f, x = indent }
                if starts then item.links = line_links(f, text, b.links, starts[k], l) end
                if b.kind == "li" and k == 1 then item.bullet = true end
                push_line(item, f.line_height)
            end
            y = y + math.floor(f.line_height * 0.45)
        end
        if #cur > 0 then pages[#pages + 1] = cur end
        if #pages == 0 then pages[1] = {} end
        scr.pages, scr.margin = pages, margin
        scr.layout_key = W .. "x" .. H .. ":" .. p.size
    end

    local function follow(href)
        local url = opts.base and net.resolve(opts.base, href) or href
        if not url:match("^https?://") then return ui.toast("Can't open " .. href) end
        if opts.on_link then return opts.on_link(url) end
        reader.open_url(url, { header = opts.header })
    end

    function scr:turn(d)
        local n = #self.pages
        local np = math.max(1, math.min(n, self.page + d))
        if np ~= self.page then
            self.page = np
            self.turns = self.turns + 1
            ui.redraw(self.turns % (p.flash_every or 6) == 0)
        end
    end

    function scr:on_tap(ev)
        if ev.x < ui.rt.W / 3 then self:turn(-1) else self:turn(1) end
    end

    function scr:on_swipe(ev)
        if ev.dir == "left" or ev.dir == "up" then self:turn(1)
        elseif ev.dir == "right" or ev.dir == "down" then self:turn(-1) end
    end

    function scr:menu()
        local items = {
            { title = "Larger text" }, { title = "Smaller text" },
            { title = "Go to first page" }, { title = "Go to last page" },
        }
        for _, a in ipairs(opts.actions or {}) do items[#items + 1] = { title = a[1], subtitle = a[3] } end
        ui.choose("Reading options", items, function(i)
            local frac = (self.page - 1) / math.max(1, #self.pages)
            if i == 1 or i == 2 then
                p.size = math.max(1, math.min(#SIZES, p.size + (i == 1 and 1 or -1)))
                store.save("reader", p)
                self.layout_key = nil
                self.relayout_frac = frac
            elseif i == 3 then self.page = 1
            elseif i == 4 then self.page = #self.pages
            else
                local a = opts.actions[i - 4]
                if a then a[2]() end
            end
            ui.redraw(true)
        end)
    end

    function scr:render(ctx)
        local s = ctx.s
        local top = ctx:header(opts.header or "", { right = { "☰", function() self:menu() end, size = 44 } })
        local key = ctx.W .. "x" .. ctx.H .. ":" .. p.size
        if self.layout_key ~= key then
            layout(ctx.W, ctx.H, top)
            if self.relayout_frac then
                self.page = math.max(1, math.floor(self.relayout_frac * #self.pages) + 1)
                self.relayout_frac = nil
            end
        end
        self.page = math.min(self.page, #self.pages)
        local y0 = top + dp(30)
        for _, it in ipairs(self.pages[self.page]) do
            local x = self.margin + (it.x or 0)
            if it.bullet then
                s:fill_circle(x - dp(20), y0 + it.y + it.font.ascent * 0.62, dp(6), BLACK)
            end
            it.font:draw_top(s, x, y0 + it.y, it.text, it.color or BLACK)
            for _, lk in ipairs(it.links or {}) do
                local ly = y0 + it.y + it.font.ascent + dp(4)
                s:fill_rect(x + lk[1], ly, lk[2] - lk[1], dp(2), BLACK)
                local href = lk[3]
                ctx:hit(x + lk[1] - dp(8), y0 + it.y, lk[2] - lk[1] + dp(16), it.font.line_height,
                    function() follow(href) end, nil, { label = lk[4], href = href })
            end
        end
        -- footer: progress
        local ff = ui.font("sans", 24)
        local pg = string.format("%d / %d", self.page, #self.pages)
        local fy = ctx.H - dp(60)
        ff:draw_top(s, ctx.W - self.margin - ff:width(pg), fy, pg, DARK)
        local bw = ctx.W - 2 * self.margin - dp(140)
        s:fill_rect(self.margin, fy + dp(14), bw, dp(3), LIGHT)
        s:fill_rect(self.margin, fy + dp(12), math.floor(bw * self.page / #self.pages), dp(7), BLACK)
    end

    ui.push(scr)
    return scr
end

-- Download a web page and show it in the reader. Links on it keep working;
-- opts: header=, title= (if the page has none), actions(title, url, blocks)=, on_link=.
function reader.open_url(url, opts)
    opts = opts or {}
    if not kindle.ensure_wifi() then return ui.alert("Offline", "Wi-Fi isn't connected.") end
    ui.busy("Loading page…")
    local resp, err = net.get(url, { Accept = "text/html,application/xhtml+xml" })
    if not resp then return ui.alert("Couldn't load page", err) end
    if resp.status ~= 200 then return ui.alert("Couldn't load page", "HTTP " .. resp.status) end
    local ctype = resp.headers["content-type"] or ""
    local blocks
    if ctype:find("text/plain") then blocks = html.text_blocks(resp.body) else blocks = html.to_blocks(resp.body) end
    if #blocks == 0 then blocks = { { kind = "p", text = "This page has no readable text (it may need JavaScript)." } } end
    local t = resp.body:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>(.-)</[Tt][Ii][Tt][Ll][Ee]>")
    local title = t and html.strip(t) or opts.title or url
    local page_url = resp.url or url
    local actions = opts.actions and opts.actions(title, page_url, blocks) or {
        { "Export to Kindle documents", function()
            local p = reader.export_txt("Web", title, blocks, page_url)
            ui.toast("Saved to " .. p:gsub("^/mnt/us/", ""))
        end },
    }
    return reader.open({ header = opts.header, title = title, subtitle = page_url, blocks = blocks,
        actions = actions, base = page_url, on_link = opts.on_link })
end

-- Write an article as a plain text file in the Kindle's documents folder so
-- KOReader (or the Kindle library) can open it later.
function reader.export_txt(folder, title, blocks, source)
    local sys = require("core.sys")
    local dir = "/mnt/us/documents/" .. folder
    if os.getenv("EINK_SIM") then dir = store.dir("export/" .. folder) end
    sys.mkdir_p(dir)
    local lines = { title or "", string.rep("=", 40), "" }
    if source then lines[#lines + 1] = source; lines[#lines + 1] = "" end
    for _, b in ipairs(blocks) do
        if b.kind == "h" then
            lines[#lines + 1] = ""
            lines[#lines + 1] = b.text
            lines[#lines + 1] = string.rep("-", math.min(40, #b.text))
        elseif b.kind == "li" then
            lines[#lines + 1] = "• " .. b.text
        else
            lines[#lines + 1] = b.text
            lines[#lines + 1] = ""
        end
    end
    local path = dir .. "/" .. store.slug(title or "article", 80) .. ".txt"
    sys.write_file(path, table.concat(lines, "\n"))
    return path
end

return reader
