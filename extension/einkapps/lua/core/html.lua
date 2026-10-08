-- HTML/XML helpers: entity decoding, tag stripping, readable-text extraction
-- and a forgiving RSS/Atom parser.
local sys = require("core.sys")

local html = {}

local ENT = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", ndash = "–", mdash = "—",
    hellip = "…", rsquo = "’", lsquo = "‘", rdquo = "”", ldquo = "“", sbquo = "‚", bdquo = "„",
    copy = "©", reg = "®", trade = "™", deg = "°", middot = "·", bull = "•", laquo = "«", raquo = "»",
    times = "×", divide = "÷", plusmn = "±", frac12 = "½", frac14 = "¼", frac34 = "¾", euro = "€",
    pound = "£", yen = "¥", cent = "¢", sect = "§", para = "¶", prime = "′", Prime = "″", minus = "−",
    eacute = "é", egrave = "è", ecirc = "ê", euml = "ë", aacute = "á", agrave = "à", acirc = "â", auml = "ä",
    atilde = "ã", aring = "å", oacute = "ó", ograve = "ò", ocirc = "ô", ouml = "ö", otilde = "õ", oslash = "ø",
    uacute = "ú", ugrave = "ù", ucirc = "û", uuml = "ü", iacute = "í", igrave = "ì", icirc = "î", iuml = "ï",
    ccedil = "ç", ntilde = "ñ", szlig = "ß", aelig = "æ", Eacute = "É", Aacute = "Á", Oacute = "Ó", Uacute = "Ú",
    Ntilde = "Ñ", Ccedil = "Ç", Auml = "Ä", Ouml = "Ö", Uuml = "Ü", zwj = "", zwnj = "", shy = "", thinsp = " ",
    ensp = " ", emsp = " ", larr = "←", rarr = "→", uarr = "↑", darr = "↓", hearts = "♥", check = "✓",
}

function html.decode(s)
    if not s then return "" end
    return (s:gsub("&(#?[%w]+);", function(e)
        if e:sub(1, 1) == "#" then
            local n
            if e:sub(2, 2) == "x" or e:sub(2, 2) == "X" then n = tonumber(e:sub(3), 16) else n = tonumber(e:sub(2)) end
            if n and n > 0 and n < 0x110000 then
                if n == 160 then return " " end
                return sys.utf8_char(n)
            end
            return ""
        end
        return ENT[e] or ("&" .. e .. ";")
    end))
end

-- Lowercase tag names so Lua patterns can match them.
local function lower_tags(s)
    return (s:gsub("<(/?)([%a][%w:-]*)", function(slash, name) return "<" .. slash .. name:lower() end))
end

local function drop_blocks(s, tags)
    for _, t in ipairs(tags) do
        s = s:gsub("<" .. t .. "[%s>/].-</" .. t .. "%s*>", " ")
        s = s:gsub("<" .. t .. ">.-</" .. t .. "%s*>", " ")
    end
    return s
end

function html.strip(s)
    s = s:gsub("<!%-%-.-%-%->", " ")
    s = s:gsub("<[^>]*>", " ")
    s = html.decode(s)
    s = s:gsub("[ \t\r\n]+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Turn an HTML document into readable blocks: {kind="h"|"p"|"li", text=}
function html.to_blocks(doc)
    local s = lower_tags(doc or "")
    s = s:gsub("<!%-%-.-%-%->", " ")
    s = drop_blocks(s, { "script", "style", "noscript", "svg", "head", "template", "iframe", "select", "button" })
    -- prefer the main content if marked up
    local main = s:match("<article[^>]*>(.-)</article>") or s:match("<main[^>]*>(.-)</main>")
    if main and #main > 400 then s = main else
        s = drop_blocks(s, { "nav", "footer", "header", "aside", "form" })
        s = s:match("<body[^>]*>(.*)</body>") or s
    end
    -- mark block boundaries with control characters
    s = s:gsub("<h([1-6])[^>]*>", "\1H"):gsub("</h[1-6]%s*>", "\1")
    s = s:gsub("<li[^>]*>", "\1L"):gsub("</li%s*>", "\1")
    s = s:gsub("<br%s*/?>", "\2")
    s = s:gsub("</?p>", "\1"):gsub("<p%s[^>]*>", "\1")
    s = s:gsub("</?div[^>]*>", "\1"):gsub("</?tr[^>]*>", "\1"):gsub("</?blockquote[^>]*>", "\1")
    s = s:gsub("</?section[^>]*>", "\1"):gsub("</?ul[^>]*>", "\1"):gsub("</?ol[^>]*>", "\1")
    s = s:gsub("</?table[^>]*>", "\1"):gsub("</?figure[^>]*>", "\1"):gsub("</?pre[^>]*>", "\1")
    s = s:gsub("<td[^>]*>", " "):gsub("<th[^>]*>", " ")
    s = s:gsub("<[^>]*>", "")
    s = html.decode(s)
    local blocks = {}
    for chunk in (s .. "\1"):gmatch("([^\1]*)\1") do
        local kind = "p"
        if chunk:sub(1, 1) == "H" then kind, chunk = "h", chunk:sub(2)
        elseif chunk:sub(1, 1) == "L" then kind, chunk = "li", chunk:sub(2) end
        chunk = chunk:gsub("[ \t\r\n]+", " "):gsub("\2", "\n"):gsub(" *\n *", "\n")
        chunk = chunk:gsub("^%s+", ""):gsub("%s+$", "")
        if #chunk > 1 then
            blocks[#blocks + 1] = { kind = kind, text = chunk }
        end
    end
    return blocks
end

-- Plain text (paragraphs separated by blank lines) into blocks; lines
-- that look like "== Heading ==" (Wikipedia extracts) become headings.
function html.text_blocks(text)
    local blocks = {}
    for para in ((text or "") .. "\n"):gmatch("(.-)\n") do
        local t = para:gsub("^%s+", ""):gsub("%s+$", "")
        if t ~= "" then
            local h = t:match("^=+%s*(.-)%s*=+$")
            if h then
                if h ~= "" then blocks[#blocks + 1] = { kind = "h", text = h } end
            else
                blocks[#blocks + 1] = { kind = "p", text = t }
            end
        end
    end
    return blocks
end

-- Minimal XML helpers for feeds ------------------------------------------------------
local function tag_text(block, name)
    local inner = block:match("<" .. name .. "[^>]*>(.-)</" .. name .. ">")
    if not inner then return nil end
    local cdata = inner:match("^%s*<!%[CDATA%[(.-)%]%]>%s*$")
    if cdata then return cdata end
    inner = inner:gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    return html.decode(inner)
end

-- Parse RSS 2.0 / Atom. Returns {title=, items={ {title, link, date, author, summary, content} }}
function html.parse_feed(xml)
    local feed = { items = {} }
    local x = xml:gsub("<(/?)[%w]+:([%w]+)", function(slash, local_name)
        -- keep content:encoded distinct; drop other namespaces
        return "<" .. slash .. local_name
    end)
    local channel = x:match("<channel[^>]*>(.-)</channel>") or x:match("<feed[^>]*>(.-)</feed>") or x
    local head = channel:match("^(.-)<item[%s>]") or channel:match("^(.-)<entry[%s>]") or channel
    feed.title = tag_text(head, "title")
    for item in x:gmatch("<item[%s>](.-)</item>") do
        local it = {
            title = tag_text(item, "title"),
            link = tag_text(item, "link"),
            date = tag_text(item, "pubDate") or tag_text(item, "date"),
            author = tag_text(item, "creator") or tag_text(item, "author"),
            summary = tag_text(item, "description"),
            content = tag_text(item, "encoded"),
        }
        feed.items[#feed.items + 1] = it
    end
    if #feed.items == 0 then
        for entry in x:gmatch("<entry[%s>](.-)</entry>") do
            local link = entry:match("<link[^>]-rel=\"alternate\"[^>]-href=\"([^\"]+)\"")
                or entry:match("<link[^>]-href=\"([^\"]+)\"")
            local author = entry:match("<author[^>]*>(.-)</author>")
            feed.items[#feed.items + 1] = {
                title = tag_text(entry, "title"),
                link = link and html.decode(link),
                date = tag_text(entry, "updated") or tag_text(entry, "published"),
                author = author and tag_text(author, "name"),
                summary = tag_text(entry, "summary"),
                content = tag_text(entry, "content"),
            }
        end
    end
    for _, it in ipairs(feed.items) do
        it.title = html.strip(it.title or "(untitled)")
        if it.link then it.link = it.link:gsub("^%s+", ""):gsub("%s+$", "") end
    end
    return feed
end

return html
