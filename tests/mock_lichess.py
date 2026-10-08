#!/usr/bin/env python3
"""A tiny fake of the Lichess Board API, enough to drive the Kindle client."""
import json, sys, threading, time, queue
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

TOKEN = "lip_testtoken123"
STATE = {"events": [], "games": {}, "lock": threading.Lock()}
AI_REPLIES = ["e7e5", "b8c6", "g8f6", "f8c5", "d7d6", "c8g4"]

def new_game(gid, white, black, speed="rapid", clock=(600000, 5000)):
    g = {"id": gid, "white": white, "black": black, "moves": [], "status": "started",
         "subs": [], "speed": speed, "wtime": clock[0], "btime": clock[0], "inc": clock[1],
         "winner": None, "bdraw": False, "wdraw": False}
    STATE["games"][gid] = g
    return g

def game_state(g):
    st = {"type": "gameState", "moves": " ".join(g["moves"]), "wtime": g["wtime"], "btime": g["btime"],
          "winc": g["inc"], "binc": g["inc"], "status": g["status"]}
    if g["winner"]: st["winner"] = g["winner"]
    if g["bdraw"]: st["bdraw"] = True
    return st

def push_game(g, obj):
    for q in list(g["subs"]):
        q.put(obj)

def push_event(obj):
    for q in list(STATE["events"]):
        q.put(obj)

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, fmt, *a):
        sys.stderr.write("mock: " + (fmt % a) + "\n")

    def auth(self):
        if self.headers.get("Authorization") != "Bearer " + TOKEN:
            self.send_json(401, {"error": "No such token"})
            return False
        return True

    def send_json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def stream(self, q, first=None, keepalive=1.0, close_when=None):
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        def chunk(data):
            self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data))
            self.wfile.flush()
        try:
            for obj in (first or []):
                chunk((json.dumps(obj) + "\n").encode())
            while True:
                try:
                    obj = q.get(timeout=keepalive)
                    if obj is None:
                        break
                    chunk((json.dumps(obj) + "\n").encode())
                except queue.Empty:
                    chunk(b"\n")
                if close_when and close_when():
                    break
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def read_body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode() if n else ""
        out = {}
        for part in raw.split("&"):
            if "=" in part:
                k, v = part.split("=", 1)
                out[k] = v
        return out

    def do_GET(self):
        if not self.auth(): return
        p = self.path
        if p == "/api/account":
            return self.send_json(200, {"id": "kindleuser", "username": "KindleUser",
                "perfs": {"blitz": {"rating": 1612}, "rapid": {"rating": 1688}, "classical": {"rating": 1720, "prov": True},
                          "correspondence": {"rating": 1500}}})
        if p.startswith("/api/account/playing"):
            items = []
            for g in STATE["games"].values():
                if g["status"] == "started":
                    items.append({"gameId": g["id"], "fullId": g["id"] + "abcd", "color": "white",
                                  "opponent": {"username": "Stockfish" if "ai" in g["black"] else g["black"].get("name"), "rating": 1500},
                                  "isMyTurn": len(g["moves"]) % 2 == 0, "speed": g["speed"], "rated": False, "secondsLeft": 512})
            items.append({"gameId": "corr0001", "fullId": "corr0001wxyz", "color": "black", "opponent": {"username": "PenPal", "rating": 1450},
                          "isMyTurn": False, "speed": "correspondence", "rated": True, "secondsLeft": 200000})
            return self.send_json(200, {"nowPlaying": items})
        if p == "/api/stream/event":
            q = queue.Queue()
            STATE["events"].append(q)
            # an incoming challenge shortly after connecting
            def later():
                time.sleep(0.6)
                q.put({"type": "challenge", "challenge": {"id": "chal1", "status": "created",
                       "challenger": {"id": "magnus", "name": "MagnusFan", "rating": 1777},
                       "destUser": {"id": "kindleuser", "name": "KindleUser"},
                       "variant": {"key": "standard"}, "rated": True,
                       "timeControl": {"type": "clock", "limit": 600, "increment": 5, "show": "10+5"}}})
            threading.Thread(target=later, daemon=True).start()
            try:
                self.stream(q)
            finally:
                STATE["events"].remove(q)
            return
        if p.startswith("/api/board/game/stream/"):
            gid = p.rsplit("/", 1)[1]
            g = STATE["games"].get(gid)
            if not g:
                return self.send_json(404, {"error": "Not found"})
            q = queue.Queue()
            g["subs"].append(q)
            full = {"type": "gameFull", "id": gid, "variant": {"key": "standard"}, "speed": g["speed"],
                    "rated": False, "white": g["white"], "black": g["black"], "initialFen": "startpos",
                    "clock": {"initial": 600000, "increment": 5000}, "state": game_state(g)}
            try:
                self.stream(q, first=[full], close_when=lambda: g["status"] != "started")
            finally:
                g["subs"].remove(q)
            return
        self.send_json(404, {"error": "Not found " + p})

    def do_POST(self):
        if not self.auth(): return
        p = self.path
        form = self.read_body()
        if p == "/api/challenge/ai":
            g = new_game("aigame01", {"id": "kindleuser", "name": "KindleUser", "rating": 1688},
                         {"aiLevel": int(form.get("level", 1))})
            push_event({"type": "gameStart", "game": {"gameId": g["id"], "fullId": g["id"] + "abcd", "color": "white"}})
            return self.send_json(201, {"id": g["id"], "speed": "rapid", "rated": False})
        if p == "/api/board/seek":
            # stream a few keepalives, then pair with a human
            def pair():
                time.sleep(1.5)
                g = new_game("seekgm01", {"id": "oppo", "name": "Opponent", "rating": 1701},
                             {"id": "kindleuser", "name": "KindleUser", "rating": 1688})
                push_event({"type": "gameStart", "game": {"gameId": g["id"], "fullId": g["id"] + "abcd", "color": "black"}})
                time.sleep(1.0)
                g["moves"].append("d2d4"); push_game(g, game_state(g))
            threading.Thread(target=pair, daemon=True).start()
            q = queue.Queue()
            threading.Timer(2.0, lambda: q.put(None)).start()
            return self.stream(q, keepalive=0.5)
        if p.startswith("/api/challenge/") and p.endswith("/accept"):
            return self.send_json(200, {"ok": True})
        if p.startswith("/api/challenge/") and p.endswith("/decline"):
            return self.send_json(200, {"ok": True})
        if p.startswith("/api/board/game/") and "/move/" in p:
            gid = p.split("/")[4]
            mv = p.rsplit("/", 1)[1].split("?")[0]
            g = STATE["games"].get(gid)
            if not g: return self.send_json(404, {"error": "Not found"})
            g["moves"].append(mv)
            g["wtime"] -= 3000
            push_game(g, game_state(g))
            if "ai" in json.dumps(g["black"]) or "aiLevel" in g["black"]:
                def reply():
                    time.sleep(0.8)
                    n = len(g["moves"]) // 2
                    if n < len(AI_REPLIES):
                        g["moves"].append(AI_REPLIES[n]); g["btime"] -= 1000
                        if len(g["moves"]) == 4:
                            g["bdraw"] = True
                        push_game(g, game_state(g))
                        g["bdraw"] = False
                threading.Thread(target=reply, daemon=True).start()
            return self.send_json(200, {"ok": True})
        if p.startswith("/api/board/game/") and p.endswith("/resign"):
            gid = p.split("/")[4]
            g = STATE["games"][gid]
            g["status"] = "resign"; g["winner"] = "black"
            push_game(g, game_state(g))
            return self.send_json(200, {"ok": True})
        if p.startswith("/api/board/game/") and "/draw/" in p:
            return self.send_json(200, {"ok": True})
        self.send_json(404, {"error": "Not found " + p})

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
