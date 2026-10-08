-- Weather (ported from CrossPoint Apps' WeatherActivity) using Open-Meteo
-- (no API key). Pick a city from the built-in list or search any place;
-- forecasts are cached so they stay readable offline.
local ui = require("core.ui")
local gfx = require("core.gfx")
local font = require("core.font")
local sys = require("core.sys")
local store = require("core.store")
local net = require("core.net")
local json = require("core.json")
local kindle = require("core.kindle")
local keyboard = require("core.keyboard")

local dp = ui.dp
local BLACK, WHITE, DARK, GRAY, PALE, LIGHT, MID = gfx.BLACK, gfx.WHITE, gfx.DARK, gfx.GRAY, gfx.PALE, gfx.LIGHT, gfx.MID

local M = {}

local function describe(code)
    code = tonumber(code) or -1
    if code == 0 then return "Clear sky", "sun"
    elseif code == 1 then return "Mainly clear", "sun"
    elseif code == 2 then return "Partly cloudy", "partly"
    elseif code == 3 then return "Overcast", "cloud"
    elseif code == 45 or code == 48 then return "Fog", "fog"
    elseif code >= 51 and code <= 57 then return "Drizzle", "rain"
    elseif code >= 61 and code <= 67 then return "Rain", "rain"
    elseif code >= 71 and code <= 77 then return "Snow", "snow"
    elseif code >= 80 and code <= 82 then return "Rain showers", "rain"
    elseif code == 85 or code == 86 then return "Snow showers", "snow"
    elseif code >= 95 then return "Thunderstorm", "storm" end
    return "Unknown", "cloud"
end

-- Icons drawn with primitives, centered on (cx, cy) with radius r.
local function cloud(s, cx, cy, r, fill)
    local parts = { { -0.45, 0.1, 0.38 }, { 0.0, -0.15, 0.5 }, { 0.45, 0.1, 0.38 } }
    for _, p in ipairs(parts) do s:fill_circle(cx + p[1] * r, cy + p[2] * r, p[3] * r + dp(5), BLACK) end
    s:fill_round_rect(cx - 0.83 * r - dp(5), cy + 0.05 * r - dp(5), 1.66 * r + dp(10), 0.45 * r + dp(10), 0.2 * r, BLACK)
    for _, p in ipairs(parts) do s:fill_circle(cx + p[1] * r, cy + p[2] * r, p[3] * r, fill or WHITE) end
    s:fill_round_rect(cx - 0.83 * r, cy + 0.05 * r, 1.66 * r, 0.45 * r, 0.2 * r, fill or WHITE)
end

local function sun(s, cx, cy, r)
    s:fill_circle(cx, cy, r * 0.45, BLACK)
    for k = 0, 7 do
        local a = math.rad(k * 45)
        s:line(cx + math.cos(a) * r * 0.62, cy + math.sin(a) * r * 0.62, cx + math.cos(a) * r * 0.9, cy + math.sin(a) * r * 0.9, BLACK, math.max(3, r * 0.09))
    end
end

function M.icon(s, cx, cy, r, kind)
    if kind == "sun" then sun(s, cx, cy, r)
    elseif kind == "partly" then
        sun(s, cx + r * 0.3, cy - r * 0.3, r * 0.7)
        cloud(s, cx - r * 0.1, cy + r * 0.15, r * 0.8)
    elseif kind == "cloud" then cloud(s, cx, cy, r, LIGHT)
    elseif kind == "fog" then
        for k = 0, 3 do
            s:fill_round_rect(cx - r * 0.85 + (k % 2) * r * 0.15, cy - r * 0.5 + k * r * 0.32, r * 1.55, r * 0.14, r * 0.07, BLACK)
        end
    else
        cloud(s, cx, cy - r * 0.3, r * 0.85, kind == "storm" and MID or LIGHT)
        if kind == "rain" then
            for k = -1, 1 do
                s:line(cx + k * r * 0.4, cy + r * 0.35, cx + k * r * 0.4 - r * 0.12, cy + r * 0.75, BLACK, math.max(3, r * 0.09))
            end
        elseif kind == "snow" then
            for k = -1, 1 do s:fill_circle(cx + k * r * 0.4, cy + r * 0.55 + (k % 2) * r * 0.12, r * 0.09, BLACK) end
        else
            s:fill_polygon({ { cx + r * 0.05, cy + r * 0.2 }, { cx - r * 0.25, cy + r * 0.62 }, { cx, cy + r * 0.6 },
                { cx - r * 0.12, cy + r * 0.95 }, { cx + r * 0.3, cy + r * 0.45 }, { cx + r * 0.05, cy + r * 0.47 },
                { cx + r * 0.2, cy + r * 0.2 } }, BLACK)
        end
    end
end

local cities_cache = nil
local function cities()
    if not cities_cache then
        cities_cache = json.decode(sys.read_file(ui.rt.root .. "/assets/cities.json") or "[]") or {}
    end
    return cities_cache
end

local function cache_name(loc) return "weather_" .. store.slug(loc.name .. "_" .. string.format("%.2f_%.2f", loc.lat, loc.lon), 80) end

local function fetch(loc, units)
    local imperial = units == "F"
    local url = string.format("https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        .. "&current=temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"
        .. "&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"
        .. "&hourly=temperature_2m,weather_code,precipitation_probability&forecast_hours=24"
        .. "&timezone=auto&forecast_days=6%s",
        loc.lat, loc.lon, imperial and "&temperature_unit=fahrenheit&wind_speed_unit=mph" or "")
    local resp, err = net.get(url)
    if not resp then return nil, err end
    if resp.status ~= 200 then return nil, "HTTP " .. resp.status end
    local d = json.decode(resp.body)
    if type(d) ~= "table" or not d.current then return nil, "unexpected response" end
    d.fetched_at = os.time()
    d.units = units
    store.save(cache_name(loc), d)
    return d
end

local function search_places(q)
    local url = "https://geocoding-api.open-meteo.com/v1/search?count=10&language=en&format=json&name=" .. net.urlencode(q)
    local resp, err = net.get(url)
    if not resp then return nil, err end
    local d = json.decode(resp.body) or {}
    local out = {}
    for _, r in ipairs(d.results or {}) do
        out[#out + 1] = { name = r.name, lat = r.latitude, lon = r.longitude,
            region = table.concat({ r.admin1 or "", r.country or "" }, ", "):gsub("^, ", "") }
    end
    return out
end

local function ago(t)
    local d = os.time() - (t or 0)
    if d < 90 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. " min ago" end
    if d < 86400 * 2 then return math.floor(d / 3600) .. " h ago" end
    return math.floor(d / 86400) .. " days ago"
end

function M.new()
    local cfg = store.load("weather", { units = "F", loc = nil, saved = {} })
    local scr = {}

    local function save_cfg() store.save("weather", cfg) end

    local function choose_location()
        local opts = {}
        opts[#opts + 1] = { title = "Search for a place…", bold = true }
        for _, l in ipairs(cfg.saved) do opts[#opts + 1] = { title = l.name, subtitle = l.region, loc = l } end
        for _, c in ipairs(cities()) do opts[#opts + 1] = { title = c.name, loc = c } end
        ui.choose("Location", opts, function(i, it)
            if i == 1 then
                keyboard({ title = "Search place", on_done = function(q)
                    if q == "" then return end
                    ui.busy("Searching…")
                    if not kindle.ensure_wifi() then return ui.alert("Offline", "Wi-Fi isn't connected.") end
                    local res, err = search_places(q)
                    if not res then return ui.alert("Search failed", err) end
                    if #res == 0 then return ui.toast("No places found for " .. q) end
                    local o2 = {}
                    for _, r in ipairs(res) do o2[#o2 + 1] = { title = r.name, subtitle = r.region, loc = r } end
                    ui.choose("Results", o2, function(_, r)
                        cfg.loc = r.loc
                        local dup = false
                        for _, l in ipairs(cfg.saved) do if l.name == r.loc.name and l.region == r.loc.region then dup = true end end
                        if not dup then table.insert(cfg.saved, 1, r.loc) end
                        while #cfg.saved > 8 do table.remove(cfg.saved) end
                        save_cfg()
                        scr:refresh()
                    end)
                end })
            else
                cfg.loc = it.loc
                save_cfg()
                scr:refresh()
            end
        end)
    end

    function scr:load_cache()
        self.data = cfg.loc and store.load(cache_name(cfg.loc)) or nil
        if self.data and not self.data.current then self.data = nil end
    end

    function scr:refresh()
        self:load_cache()
        if not cfg.loc then return end
        ui.busy("Updating weather…")
        if not kindle.ensure_wifi() then
            self.err = "Offline — showing saved forecast."
            ui.redraw()
            return
        end
        local d, err = fetch(cfg.loc, cfg.units)
        if d then self.data, self.err = d, nil else self.err = "Update failed: " .. tostring(err) end
        ui.redraw(true)
    end

    function scr:enter()
        self:load_cache()
        if not cfg.loc then
            ui.after(10, choose_location)
        elseif not self.data or os.time() - (self.data.fetched_at or 0) > 1800 or self.data.units ~= cfg.units then
            ui.after(10, function() self:refresh() end)
        end
    end

    function scr:render(ctx)
        local s = ctx.s
        local top = ctx:header(cfg.loc and cfg.loc.name or "Weather", {
            right = { { "°" .. cfg.units, function()
                cfg.units = cfg.units == "F" and "C" or "F"; save_cfg(); self:refresh()
            end, size = 34 }, { "⟲", function() self:refresh() end, size = 44 } } })
        local x, w = ui.M, ctx.W - 2 * ui.M
        local y = top + dp(30)
        local d = self.data
        if not d then
            ctx:paragraph(x, y + dp(100), w, self.err or "Choose a location to see the forecast.",
                { font = ui.font("sans", 34), align = "center" })
            ctx:button(x, ctx.H - ui.BTN_H - dp(40), w, ui.BTN_H, "Choose location", choose_location, { style = "solid" })
            return
        end
        local c = d.current or {}
        local u = d.current_units or {}
        local desc, kind = describe(c.weather_code)
        if kind == "sun" and c.is_day == 0 then kind = "sun" end
        -- current conditions
        M.icon(s, x + dp(150), y + dp(150), dp(130), kind)
        local tf = ui.font("num", 180)
        local temp = string.format("%d°", math.floor((c.temperature_2m or 0) + 0.5))
        tf:draw_center_ink(s, x + dp(320), y + dp(10), w - dp(320), dp(220), temp, BLACK)
        y = y + dp(300)
        local bf = ui.font("bold", 44)
        bf:draw_center(s, x, y, w, bf.height, desc, BLACK)
        y = y + bf.height + dp(16)
        local sf = ui.font("sans", 30)
        local line = string.format("Feels like %d°  ·  Humidity %d%%  ·  Wind %d %s",
            math.floor((c.apparent_temperature or 0) + 0.5), c.relative_humidity_2m or 0,
            math.floor((c.wind_speed_10m or 0) + 0.5), u.wind_speed_10m or "")
        sf:draw_center(s, x, y, w, sf.height, sf:ellipsize(line, w), DARK)
        y = y + sf.height + dp(36)
        -- next hours
        local h = d.hourly or {}
        if h.time and #h.time > 0 then
            s:fill_rect(x, y, w, ui.BORDER, LIGHT)
            y = y + dp(20)
            local n = 6
            local cw = w / n
            for k = 1, n do
                local idx = (k - 1) * 3 + 1
                if h.time[idx] then
                    local hx = x + (k - 1) * cw
                    local hh = tonumber(h.time[idx]:match("T(%d%d)")) or 0
                    local label = string.format("%d%s", (hh % 12 == 0) and 12 or hh % 12, hh < 12 and "am" or "pm")
                    sf:draw_center(s, hx, y, cw, sf.height, label, DARK)
                    local _, hk = describe(h.weather_code[idx])
                    M.icon(s, hx + cw / 2, y + dp(100), dp(40), hk)
                    ui.font("bold", 34):draw_center(s, hx, y + dp(150), cw, dp(50), string.format("%d°", math.floor(h.temperature_2m[idx] + 0.5)), BLACK)
                end
            end
            y = y + dp(230)
        end
        -- daily forecast
        s:fill_rect(x, y, w, ui.BORDER, LIGHT)
        y = y + dp(10)
        local dd = d.daily or {}
        local rowh = dp(104)
        local df = ui.font("sans", 34)
        local maxrows = math.floor((ctx.H - y - dp(120)) / rowh)
        for k = 1, math.min(#(dd.time or {}), 6, maxrows) do
            local ry = y + (k - 1) * rowh
            local yy, mm, dday = dd.time[k]:match("(%d+)-(%d+)-(%d+)")
            local t = os.time({ year = tonumber(yy), month = tonumber(mm), day = tonumber(dday), hour = 12 })
            local name = k == 1 and "Today" or os.date("%a %d", t)
            df:draw_top(s, x, ry + (rowh - df.height) / 2, name, BLACK)
            local _, k2 = describe(dd.weather_code[k])
            M.icon(s, x + dp(290), ry + rowh / 2, dp(38), k2)
            local pp = dd.precipitation_probability_max and dd.precipitation_probability_max[k]
            if pp and pp >= 20 then
                ui.font("sans", 28):draw_top(s, x + dp(360), ry + (rowh - dp(34)) / 2, pp .. "%", DARK)
            end
            local hi = string.format("%d°", math.floor(dd.temperature_2m_max[k] + 0.5))
            local lo = string.format("%d°", math.floor(dd.temperature_2m_min[k] + 0.5))
            local hf = ui.font("bold", 36)
            hf:draw_top(s, x + w - dp(110), ry + (rowh - hf.height) / 2, hi, BLACK)
            df:draw_top(s, x + w - dp(250), ry + (rowh - df.height) / 2, lo, DARK)
            if k < 6 then s:fill_rect(x, ry + rowh - 1, w, dp(2), PALE) end
        end
        -- footer
        local ff = ui.font("sans", 26)
        local foot = (self.err and (self.err .. "  ") or "") .. "Updated " .. ago(d.fetched_at) .. " · Open-Meteo"
        ff:draw_top(s, x, ctx.H - dp(60), ff:ellipsize(foot, w - dp(220)), DARK)
        local cl = "Change ›"
        ff:draw_top(s, x + w - ff:width(cl), ctx.H - dp(60), cl, BLACK)
        ctx:hit(x + w - dp(240), ctx.H - dp(100), dp(240), dp(100), choose_location, nil, { label = "Change" })
    end
    return scr
end

return M
