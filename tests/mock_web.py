#!/usr/bin/env python3
"""Canned responses for the network apps (weather, Wikipedia, RSS, DuckDuckGo)."""
import json, sys, urllib.parse, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

now = time.strftime("%Y-%m-%d")
FORECAST = {
  "current_units": {"wind_speed_10m": "mp/h"},
  "current": {"temperature_2m": 71.6, "apparent_temperature": 73.0, "relative_humidity_2m": 58, "weather_code": 2, "wind_speed_10m": 9.4, "is_day": 1},
  "hourly": {"time": ["%sT%02d:00" % (now, h % 24) for h in range(15, 39)],
             "temperature_2m": [71 - i * 0.6 for i in range(24)], "weather_code": [2,2,3,3,61,61,63,61,3,3,2,1,0,0,0,1,1,2,2,3,3,45,45,0],
             "precipitation_probability": [0]*24},
  "daily": {"time": [time.strftime("%Y-%m-%d", time.localtime(time.time() + 86400 * d)) for d in range(6)],
            "weather_code": [2, 61, 95, 0, 71, 45], "temperature_2m_max": [74, 66, 70, 78, 41, 55],
            "temperature_2m_min": [58, 55, 59, 60, 30, 44], "precipitation_probability_max": [10, 80, 65, 0, 40, 5]},
}
GEO = {"results": [{"name": "Chicago", "latitude": 41.8781, "longitude": -87.6298, "admin1": "Illinois", "country": "United States"}]}
EXTRACT = """Magic: The Gathering (colloquially known as Magic or MTG) is a collectible card game designed by Richard Garfield. Released in 1993 by Wizards of the Coast, Magic was the first trading card game.

== Gameplay ==
In a game of Magic, two or more players are engaged in a battle acting as powerful wizards called planeswalkers. Each player starts with 20 life points; a player loses when reduced to zero life, or when they have ten or more poison counters.

=== Commander ===
Commander is a multiplayer format with 100-card singleton decks and 40 starting life. A player who takes 21 combat damage from a single commander loses the game.
""" + "\n".join("Paragraph %d of filler text to make the article long enough to span several pages on the Kindle screen, so pagination can be tested properly." % i for i in range(40))
RSS = """<?xml version="1.0"?><rss version="2.0"><channel><title>Hacker News</title>
<item><title>Show HN: Running custom apps on a jailbroken Kindle</title><link>http://127.0.0.1:{port}/example.com/article</link><pubDate>Wed, 07 Oct 2026 18:00:00 +0000</pubDate><description><![CDATA[<p>A suite of <b>e-ink</b> apps &amp; games written in LuaJIT.</p><a href="https://news.ycombinator.com/item?id=4242">Comments</a>]]></description></item>
<item><title>Why e-ink is great for chess</title><link>https://example.com/b</link><pubDate>Tue, 06 Oct 2026 12:00:00 +0000</pubDate><description>Low glare, long battery life.</description></item>
</channel></rss>"""
ATOM = """<?xml version="1.0" encoding="UTF-8"?><feed xmlns="http://www.w3.org/2005/Atom"><title>r/kindle</title>
<entry><author><name>/u/reader42</name></author><content type="html">&lt;div class=&quot;md&quot;&gt;&lt;p&gt;My PW3 on 5.16.2.1.1 is jailbroken — what should I install first?&lt;/p&gt;&lt;ul&gt;&lt;li&gt;KOReader&lt;/li&gt;&lt;li&gt;renameotabin&lt;/li&gt;&lt;/ul&gt;&lt;/div&gt;</content>
<link href="https://www.reddit.com/r/kindle/comments/abc/x/"/><updated>2026-10-07T20:00:00+00:00</updated><title>Just jailbroke my Paperwhite</title></entry></feed>"""
DDG = """<html><body><div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=http%3A%2F%2F127.0.0.1%3A{port}%2Fexample.com%2Farticle&amp;rut=abc">KUAL &amp; KOReader guide</a>
<a class="result__snippet" href="#">How to run <b>apps</b> on a Kindle.</a></div>
<div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fsecond">Second result</a><a class="result__snippet">Another snippet</a></div></body></html>"""
ARTICLE = """<html><head><title>Running apps on a Kindle</title><style>p{color:red}</style><script>var x=1;</script></head>
<body><nav>Home | About</nav><article><h1>Running apps on a Kindle</h1><p>Jailbreaking lets you run <a href="#">KUAL</a> extensions. <a href="/news.ycombinator.com/item?id=4242">Discuss on HN</a></p>
<h2>Requirements</h2><ul><li>A jailbroken Kindle</li><li>KOReader installed</li></ul><p>""" + " ".join(["E-ink is wonderful for reading long articles."] * 30) + """</p></article><footer>(c) 2026</footer></body></html>"""
# Hacker News item pages, shaped like the real ones (tables, relative links)
HN_ITEM = {
  "4242": """<html><head><title>Show HN: Running custom apps on a jailbroken Kindle | Hacker News</title></head><body><center><table>
<tr><td><a href="news">Hacker News</a> | <a href="newest">new</a></td></tr>
<tr><td><span class="titleline"><a href="https://example.com/article">Show HN: Running custom apps on a jailbroken Kindle</a></span></td></tr>
<tr><td><table class="comment-tree"><tr class="athing comtr"><td><a href="user?id=reader42">reader42</a> 2 hours ago
<div class="comment"><div class="commtext">Great work! Does the life counter rotate panels for each seat?</div>
<div class="reply"><a href="item?id=4243">reply</a></div></div></td></tr></table></td></tr></table></center></body></html>""",
  "4243": """<html><head><title>Reply thread | Hacker News</title></head><body><table>
<tr><td><div class="commtext">Yes, every panel faces its player.</div></td></tr></table></body></html>""",
}

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *a): sys.stderr.write("web: " + (fmt % a) + "\n")
    def send(self, code, body, ctype="application/json"):
        if isinstance(body, (dict, list)): body = json.dumps(body)
        body = body.replace("{port}", str(self.server.server_address[1])).encode()
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self): self.do_GET()
    def do_GET(self):
        u = urllib.parse.urlparse(self.path); q = urllib.parse.parse_qs(u.query); p = u.path
        if p.startswith("/api.open-meteo.com/v1/forecast"): return self.send(200, FORECAST)
        if p.startswith("/geocoding-api.open-meteo.com"): return self.send(200, GEO)
        if p.startswith("/en.wikipedia.org/w/api.php"):
            if q.get("action") == ["opensearch"]:
                return self.send(200, [q["search"][0], ["Magic: The Gathering", "Magic: The Gathering Arena"], ["Collectible card game", "Digital version"], []])
            return self.send(200, {"query": {"pages": {"1": {"title": "Magic: The Gathering", "extract": EXTRACT}}}})
        if p.startswith("/news.ycombinator.com/rss"): return self.send(200, RSS, "application/rss+xml")
        if p.startswith("/news.ycombinator.com/item") and q.get("id", [""])[0] in HN_ITEM:
            return self.send(200, HN_ITEM[q["id"][0]], "text/html; charset=utf-8")
        if p.startswith("/www.reddit.com/r/kindle/"): return self.send(200, ATOM, "application/atom+xml")
        if p.startswith("/html.duckduckgo.com/html"): return self.send(200, DDG, "text/html")
        if p.startswith("/example.com/article"): return self.send(200, ARTICLE, "text/html; charset=utf-8")
        self.send(404, "not found", "text/plain")

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
