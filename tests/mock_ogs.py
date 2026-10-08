#!/usr/bin/env python3
"""Fake online-go.com for tests (stdlib only): REST + realtime WebSocket on
ONE port.

usage: python3 tests/mock_ogs.py [PORT]        (default 8722)
  OGS_BASE=http://127.0.0.1:PORT  OGS_WS=ws://127.0.0.1:PORT/
or, for the whole simulator: EINK_NET_REDIRECT=http://127.0.0.1:PORT
(the "/online-go.com" path prefix that the redirect adds is stripped).

Accounts: client_id "test-client" (any/no secret), username "kindle",
password "hunter2" -> access token "ogs_test_token", refresh token
"ogs_refresh_token". The user is id 501.

Games:
  1001  9x9 correspondence, me = black, my turn. After each client move the
        opponent ("opponent", id 777) replies ~0.5 s later. If the client
        passes twice in a row (pass, opponent plays, pass) the opponent
        passes too -> phase "stone removal"; ~0.3 s later the opponent marks
        a white group dead (removed_stones). When the client accepts the same
        stones -> removed_stones_accepted + phase "finished" + gamedata.
        game/removed_stones/reject -> back to "play".
  1002  19x19 live (fischer 10m+30s), me = white, opponent's turn. Moving
        there out of turn gets a game/1002/error.
Challenges: one incoming (id 3001 from "challenger", 13x13 unranked);
accepting it creates game 1003. Outgoing challenges go to players
"friend" (888) / "opponent" (777) / "rival" (778).
Bots: after authenticate the socket gets "active-bots" with five bots:
  kata-bot (1201, v2 config, plays anything), gnugo-9x9 (1202, v1 config:
  9x9 unranked live only), refuser (1203, declines every challenge with a
  gameOfferRejected notification), legacy-bot (1204, no config) and
  sleepy-bot (1205, never answers, for cancel/timeout).
  A bot challenge starts its game on the first challenge/keepalive: the
  client is black and the bot (white) answers each move ~0.5 s later.

Test hooks (no auth):
  GET  /_mock/state                 games, ws command log, last challenge
  POST /_mock/opponent_move/<gid>   opponent plays its next scripted move
  POST /_mock/drop                  abruptly close every websocket
  POST /_mock/expire                invalidate access tokens (forces refresh)
  POST /_mock/reset                 restore the initial state
Every websocket command received is logged to stderr ("ws< ...").
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import wsproto

LOCK = threading.RLock()

ME = {"id": 501, "username": "kindle", "ranking": 23.4, "professional": False}
OPP = {"id": 777, "username": "opponent", "ranking": 26.2, "professional": False}
RIVAL = {"id": 778, "username": "rival", "ranking": 31.5, "professional": False}
FRIEND = {"id": 888, "username": "friend", "ranking": 20.0, "professional": False}
CHALLENGER = {"id": 999, "username": "challenger", "ranking": 28.0, "professional": False}
PLAYERS = [OPP, RIVAL, FRIEND, CHALLENGER, ME]


def bot_v2(bid, name, ranking, sizes="all"):
    clock = {"fischer": {"initial_time_range": [30, 3600], "max_time_range": [30, 7200],
                         "time_increment_range": [1, 300]}}
    return {"id": bid, "username": name, "ranking": ranking, "ui_class": "bot", "config": {
        "_config_version": 2, "hidden": False, "bot_id": bid, "username": name,
        "allowed_time_control_systems": ["fischer", "byoyomi"], "allowed_board_sizes": sizes,
        "allowed_blitz_settings": clock, "allowed_rapid_settings": clock, "allowed_live_settings": clock,
        "allowed_correspondence_settings": {"fischer": {"initial_time_range": [86400, 1209600],
                                                        "max_time_range": [86400, 1209600],
                                                        "time_increment_range": [3600, 604800]}},
        "allow_ranked": True, "allow_unranked": True, "allowed_rank_range": ["30k", "9d"],
        "allow_ranked_handicap": False, "allow_unranked_handicap": True,
        "allowed_komi_range": [-15, 15], "decline_new_challenges": False,
        "min_move_time": 0, "max_games_per_player": 3}}


BOTS = {
    1201: bot_v2(1201, "kata-bot", 38.0),
    1202: {"id": 1202, "username": "gnugo-9x9", "ranking": 20.0, "ui_class": "bot", "config": {
        "_config_version": 1, "hidden": False, "bot_id": 1202, "username": "gnugo-9x9",
        "allowed_time_control_systems": ["fischer"], "allowed_board_sizes": [9],
        "allowed_live_settings": {"fischer": {"max_time_range": [60, 3600], "time_increment_range": [0, 60]}},
        "allow_ranked": False, "allow_unranked": True, "allowed_rank_range": ["30k", "9d"],
        "allow_ranked_handicap": False, "allow_unranked_handicap": False, "allowed_komi_range": [-15, 15],
        "decline_new_challenges": False, "min_move_time": 0, "max_games_per_player": 1}},
    1203: bot_v2(1203, "refuser", 25.0),
    1204: {"id": 1204, "username": "legacy-bot", "ranking": 15.0, "ui_class": "bot",
           "config": {"_config_version": 0}},
    1205: bot_v2(1205, "sleepy-bot", 30.0),
}
BOT_SCRIPT = [(6, 2), (2, 6), (6, 6), (2, 2), (4, 6), (6, 4), (4, 2), (2, 4)]
JWT = "jwt-kindle-501"

OPP_SCRIPT = {
    1001: [(4, 4), (5, 5), (3, 5), (5, 3), (6, 4), (4, 6), (1, 1), (7, 7), (1, 7), (7, 1), (0, 4), (8, 4)],
    1002: [(16, 3), (3, 16), (16, 16), (9, 9), (2, 9), (16, 9)],
    1003: [(3, 3), (9, 9), (3, 9), (9, 3)],
}


def now_ms():
    return int(time.time() * 1000)


def log(*a):
    sys.stderr.write(" ".join(str(x) for x in a) + "\n")
    sys.stderr.flush()


def sgf(x, y):
    return chr(97 + x) + chr(97 + y)


def pairs(s):
    return {s[i:i + 2] for i in range(0, len(s or "") - 1, 2)}


def pts_string(st):
    return "".join(sorted(st, key=lambda p: (ord(p[1]), ord(p[0]))))


class Game:
    def __init__(self, gid, name, size, black, white, speed, moves, tc):
        self.id = gid
        self.name = name
        self.w = self.h = size
        self.black, self.white = black, white
        self.speed = speed
        self.moves = [list(m) for m in moves]
        self.phase = "play"
        self.removed = set()
        self.tc = tc
        t = now_ms()
        base = tc["initial_time"]
        self.times = {"black": base - 60, "white": base - 20}
        self.last_move = t - (3600_000 if speed == "correspondence" else 5000)
        self.client_passed = False
        self.winner = None
        self.outcome = ""
        self.score = None
        self.end_time = None
        self.script = list(OPP_SCRIPT.get(gid, BOT_SCRIPT if white["id"] in BOTS else []))

    # -- derived state ------------------------------------------------------------
    def to_move(self):
        return "black" if len(self.moves) % 2 == 0 else "white"

    def player(self, color):
        return self.black if color == "black" else self.white

    def color_of(self, pid):
        if pid == self.black["id"]:
            return "black"
        if pid == self.white["id"]:
            return "white"
        return None

    def occupied(self):
        return {(m[0], m[1]) for m in self.moves if m[0] >= 0}

    def stones_of(self, color):
        out = set()
        for i, m in enumerate(self.moves):
            if m[0] >= 0 and (i % 2 == 0) == (color == "black"):
                out.add((m[0], m[1]))
        return out

    def clock(self):
        cur = self.to_move()
        t = self.times[cur]
        return {
            "game_id": self.id,
            "current_player": self.player(cur)["id"],
            "black_player_id": self.black["id"],
            "white_player_id": self.white["id"],
            "title": self.name,
            "last_move": self.last_move,
            "expiration": self.last_move + int(t * 1000),
            "now": now_ms(),
            "paused_since": None,
            "black_time": {"thinking_time": self.times["black"], "skip_bonus": False},
            "white_time": {"thinking_time": self.times["white"], "skip_bonus": False},
        }

    def gamedata(self):
        def p(u):
            return {"id": u["id"], "username": u["username"], "rank": u["ranking"],
                    "professional": False, "accepted_stones": None}
        gd = {
            "game_id": self.id, "game_name": self.name,
            "width": self.w, "height": self.h, "phase": self.phase,
            "moves": self.moves,
            "initial_state": {"black": "", "white": ""},
            "initial_player": "black",
            "handicap": 0, "free_handicap_placement": False,
            "komi": 6.5, "rules": "japanese",
            "players": {"black": p(self.black), "white": p(self.white)},
            "black_player_id": self.black["id"], "white_player_id": self.white["id"],
            "player_id": self.player(self.to_move())["id"],
            "clock": self.clock(),
            "removed": pts_string(self.removed),
            "time_control": self.tc,
            "ranked": False, "disable_analysis": False, "pause_on_weekends": self.speed == "correspondence",
        }
        if self.phase == "finished":
            gd.update({"winner": self.winner, "outcome": self.outcome, "score": self.score,
                       "end_time": self.end_time})
        return gd

    def overview_entry(self):
        return {
            "id": self.id, "name": self.name, "width": self.w, "height": self.h,
            "black": dict(self.black), "white": dict(self.white),
            "rengo": False, "ranked": False,
            "json": self.gamedata(),
        }

    # -- mutations ----------------------------------------------------------------
    def play(self, x, y):
        color = self.to_move()
        t = now_ms()
        elapsed = t - self.last_move
        tt = self.times[color] - elapsed / 1000.0 + self.tc.get("time_increment", 0)
        self.times[color] = round(min(tt, self.tc.get("max_time", tt)), 3)
        self.last_move = t
        mv = [x, y, elapsed]
        self.moves.append(mv)
        return mv


def tc_of(speed, initial, inc, max_time):
    return {"system": "fischer", "time_control": "fischer", "speed": speed,
            "initial_time": initial, "time_increment": inc, "max_time": max_time,
            "pause_on_weekends": speed == "correspondence"}


class State:
    def __init__(self):
        self.reset()

    def reset(self):
        self.tokens = {"ogs_test_token"}
        self.refresh_tokens = {"ogs_refresh_token"}
        self.games = {
            1001: Game(1001, "Kindle test 9x9", 9, ME, OPP, "correspondence",
                       [(2, 2, 1000), (6, 6, 1000), (2, 6, 1000), (6, 2, 1000)],
                       tc_of("correspondence", 259200, 86400, 259200)),
            1002: Game(1002, "Live 19x19", 19, OPP, ME, "live",
                       [(3, 3, 3000), (15, 15, 4000), (15, 3, 3000), (3, 15, 2000)],
                       tc_of("live", 600, 30, 1200)),
        }
        self.challenges = [{
            "id": 3001,
            "challenger": dict(CHALLENGER), "challenged": dict(ME),
            "challenger_color": "black", "min_ranking": -1000, "max_ranking": 1000,
            "created": "2026-10-01T12:00:00Z",
            "game": {"id": 1003, "name": "Friendly match", "width": 13, "height": 13,
                     "ranked": False, "handicap": 0, "rules": "japanese", "komi": None,
                     "time_control": "fischer",
                     # OGS sends this as a JSON *string*
                     "time_control_parameters": json.dumps(tc_of("live", 1200, 30, 2400))},
        }]
        self.next_challenge = 5001
        self.next_game = 2001
        self.last_challenge = None
        self.ws_log = []
        self.bot_pending = {}    # game id -> {"challenge", "bot", "game"} until the bot answers
        self.bot_games = set()


S = State()
CONNS = set()            # live WSConn
SUBS = {}                # game_id -> set(WSConn)


def send(conn, msg):
    try:
        conn.send_text(json.dumps(msg))
    except Exception as e:  # noqa: BLE001
        log("send failed:", e)


def broadcast(gid, event, data):
    for c in list(SUBS.get(gid, ())):
        send(c, ["game/%d/%s" % (gid, event), data])


def later(sec, fn):
    t = threading.Timer(sec, fn)
    t.daemon = True
    t.start()


# -- game flow --------------------------------------------------------------------------
def opponent_move(gid, force_pass=False):
    with LOCK:
        g = S.games.get(gid)
        if not g or g.phase != "play":
            return
        if g.player(g.to_move())["id"] == ME["id"]:
            return
        if force_pass:
            x, y = -1, -1
        else:
            occ = g.occupied()
            while g.script and g.script[0] in occ:
                g.script.pop(0)
            if g.script:
                x, y = g.script.pop(0)
            else:
                x, y = -1, -1
        mv = g.play(x, y)
        log("opponent plays", gid, x, y)
        broadcast(gid, "move", {"game_id": gid, "move_number": len(g.moves), "move": mv})
        broadcast(gid, "clock", g.clock())
        if force_pass:
            enter_removal(g)


def group_of(g, start, color):
    stones = g.stones_of(color)
    seen, todo = set(), [start]
    while todo:
        p = todo.pop()
        if p in seen or p not in stones:
            continue
        seen.add(p)
        x, y = p
        todo += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    return seen


def enter_removal(g):
    g.phase = "stone removal"
    g.removed = set()
    broadcast(g.id, "phase", "stone removal")
    broadcast(g.id, "gamedata", g.gamedata())

    def mark():
        with LOCK:
            if g.phase != "stone removal":
                return
            whites = [(m[0], m[1]) for i, m in enumerate(g.moves) if i % 2 == 1 and m[0] >= 0]
            if not whites:
                return
            grp = group_of(g, whites[-1], "white")
            st = {sgf(x, y) for x, y in grp}
            g.removed |= st
            log("opponent marks dead", pts_string(st))
            broadcast(g.id, "removed_stones", {"removed": True, "stones": pts_string(st),
                                               "all_removed": pts_string(g.removed)})
    later(0.3, mark)


def finish(g, winner, outcome, score=None):
    g.phase = "finished"
    g.winner = winner
    g.outcome = outcome
    g.score = score
    g.end_time = int(time.time())


def handle_ws(conn, msg, sess):
    if not isinstance(msg, list) or not msg or not isinstance(msg[0], str):
        log("ws< bad message", msg)
        return
    cmd = msg[0]
    data = msg[1] if len(msg) > 1 else None
    rid = msg[2] if len(msg) > 2 else None
    log("ws<", json.dumps(msg))
    with LOCK:
        S.ws_log.append(msg)
    reply = {}

    def err(gid, text):
        send(conn, ["game/%s/error" % gid, text])

    with LOCK:
        if cmd == "authenticate":
            if isinstance(data, dict) and data.get("jwt") == JWT:
                sess["user"] = ME["id"]
                if not data.get("device_id"):
                    log("WARNING: authenticate without device_id")
                send(conn, ["active-bots", {str(b): v for b, v in BOTS.items()}])
            else:
                log("authenticate: bad jwt", data)
                reply = None
        elif cmd == "net/ping":
            send(conn, ["net/pong", {"client": (data or {}).get("client"), "server": now_ms()}])
        elif cmd == "challenge/keepalive":
            gid = int((data or {}).get("game_id", 0))
            pend = S.bot_pending.pop(gid, None)
            if pend and pend["bot"]["username"] == "sleepy-bot":
                S.bot_pending[gid] = pend
            elif pend and pend["challenge"] == (data or {}).get("challenge_id"):
                S.challenges = [c for c in S.challenges if c["id"] != pend["challenge"]]
                bot = pend["bot"]
                if bot["username"] == "refuser":
                    send(conn, ["notification", {"id": "n-%d" % gid, "type": "gameOfferRejected",
                                                 "game_id": gid, "message": "I'm only practising today."}])
                else:
                    gm = pend["game"]
                    tcp = gm["time_control_parameters"]
                    S.games[gid] = Game(gid, gm["name"], gm["width"], ME, bot, tcp["speed"], [], tcp)
                    S.bot_games.add(gid)
                    log("bot", bot["username"], "accepted; game", gid)
                    broadcast(gid, "gamedata", S.games[gid].gamedata())
                    broadcast(gid, "clock", S.games[gid].clock())
            elif pend:
                S.bot_pending[gid] = pend
        elif cmd == "game/connect" and int(data["game_id"]) in S.bot_pending:
            SUBS.setdefault(int(data["game_id"]), set()).add(conn)   # game starts when the bot accepts
        elif cmd == "game/connect":
            gid = int(data["game_id"])
            g = S.games.get(gid)
            if not g:
                err(gid, "Game not found")
            else:
                SUBS.setdefault(gid, set()).add(conn)
                send(conn, ["game/%d/gamedata" % gid, g.gamedata()])
                send(conn, ["game/%d/clock" % gid, g.clock()])
        elif cmd == "game/disconnect":
            SUBS.get(int(data["game_id"]), set()).discard(conn)
        elif cmd.startswith("game/"):
            gid = int((data or {}).get("game_id", 0))
            g = S.games.get(gid)
            if not g:
                err(gid, "Game not found")
            elif not sess.get("user"):
                err(gid, "Not authenticated")
            elif cmd == "game/move":
                if g.phase != "play":
                    err(gid, "Game is not in play phase")
                elif g.player(g.to_move())["id"] != sess["user"]:
                    err(gid, "Move out of turn")
                else:
                    mvs = data.get("move", "")
                    if mvs in ("..", ""):
                        x, y = -1, -1
                    else:
                        x, y = ord(mvs[0]) - 97, ord(mvs[1]) - 97
                    if x >= 0 and (not (0 <= x < g.w and 0 <= y < g.h) or (x, y) in g.occupied()):
                        err(gid, "Illegal move")
                    else:
                        second_pass = x < 0 and g.client_passed
                        g.client_passed = x < 0
                        mv = g.play(x, y)
                        broadcast(gid, "move", {"game_id": gid, "move_number": len(g.moves), "move": mv})
                        broadcast(gid, "clock", g.clock())
                        if (gid in OPP_SCRIPT and gid != 1002) or gid in S.bot_games:
                            later(0.5, lambda: opponent_move(gid, force_pass=second_pass))
            elif cmd == "game/resign":
                if g.phase == "finished":
                    err(gid, "Game already finished")
                else:
                    me_color = g.color_of(sess["user"])
                    other = g.white if me_color == "black" else g.black
                    finish(g, other["id"], "Resignation")
                    broadcast(gid, "phase", "finished")
                    broadcast(gid, "gamedata", g.gamedata())
            elif cmd == "game/removed_stones/set":
                if g.phase != "stone removal":
                    err(gid, "Not in stone removal phase")
                else:
                    st = pairs(data.get("stones", ""))
                    if data.get("removed"):
                        g.removed |= st
                    else:
                        g.removed -= st
                    broadcast(gid, "removed_stones", {"removed": bool(data.get("removed")),
                                                      "stones": pts_string(st),
                                                      "all_removed": pts_string(g.removed)})
            elif cmd == "game/removed_stones/accept":
                if g.phase != "stone removal":
                    err(gid, "Not in stone removal phase")
                elif pairs(data.get("stones", "")) != g.removed:
                    log("accept mismatch: client", data.get("stones"), "server", pts_string(g.removed))
                    err(gid, "Removed stones do not match")
                else:
                    stones = pts_string(g.removed)
                    score = {
                        "black": {"total": 41, "stones": 0, "territory": 38, "prisoners": 3,
                                  "scoring_positions": "", "handicap": 0, "komi": 0},
                        "white": {"total": 33.5, "stones": 0, "territory": 27, "prisoners": 0,
                                  "scoring_positions": "", "handicap": 0, "komi": 6.5},
                    }
                    finish(g, g.black["id"], "7.5 points", score)
                    broadcast(gid, "removed_stones_accepted", {
                        "player_id": sess["user"], "stones": stones,
                        "players": {"black": {"id": g.black["id"], "accepted_stones": stones},
                                    "white": {"id": g.white["id"], "accepted_stones": stones}},
                        "phase": "finished", "score": score, "winner": g.winner,
                        "outcome": g.outcome, "end_time": g.end_time,
                    })
                    broadcast(gid, "phase", "finished")
                    broadcast(gid, "gamedata", g.gamedata())
            elif cmd == "game/removed_stones/reject":
                if g.phase != "stone removal":
                    err(gid, "Not in stone removal phase")
                else:
                    g.phase = "play"
                    g.removed = set()
                    g.client_passed = False
                    broadcast(gid, "phase", "play")
                    broadcast(gid, "gamedata", g.gamedata())
            else:
                log("unhandled game command", cmd)
        else:
            log("ignored command", cmd)
    if rid is not None and reply is not None:
        send(conn, [rid, reply])


# -- HTTP ---------------------------------------------------------------------------------
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        log("http:", fmt % args)

    # helpers
    def reply(self, status, obj=None, raw=None):
        body = raw if raw is not None else (b"" if obj is None else json.dumps(obj).encode())
        self.send_response(status)
        if obj is not None or raw is not None:
            self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def route(self):
        u = urlparse(self.path)
        path = u.path
        if path.startswith("/online-go.com"):
            path = path[len("/online-go.com"):] or "/"
        if len(path) > 1:
            path = path.rstrip("/")
        return path, parse_qs(u.query)

    def authed(self):
        a = self.headers.get("Authorization") or ""
        if a.startswith("Bearer ") and a[7:] in S.tokens:
            return True
        self.reply(401, {"detail": "Authentication credentials were not provided."})
        return False

    # verbs
    def do_GET(self):
        path, q = self.route()
        if wsproto.is_upgrade(self):
            return self.websocket()
        with LOCK:
            if path == "/_mock/state":
                return self.reply(200, {
                    "games": {gid: {"phase": g.phase, "moves": g.moves, "removed": pts_string(g.removed),
                                    "outcome": g.outcome} for gid, g in S.games.items()},
                    "ws_log": S.ws_log, "last_challenge": S.last_challenge,
                    "challenges": [c["id"] for c in S.challenges],
                })
            if not path.startswith("/api/"):
                return self.reply(404, {"detail": "Not found."})
            if not self.authed():
                return
            if path == "/api/v1/me":
                return self.reply(200, dict(ME, about="mock", country="un"))
            if path == "/api/v1/ui/config":
                return self.reply(200, {"user_jwt": JWT, "user": dict(ME), "csrf_token": "x"})
            if path == "/api/v1/ui/overview":
                active = [g.overview_entry() for g in S.games.values() if g.phase != "finished"]
                return self.reply(200, {"active_games": active, "challenges": S.challenges})
            if path.startswith("/api/v1/games/"):
                try:
                    gid = int(path.split("/")[4])
                except ValueError:
                    return self.reply(404, {"detail": "Not found."})
                g = S.games.get(gid)
                if not g:
                    return self.reply(404, {"detail": "Not found."})
                return self.reply(200, {"id": gid, "name": g.name, "width": g.w, "height": g.h,
                                        "players": {"black": g.black, "white": g.white},
                                        "gamedata": g.gamedata()})
            if path == "/api/v1/me/challenges":
                return self.reply(200, {"count": len(S.challenges), "next": None, "previous": None,
                                        "results": S.challenges})
            if path == "/api/v1/players":
                name = (q.get("username") or [""])[0].lower()
                res = [p for p in PLAYERS if p["username"].lower() == name]
                return self.reply(200, {"count": len(res), "next": None, "previous": None, "results": res})
        self.reply(404, {"detail": "Not found."})

    def do_DELETE(self):
        path, _ = self.route()
        with LOCK:
            if not self.authed():
                return
            if path.startswith("/api/v1/me/challenges/"):
                cid = int(path.split("/")[5])
                before = len(S.challenges)
                S.challenges = [c for c in S.challenges if c["id"] != cid]
                for gid, pend in list(S.bot_pending.items()):
                    if pend["challenge"] == cid:
                        del S.bot_pending[gid]
                if len(S.challenges) == before:
                    return self.reply(404, {"detail": "Not found."})
                return self.reply(204)
        self.reply(404, {"detail": "Not found."})

    def do_POST(self):
        path, _ = self.route()
        raw = self.body()
        ctype = (self.headers.get("Content-Type") or "").lower()
        with LOCK:
            if path == "/_mock/reset":
                S.reset()
                return self.reply(200, {"ok": True})
            if path == "/_mock/expire":
                S.tokens = set()
                return self.reply(200, {"ok": True})
            if path == "/_mock/drop":
                n = 0
                for c in list(CONNS):
                    try:
                        c.sock.shutdown(2)
                    except OSError:
                        pass
                    n += 1
                return self.reply(200, {"dropped": n})
            if path.startswith("/_mock/opponent_move/"):
                gid = int(path.rsplit("/", 1)[1])
                later(0.05, lambda: opponent_move(gid))
                return self.reply(200, {"ok": True})
            if path == "/oauth2/token":
                return self.token(raw, ctype)
            if not self.authed():
                return
            if path.startswith("/api/v1/me/challenges/") and path.endswith("/accept"):
                if "application/json" not in ctype:
                    return self.reply(415, {"detail": "Unsupported media type \"%s\" in request." % ctype})
                cid = int(path.split("/")[5])
                ch = next((c for c in S.challenges if c["id"] == cid), None)
                if not ch:
                    return self.reply(404, {"detail": "Not found."})
                S.challenges.remove(ch)
                gm = ch["game"]
                tcp = json.loads(gm["time_control_parameters"])
                black, white = (ch["challenger"], ME) if ch["challenger_color"] == "black" else (ME, ch["challenger"])
                gid = gm.get("id") or self.new_game_id()
                S.games[gid] = Game(gid, gm["name"], gm["width"], black, white, tcp["speed"], [], tcp)
                if black["id"] != ME["id"]:
                    later(0.5, lambda: opponent_move(gid))
                return self.reply(200, {"game": gid, "challenge": cid, "status": "ok"})
            if path.startswith("/api/v1/players/") and path.endswith("/challenge"):
                if "application/json" not in ctype:
                    return self.reply(415, {"detail": "Unsupported media type \"%s\" in request." % ctype})
                pid = int(path.split("/")[4])
                target = next((p for p in PLAYERS if p["id"] == pid), None) or BOTS.get(pid)
                if not target:
                    return self.reply(404, {"detail": "Not found."})
                try:
                    body = json.loads(raw)
                    game = body["game"]
                    tcp = game["time_control_parameters"]
                    assert game["width"] in (9, 13, 19) and game["height"] == game["width"]
                    assert body["challenger_color"] in ("automatic", "black", "white")
                    assert tcp["speed"] in ("live", "correspondence", "blitz", "rapid")
                    assert tcp["system"] == "fischer" and tcp["initial_time"] > 0
                except (ValueError, KeyError, TypeError, AssertionError) as e:
                    return self.reply(400, {"error": "Invalid challenge: %r" % (e,)})
                cid = S.next_challenge
                S.next_challenge += 1
                gid = self.new_game_id()
                S.last_challenge = {"player_id": pid, "body": body, "challenge": cid}
                if pid in BOTS:
                    S.bot_pending[gid] = {"challenge": cid, "bot": {k: target[k] for k in ("id", "username", "ranking")},
                                          "game": game}
                S.challenges.append({
                    "id": cid, "challenger": dict(ME), "challenged": {k: target[k] for k in ("id", "username", "ranking")},
                    "challenger_color": body["challenger_color"],
                    "game": dict(game, id=gid, time_control_parameters=json.dumps(tcp)),
                })
                return self.reply(200, {"status": "ok", "challenge": cid, "game": gid})
        self.reply(404, {"detail": "Not found."})

    def new_game_id(self):
        gid = S.next_game
        S.next_game += 1
        return gid

    def token(self, raw, ctype):
        if "application/x-www-form-urlencoded" not in ctype:
            return self.reply(400, {"error": "invalid_request", "error_description": "form encoding required"})
        f = {k: v[0] for k, v in parse_qs(raw.decode()).items()}
        if f.get("client_id") != "test-client":
            return self.reply(401, {"error": "invalid_client"})
        gt = f.get("grant_type")
        if gt == "password":
            if f.get("username") != "kindle" or f.get("password") != "hunter2":
                return self.reply(400, {"error": "invalid_grant", "error_description": "Invalid credentials given."})
        elif gt == "refresh_token":
            if f.get("refresh_token") not in S.refresh_tokens:
                return self.reply(400, {"error": "invalid_grant"})
        else:
            return self.reply(400, {"error": "unsupported_grant_type"})
        S.tokens.add("ogs_test_token")
        log("token issued via", gt)
        return self.reply(200, {"access_token": "ogs_test_token", "refresh_token": "ogs_refresh_token",
                                "expires_in": 2592000, "token_type": "Bearer", "scope": "read write"})

    def websocket(self):
        conn = wsproto.upgrade(self)
        log("ws connected from", self.client_address)
        sess = {}
        with LOCK:
            CONNS.add(conn)
        try:
            while True:
                text = conn.recv()
                if isinstance(text, bytes):
                    continue
                try:
                    msg = json.loads(text)
                except ValueError:
                    log("ws< unparseable", text[:200])
                    continue
                handle_ws(conn, msg, sess)
        except (wsproto.Closed, ConnectionError, OSError, ValueError) as e:
            log("ws closed", type(e).__name__)
        finally:
            with LOCK:
                CONNS.discard(conn)
                for s in SUBS.values():
                    s.discard(conn)
                conn.closed = True


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8722
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    log("mock_ogs listening on %d" % port)
    srv.serve_forever()


if __name__ == "__main__":
    main()
