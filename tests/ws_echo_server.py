#!/usr/bin/env python3
"""Tiny WebSocket test server for tests/ws_test.lua (stdlib only).

usage: ws_echo_server.py PORT [CERT KEY]     (CERT/KEY -> serve wss)

Text messages are echoed, except these commands:
  frag:N      reply with an N-byte message split into 3 fragments, with a
              ping interleaved between fragments
  trickle:N   reply with an N-byte message written a few bytes at a time,
              then two small messages ("t1", "t2") in a single write
  ping:P      send a ping with payload P; once the pong arrives reply "pong:P"
  close       send a close frame (1000 "bye") and wait for the client's echo
  stats       reply "unmasked:<count of client frames that were not masked>"
Paths: /bad-accept answers 101 with a wrong Sec-WebSocket-Accept;
       /plain answers 200 (no upgrade).
"""
import ssl
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import wsproto


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("ws_echo: " + (fmt % args) + "\n")

    def do_GET(self):
        if self.path == "/plain" or not wsproto.is_upgrade(self):
            body = b"not a websocket"
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path == "/bad-accept":
            wsproto.upgrade(self, accept_override="AAAAAAAAAAAAAAAAAAAAAAAAAAA=")
            time.sleep(0.2)
            return
        ws = wsproto.upgrade(self)
        try:
            self.loop(ws)
        except wsproto.Closed:
            pass
        except (ConnectionError, OSError) as e:
            sys.stderr.write("ws_echo: conn error %r\n" % e)

    def loop(self, ws):
        parts, waiting_pong = [], None
        while True:
            fin, op, payload = ws.read_frame()
            if op == 0x8:
                sys.stderr.write("ws_echo: client close %r\n" % payload)
                ws.send_frame(0x8, payload[:2])
                return
            if op == 0x9:
                ws.send_frame(0xA, payload)
                continue
            if op == 0xA:
                if waiting_pong is not None and payload.decode() == waiting_pong:
                    ws.send_text("pong:" + waiting_pong)
                    waiting_pong = None
                continue
            if op in (1, 2):
                parts = [payload]
            else:
                parts.append(payload)
            if not fin:
                continue
            msg = b"".join(parts).decode()
            if msg.startswith("frag:"):
                n = int(msg[5:])
                data = ("0123456789" * (n // 10 + 1))[:n].encode()
                a, b = n // 3, 2 * n // 3
                ws.send_frame(0x1, data[:a], fin=False)
                ws.send_frame(0x9, b"mid")
                ws.send_frame(0x0, data[a:b], fin=False)
                ws.send_frame(0x0, data[b:], fin=True)
            elif msg.startswith("trickle:"):
                n = int(msg[8:])
                data = ("abcdefghij" * (n // 10 + 1))[:n].encode()
                if n < 126:
                    head = bytes([0x81, n])
                elif n < 65536:
                    head = bytes([0x81, 126]) + struct.pack(">H", n)
                else:
                    head = bytes([0x81, 127]) + struct.pack(">Q", n)
                frame = head + data
                step = 7 if n < 1000 else 4093
                for i in range(0, len(frame), step):
                    ws.send_raw(frame[i:i + step])
                    time.sleep(0.003)
                ws.send_raw(bytes([0x81, 2]) + b"t1" + bytes([0x81, 2]) + b"t2")
            elif msg.startswith("ping:"):
                waiting_pong = msg[5:]
                ws.send_frame(0x9, waiting_pong)
            elif msg == "close":
                ws.send_close(1000, "bye")
                # wait for the client's close echo
                while True:
                    fin, op, payload = ws.read_frame()
                    if op == 0x8:
                        sys.stderr.write("ws_echo: client echoed close %r\n" % payload)
                        return
            elif msg == "stats":
                ws.send_text("unmasked:%d" % ws.unmasked_frames)
            else:
                ws.send_text(msg)


def main():
    port = int(sys.argv[1])
    srv = ThreadingHTTPServer(("127.0.0.1", port), H)
    srv.daemon_threads = True
    if len(sys.argv) >= 4:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(sys.argv[2], sys.argv[3])
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
    sys.stderr.write("ws_echo listening on %d\n" % port)
    srv.serve_forever()


if __name__ == "__main__":
    main()
