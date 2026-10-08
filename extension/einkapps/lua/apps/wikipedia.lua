-- Wikipedia (ported from CrossPoint Apps' WikipediaActivity): search,
-- read full articles as paginated text, and keep them offline.
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
local LANGS = { "en", "es", "fr", "de", "it", "pt", "nl", "pl", "ru", "ja", "zh" }

local function online()
    if kindle.ensure_wifi() then return true end
    ui.alert("Offline", "Wi-Fi isn't connected. Saved articles still work.")
    return false
end

function M.new()
    local cfg = store.load("wikipedia", { lang = "en", recent = {} })
    local scr = { state = { page = 1 } }
    local dir = store.dir("wikipedia")

    local function base() return "https://" .. cfg.lang .. ".wikipedia.org/w/api.php" end

    local function saved_list()
        local out = {}
        for _, f in ipairs(sys.list_dir(dir)) do
            if f:match("%.json$") then
                local d = json.decode(sys.read_file(dir .. "/" .. f) or "") or {}
                out[#out + 1] = { file = f, title = d.title or f, saved = d.saved or 0, lang = d.lang }
            end
        end
        table.sort(out, function(a, b) return a.saved > b.saved end)
        return out
    end

    local function open_article(title, blocks, from_file, lang)
        local actions = {}
        if not from_file then
            actions[#actions + 1] = { "Save for offline reading", function()
                local f = store.slug(title, 80) .. ".json"
                sys.write_file(dir .. "/" .. f, json.encode({ title = title, blocks = blocks, saved = os.time(), lang = lang }))
                ui.toast("Saved")
            end }
        else
            actions[#actions + 1] = { "Remove from saved", function()
                os.remove(dir .. "/" .. from_file)
                ui.toast("Removed")
            end }
        end
        actions[#actions + 1] = { "Export to Kindle documents", function()
            local p = reader.export_txt("Wikipedia", title, blocks, "https://" .. (lang or cfg.lang) .. ".wikipedia.org/wiki/" .. title:gsub(" ", "_"))
            ui.toast("Saved to " .. p:gsub("^/mnt/us/", ""))
        end, "as .txt — opens in KOReader" }
        reader.open({ header = "Wikipedia", title = title, blocks = blocks, actions = actions })
    end

    local function fetch_article(title)
        if not online() then return end
        ui.busy("Loading article…")
        local url = base() .. "?action=query&prop=extracts&explaintext=1&exsectionformat=wiki&redirects=1&format=json&titles=" .. net.urlencode(title)
        local resp, err = net.get(url)
        if not resp then return ui.alert("Couldn't load article", err) end
        local d = json.decode(resp.body) or {}
        local pages = (d.query or {}).pages or {}
        for _, p in pairs(pages) do
            if p.extract and p.extract ~= "" then
                local blocks = html.text_blocks(p.extract)
                table.insert(cfg.recent, 1, p.title)
                for i = #cfg.recent, 2, -1 do if cfg.recent[i] == p.title then table.remove(cfg.recent, i) end end
                while #cfg.recent > 10 do table.remove(cfg.recent) end
                store.save("wikipedia", cfg)
                open_article(p.title, blocks, nil, cfg.lang)
                return
            end
        end
        ui.alert("Not found", "No article text for “" .. title .. "”.")
    end

    local function search(q)
        if q == "" or not online() then return end
        ui.busy("Searching…")
        local url = base() .. "?action=opensearch&limit=15&namespace=0&format=json&search=" .. net.urlencode(q)
        local resp, err = net.get(url)
        if not resp then return ui.alert("Search failed", err) end
        local d = json.decode(resp.body)
        if type(d) ~= "table" or type(d[2]) ~= "table" or #d[2] == 0 then
            return ui.toast("No results for " .. q)
        end
        local opts = {}
        for i, t in ipairs(d[2]) do
            local desc = type(d[3]) == "table" and d[3][i] or nil
            opts[#opts + 1] = { title = t, subtitle = desc ~= "" and desc or nil }
        end
        ui.choose("Results: " .. q, opts, function(_, it) fetch_article(it.title) end)
    end

    function scr:render(ctx)
        local top = ctx:header("Wikipedia", { right = { cfg.lang:upper(), function()
            ui.choose("Wikipedia language", LANGS, function(i)
                cfg.lang = LANGS[i]; store.save("wikipedia", cfg)
            end, { selected = (function() for i, l in ipairs(LANGS) do if l == cfg.lang then return i end end end)() })
        end, size = 32 } })
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(30)
        ctx:button(x, y, w, ui.BTN_H, "Search Wikipedia…", function()
            keyboard({ title = "Search Wikipedia", on_done = search })
        end, { style = "solid", size = 38 })
        y = y + ui.BTN_H + dp(30)
        local items = {}
        for _, a in ipairs(saved_list()) do
            local file = a.file
            items[#items + 1] = {
                title = a.title, subtitle = "Saved " .. os.date("%b %d", a.saved) .. (a.lang and (" · " .. a.lang) or ""),
                on_tap = function()
                    local d = json.decode(sys.read_file(dir .. "/" .. file) or "") or {}
                    open_article(d.title or a.title, d.blocks or {}, file, d.lang)
                end,
                on_hold = function()
                    ui.confirm("Remove saved article?", a.title, "Remove", function()
                        os.remove(dir .. "/" .. file); ui.redraw()
                    end)
                end,
            }
        end
        for _, t in ipairs(cfg.recent) do
            local seen = false
            for _, it in ipairs(items) do if it.title == t then seen = true end end
            if not seen then
                items[#items + 1] = { title = t, subtitle = "Recently viewed (needs Wi-Fi)", on_tap = function() fetch_article(t) end }
            end
        end
        ui.font("bold", 30):draw_top(ctx.s, x, y, "SAVED & RECENT", DARK)
        y = y + dp(50)
        ctx:list(x, y, w, ctx.H - y - dp(20), items, self.state,
            { empty = "Search for an article. Open the ☰ menu while reading to save it for offline reading." })
    end
    return scr
end

return M
