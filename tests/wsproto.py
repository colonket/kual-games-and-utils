"""Minimal RFC 6455 server-side helpers (stdlib only) for the test mocks.

Used by tests/ws_echo_server.py and tests/mock_ogs.py. Plug into an
http.server.BaseHTTPRequestHandler: call `upgrade(handler)` from do_GET when
the request has `Upgrade: websocket`, then use the returned WSConn.
"""
import base64
import hashlib
import struct
import threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def accept_for(key):
    return base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()


def is_upgrade(handler):
    return "websocket" in (handler.headers.get("Upgrade") or "").lower()


class Closed(Exception):
    pass


class WSConn:
    def __init__(self, rfile, sock):
        self.rfile = rfile
        self.sock = sock
        self.lock = threading.Lock()
        self.closed = False
        self.unmasked_frames = 0   # client frames that violated the masking rule
        self.pongs = []

    # -- writing -------------------------------------------------------------------
    def send_frame(self, opcode, payload=b"", fin=True):
        if isinstance(payload, str):
            payload = payload.encode()
        n = len(payload)
        head = bytes([(0x80 if fin else 0) | opcode])
        if n < 126:
            head += bytes([n])
        elif n < 65536:
            head += bytes([126]) + struct.pack(">H", n)
        else:
            head += bytes([127]) + struct.pack(">Q", n)
        with self.lock:
            if self.closed:
                raise Closed()
            self.sock.sendall(head + payload)

    def send_raw(self, data):
        with self.lock:
            self.sock.sendall(data)

    def send_text(self, text):
        self.send_frame(0x1, text)

    def send_close(self, code=1000, reason=""):
        self.send_frame(0x8, struct.pack(">H", code) + reason.encode())

    # -- reading -------------------------------------------------------------------
    def _read(self, n):
        data = b""
        while len(data) < n:
            chunk = self.rfile.read(n - len(data))
            if not chunk:
                raise Closed()
            data += chunk
        return data

    def read_frame(self):
        b1, b2 = self._read(2)
        fin = bool(b1 & 0x80)
        op = b1 & 0x0F
        masked = bool(b2 & 0x80)
        n = b2 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._read(8))[0]
        mask = self._read(4) if masked else None
        payload = self._read(n)
        if mask:
            payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        else:
            self.unmasked_frames += 1
        return fin, op, payload

    def recv(self):
        """Next complete text/binary message as str/bytes. Handles control
        frames: ping -> pong, pong recorded, close -> echo + raise Closed."""
        parts, mop = [], None
        while True:
            fin, op, payload = self.read_frame()
            if op == 0x8:
                try:
                    self.send_frame(0x8, payload[:2])
                except Exception:
                    pass
                self.closed = True
                raise Closed()
            if op == 0x9:
                self.send_frame(0xA, payload)
                continue
            if op == 0xA:
                self.pongs.append(payload)
                continue
            if op in (0x1, 0x2):
                parts, mop = [payload], op
            elif op == 0x0:
                parts.append(payload)
            if fin:
                data = b"".join(parts)
                return data.decode() if mop == 0x1 else data


def upgrade(handler, accept_override=None):
    """Complete the handshake on a BaseHTTPRequestHandler; returns WSConn."""
    key = handler.headers.get("Sec-WebSocket-Key", "")
    handler.close_connection = True
    lines = [
        "HTTP/1.1 101 Switching Protocols",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Accept: " + (accept_override or accept_for(key)),
    ]
    handler.wfile.write(("\r\n".join(lines) + "\r\n\r\n").encode())
    handler.wfile.flush()
    return WSConn(handler.rfile, handler.connection)
