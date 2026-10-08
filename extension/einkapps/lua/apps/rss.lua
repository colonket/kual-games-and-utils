-- RSS & Reddit reader (ported from CrossPoint Apps' RssActivity). Feeds
-- are fetched when you ask and cached, so you can read offline.
local ui = require("core.ui")
local gfx = require("core.gfx")
local sys = require("core.sys")
local store = require("core.store")
local net = require("core.net")
local json = require("core.json")
local html = require("core.html")
local kindle = require("core.kindle")
local keyboard = require("core.keyboard")
local reader = require("core.reader")

local dp = ui.dp
local BLACK, DARK = gfx.BLACK, gfx.DARK

local M = {}

local DEFAULTS = {
    "https://news.ycombinator.com/rss",
    "https://www.reddit.com/r/kindle/.rss",
    "https://www.reddit.com/r/chess/.rss",
    "https://www.reddit.com/r/magicTCG/.rss",
    "https://feeds.bbci.co.uk/news/rss.xml",
    "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en",
    "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml",
    "https://finance.yahoo.com/news/rssindex",
}

local function friendly(url)
    local sub = url:match("reddit%.com/r/([^/]+)")
    if sub then return "r/" .. sub end
    if url:match("reddit%.com/?%.rss") then return "Reddit front page" end
    local host = url:match("^%a+://([^/]+)") or url
    host = host:gsub("^www%.", ""):gsub("^feeds%.", ""):gsub("^rss%.", "")
    return host
end
M.friendly = friendly

local function normalize(input)
    input = input:gsub("^%s+", ""):gsub("%s+$", "")
    local sub = input:match("^/?r/([%w_]+)$")
    if sub then return "https://www.reddit.com/r/" .. sub .. "/.rss" end
    if not input:match("^%a+://") then input = "https://" .. input end
    return input
end

local function age(ts)
    if not ts then return "" end
    local d = os.time() - ts
    if d < 3600 then return math.max(1, math.floor(d / 60)) .. "m" end
    if d < 86400 then return math.floor(d / 3600) .. "h" end
    return math.floor(d / 86400) .. "d"
end

local MONTHS = { Jan = 1, Feb = 2, Mar = 3, Apr = 4, May = 5, Jun = 6, Jul = 7, Aug = 8, Sep = 9, Oct = 10, Nov = 11, Dec = 12 }
local function parse_date(s)
    if not s then return nil end
    local y, mo, d, h, mi = s:match("(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d)")
    if y then return os.time({ year = y, month = mo, day = d, hour = h, min = mi }) end
    local dd, mon, yy, hh, mm = s:match("(%d+)%s+(%a%a%a)%a*%s+(%d%d%d%d)%s+(%d+):(%d+)")
    if dd and MONTHS[mon] then return os.time({ year = yy, month = MONTHS[mon], day = dd, hour = hh, min = mm }) end
    return nil
end

function M.new()
    local cfg = store.load("rss", { feeds = DEFAULTS })
    local dir = store.dir("rss")
    local scr = { state = { page = 1 } }

    local function cache_file(url) return dir .. "/" .. store.slug(friendly(url) .. "_" .. #url, 80) .. ".json" end
    local function load_feed(url) return json.decode(sys.read_file(cache_file(url)) or "") end

    local function refresh(urls)
        if not kindle.ensure_wifi() then return ui.alert("Offline", "Wi-Fi isn't connected. Cached articles are still available.") end
        local failed = {}
        for k, url in ipairs(urls) do
            ui.busy(string.format("Fetching %d/%d: %s", k, #urls, friendly(url)))
            local resp, err = net.get(url, { Accept = "application/rss+xml, application/atom+xml, text/xml, */*" })
            if resp and resp.status == 200 then
                local feed = html.parse_feed(resp.body)
                local items = {}
                for i, it in ipairs(feed.items) do
                    if i > 60 then break end
                    items[#items + 1] = {
                        title = it.title, link = it.link, author = it.author,
                        ts = parse_date(it.date),
                        body = it.content or it.summary or "",
                    }
                end
                sys.write_file(cache_file(url), json.encode({ title = feed.title, items = items, fetched = os.time() }))
            else
                failed[#failed + 1] = friendly(url) .. ": " .. tostring(err or (resp and ("HTTP " .. resp.status)))
            end
        end
        if #failed > 0 then ui.alert("Some feeds failed", table.concat(failed, "\n")) end
        ui.redraw(true)
    end

    local function open_item(feed_title, it)
        local blocks = html.to_blocks(it.body or "")
        if #blocks == 0 then blocks = { { kind = "p", text = "(No summary in the feed. Use ☰ → Download full article.)" } } end
        local sub = table.concat({ feed_title or "", it.author or "", it.ts and os.date("%b %d, %H:%M", it.ts) or "" }, "  ·  "):gsub("^[ ·]+", "")
        local actions = {}
        if it.link then
            actions[#actions + 1] = { "Download full article", function()
                if not kindle.ensure_wifi() then return ui.alert("Offline", "Wi-Fi isn't connected.") end
                ui.busy("Downloading…")
                local resp, err = net.get(it.link)
                if not resp or resp.status ~= 200 then return ui.alert("Download failed", err or ("HTTP " .. resp.status)) end
                local full = html.to_blocks(resp.body)
                ui.pop()   -- close the summary view
                reader.open({ header = feed_title, title = it.title, subtitle = it.link, blocks = full,
                    base = resp.url or it.link, actions = {
                    { "Export to Kindle documents", function()
                        local p = reader.export_txt("Articles", it.title, full, it.link)
                        ui.toast("Saved to " .. p:gsub("^/mnt/us/", ""))
                    end },
                } })
            end, it.link }
        end
        actions[#actions + 1] = { "Export to Kindle documents", function()
            local p = reader.export_txt("Articles", it.title, blocks, it.link)
            ui.toast("Saved to " .. p:gsub("^/mnt/us/", ""))
        end }
        reader.open({ header = feed_title, title = it.title, subtitle = sub, blocks = blocks, actions = actions,
            base = it.link })
    end

    local function open_feed(url)
        local data = load_feed(url)
        if not data then
            refresh({ url })
            data = load_feed(url)
            if not data then return end
        end
        local fs = { state = { page = 1 } }
        function fs:render(ctx)
            local title = friendly(url)
            local top = ctx:header(title, { right = { "⟲", function() refresh({ url }); data = load_feed(url) or data end, size = 44 } })
            local items = {}
            for _, it in ipairs(data.items or {}) do
                items[#items + 1] = {
                    title = it.title,
                    subtitle = table.concat({ it.author or "", it.ts and (age(it.ts) .. " ago") or "" }, "  ·  "):gsub("^[ ·]+", ""),
                    on_tap = function() open_item(title, it) end,
                }
            end
            ctx:list(ui.M, top + dp(10), ctx.W - 2 * ui.M, ctx.H - top - dp(70), items, self.state,
                { empty = "No items in this feed.", row_h = dp(140) })
            ui.font("sans", 24):draw_top(ctx.s, ui.M, ctx.H - dp(50), "Updated " .. age(data.fetched) .. " ago", DARK)
        end
        ui.push(fs)
    end

    function scr:render(ctx)
        local top = ctx:header("RSS & Reddit", { right = { { "+", function()
            keyboard({ title = "Add feed", hint = "URL or r/subreddit",
                help = "Paste a feed URL (https://…/feed) or type r/name for a subreddit.",
                on_done = function(t)
                    if t == "" then return end
                    local u = normalize(t)
                    table.insert(cfg.feeds, u)
                    store.save("rss", cfg)
                    refresh({ u })
                end })
        end, size = 52 }, { "⟲", function() refresh(cfg.feeds) end, size = 44 } } })
        local items = {}
        for _, url in ipairs(cfg.feeds) do
            local d = load_feed(url)
            local u = url
            items[#items + 1] = {
                title = friendly(url),
                subtitle = d and string.format("%d items · updated %s ago", #(d.items or {}), age(d.fetched)) or "Not downloaded yet",
                on_tap = function() open_feed(u) end,
                on_hold = function()
                    ui.confirm("Remove feed?", u, "Remove", function()
                        for i, f in ipairs(cfg.feeds) do if f == u then table.remove(cfg.feeds, i) break end end
                        store.save("rss", cfg)
                        os.remove(cache_file(u))
                    end)
                end,
            }
        end
        ctx:list(ui.M, top + dp(10), ctx.W - 2 * ui.M, ctx.H - top - dp(80), items, self.state,
            { empty = "No feeds. Tap + to add one." })
        ui.font("sans", 24):draw_top(ctx.s, ui.M, ctx.H - dp(56), "⟲ downloads all feeds · hold a feed to remove it", DARK)
    end
    return scr
end

return M
