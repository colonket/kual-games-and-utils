-- DuckDuckGo search (ported from CrossPoint Apps' DuckDuckGoActivity):
-- search the web through DuckDuckGo's HTML endpoint, open results as
-- clean paginated text, and keep pages for offline reading.
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
local DARK = gfx.DARK

local M = {}

-- Parse the result links out of html.duckduckgo.com's markup.
function M.parse_results(body)
    local out = {}
    for attrs, inner in body:gmatch("<a([^>]-class=\"[^\"]*result__a[^\"]*\"[^>]*)>(.-)</a>") do
        local href = attrs:match("href=\"([^\"]+)\"") or ""
        href = html.decode(href)
        local real = href:match("[?&]uddg=([^&]+)")
        if real then href = net.urldecode(real) end
        if href:sub(1, 2) == "//" then href = "https:" .. href end
        if href:match("^https?://") and not href:match("duckduckgo%.com/y%.js") then
            out[#out + 1] = { title = html.strip(inner), url = href }
        end
    end
    -- snippets appear in the same order as the results
    local k = 0
    for snip in body:gmatch("class=\"result__snippet\"[^>]*>(.-)</a>") do
        k = k + 1
        if out[k] then out[k].snippet = html.strip(snip) end
    end
    return out
end

function M.new()
    local dir = store.dir("ddg")
    local scr = { state = { page = 1 } }

    local function saved()
        local out = {}
        for _, f in ipairs(sys.list_dir(dir)) do
            if f:match("%.json$") then
                local d = json.decode(sys.read_file(dir .. "/" .. f) or "") or {}
                out[#out + 1] = { file = f, title = d.title or f, url = d.url, saved = d.saved or 0 }
            end
        end
        table.sort(out, function(a, b) return a.saved > b.saved end)
        return out
    end

    local function show_page(title, url, blocks, file)
        local actions = {}
        if not file then
            actions[#actions + 1] = { "Save for offline reading", function()
                sys.write_file(dir .. "/" .. store.slug(title, 80) .. ".json",
                    json.encode({ title = title, url = url, blocks = blocks, saved = os.time() }))
                ui.toast("Saved")
            end }
        else
            actions[#actions + 1] = { "Remove from saved", function() os.remove(dir .. "/" .. file); ui.toast("Removed") end }
        end
        actions[#actions + 1] = { "Export to Kindle documents", function()
            local p = reader.export_txt("Web", title, blocks, url)
            ui.toast("Saved to " .. p:gsub("^/mnt/us/", ""))
        end }
        reader.open({ header = "DuckDuckGo", title = title, subtitle = url, blocks = blocks, actions = actions })
    end

    local function open_result(r)
        if not kindle.ensure_wifi() then return ui.alert("Offline", "Wi-Fi isn't connected.") end
        ui.busy("Loading page…")
        local resp, err = net.get(r.url, { Accept = "text/html,application/xhtml+xml" })
        if not resp then return ui.alert("Couldn't load page", err) end
        if resp.status ~= 200 then return ui.alert("Couldn't load page", "HTTP " .. resp.status) end
        local ctype = resp.headers["content-type"] or ""
        local blocks
        if ctype:find("text/plain") then blocks = html.text_blocks(resp.body) else blocks = html.to_blocks(resp.body) end
        if #blocks == 0 then blocks = { { kind = "p", text = "This page has no readable text (it may need JavaScript)." } } end
        local t = resp.body:match("<[Tt][Ii][Tt][Ll][Ee][^>]*>(.-)</[Tt][Ii][Tt][Ll][Ee]>")
        show_page(t and html.strip(t) or r.title, resp.url or r.url, blocks)
    end

    local function search(q)
        if q == "" then return end
        if not kindle.ensure_wifi() then return ui.alert("Offline", "Wi-Fi isn't connected.") end
        ui.busy("Searching…")
        local resp, err = net.get("https://html.duckduckgo.com/html/?q=" .. net.urlencode(q))
        if resp and resp.status ~= 200 then
            resp, err = net.request({ url = "https://html.duckduckgo.com/html/", method = "POST", body = net.form({ q = q }) })
        end
        if not resp then return ui.alert("Search failed", err) end
        local results = M.parse_results(resp.body or "")
        if #results == 0 then return ui.alert("No results", "DuckDuckGo returned no results (or asked for a captcha). Try again in a minute.") end
        local opts = {}
        for _, r in ipairs(results) do
            opts[#opts + 1] = { title = r.title, subtitle = (r.url:match("^%a+://([^/]+)") or r.url) .. (r.snippet and (" — " .. r.snippet) or ""), r = r }
        end
        ui.choose(q, opts, function(_, it) open_result(it.r) end, { row_h = dp(140) })
    end

    function scr:render(ctx)
        local top = ctx:header("DuckDuckGo")
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(30)
        ctx:button(x, y, w, ui.BTN_H, "Search the web…", function()
            keyboard({ title = "Search", on_done = search })
        end, { style = "solid", size = 38 })
        y = y + ui.BTN_H + dp(30)
        ui.font("bold", 30):draw_top(ctx.s, x, y, "SAVED PAGES", DARK)
        y = y + dp(50)
        local items = {}
        for _, s in ipairs(saved()) do
            local file = s.file
            items[#items + 1] = {
                title = s.title, subtitle = s.url,
                on_tap = function()
                    local d = json.decode(sys.read_file(dir .. "/" .. file) or "") or {}
                    show_page(d.title or s.title, d.url, d.blocks or {}, file)
                end,
                on_hold = function()
                    ui.confirm("Remove saved page?", s.title, "Remove", function() os.remove(dir .. "/" .. file) end)
                end,
            }
        end
        ctx:list(x, y, w, ctx.H - y - dp(20), items, self.state,
            { empty = "Pages you save while reading (☰ → Save) appear here for offline reading." })
    end
    return scr
end

return M
