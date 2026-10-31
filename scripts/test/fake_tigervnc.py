#!/usr/bin/env python3
"""Fake TigerVNC-style server for Circe's Linux/cloud path.

Exercises: VeNCrypt (Plain or VncAuth subtype), Tight (fill, JPEG, copy/palette/gradient filters,
all four zlib streams, small uncompressed payloads), LastRect, ExtendedDesktopSize (incl. client
resize requests) and the UTF-8 Extended Clipboard. Prints `--expect` args for `circe-cli vnc` on stdout.

usage: fake_tigervnc.py PORT [plain|vncauth] JPEG_PATH
"""
import socket, struct, sys, threading, zlib

PORT = int(sys.argv[1])
AUTH = sys.argv[2] if len(sys.argv) > 2 else "plain"
JPEG = open(sys.argv[3], "rb").read()  # solid blue 32x32
W, H = 240, 160
CLIP_TEXT = "Grüße from Linux ✓"

def rect(x, y, w, h, enc): return struct.pack(">HHHHi", x, y, w, h, enc)
def rgb(c): return bytes([(c >> 16) & 255, (c >> 8) & 255, c & 255])
def compact(n):
    out = bytearray([n & 0x7F])
    if n > 0x7F:
        out[0] |= 0x80; out.append((n >> 7) & 0x7F)
        if n > 0x3FFF: out[1] |= 0x80; out.append((n >> 14) & 0xFF)
    return bytes(out)

expect = []
streams = [zlib.compressobj() for _ in range(4)]

def tight_basic(stream, filt, payload, explicit=True):
    ctl = (stream | (0x4 if explicit else 0)) << 4
    out = bytearray([ctl])
    if explicit: out.append(filt)
    return out, payload

def zpack(stream, data):
    if len(data) < 12: return data
    c = streams[stream].compress(data) + streams[stream].flush(zlib.Z_SYNC_FLUSH)
    return compact(len(c)) + c

def build_update():
    out = bytearray()
    # ExtendedDesktopSize first: advertises resize support.
    out += rect(0, 0, W, H, -308) + bytes([1, 0, 0, 0]) + struct.pack(">IHHHHI", 7, 0, 0, W, H, 0)
    # Fill
    out += rect(0, 0, 20, 20, 7) + bytes([0x80]) + rgb(0xFF0000)
    expect.extend([(0, 0, 0xFF0000), (19, 19, 0xFF0000)])
    # Basic, copy filter (implicit), stream 0
    f = lambda x, y: ((x * 25) << 16) | ((y * 25) << 8) | 0x40
    data = b"".join(rgb(f(x, y)) for y in range(10) for x in range(10))
    out += rect(20, 0, 10, 10, 7) + bytes([0 << 4]) + zpack(0, data)
    expect.extend([(20 + x, y, f(x, y)) for x, y in [(0, 0), (9, 9), (3, 7)]])
    # Palette, 2 colours, 1 bpp, stream 1
    pal = [0x00FF00, 0x112233]
    g = lambda x, y: pal[(x // 3) % 2]
    rows = bytearray()
    for y in range(4):
        bits = [(x // 3) % 2 for x in range(16)]
        for i in range(0, 16, 8):
            b = 0
            for k, v in enumerate(bits[i:i + 8]): b |= v << (7 - k)
            rows.append(b)
    out += rect(30, 0, 16, 4, 7) + bytes([(1 | 4) << 4, 1, 1]) + rgb(pal[0]) + rgb(pal[1]) + zpack(1, bytes(rows))
    expect.extend([(30 + x, y, g(x, y)) for x, y in [(0, 0), (3, 1), (15, 3)]])
    # Palette, 5 colours, 8 bpp, stream 2
    pal5 = [0x000000, 0xFF00FF, 0x00FFFF, 0x808080, 0xFFFFFF]
    idx = bytes([(x + y) % 5 for y in range(8) for x in range(8)])
    out += rect(50, 0, 8, 8, 7) + bytes([(2 | 4) << 4, 1, 4]) + b"".join(rgb(c) for c in pal5) + zpack(2, idx)
    expect.extend([(50 + x, y, pal5[(x + y) % 5]) for x, y in [(0, 0), (7, 7), (2, 5)]])
    # Gradient filter, stream 3
    img = [[((x * 30) & 255, (y * 20) & 255, ((x + y) * 7) & 255) for x in range(8)] for y in range(8)]
    res = bytearray()
    for y in range(8):
        for x in range(8):
            for c in range(3):
                left = img[y][x - 1][c] if x else 0
                up = img[y - 1][x][c] if y else 0
                ul = img[y - 1][x - 1][c] if x and y else 0
                p = min(max(left + up - ul, 0), 255)
                res.append((img[y][x][c] - p) & 255)
    out += rect(60, 0, 8, 8, 7) + bytes([(3 | 4) << 4, 2]) + zpack(3, bytes(res))
    for x, y in [(0, 0), (7, 7), (4, 2)]:
        r, gg, b = img[y][x]; expect.append((60 + x, y, (r << 16) | (gg << 8) | b))
    # Tiny palette rect: 2 bytes of data are sent raw (no zlib)
    out += rect(70, 0, 4, 2, 7) + bytes([(0 | 4) << 4, 1, 1]) + rgb(0xABCDEF) + rgb(0x0F0F0F) + bytes([0b10100000, 0b01010000])
    expect.extend([(70, 0, 0x0F0F0F), (71, 0, 0xABCDEF), (71, 1, 0x0F0F0F)])
    # JPEG (solid blue)
    out += rect(0, 40, 32, 32, 7) + bytes([0x90]) + compact(len(JPEG)) + JPEG
    expect.extend([(0, 40, 0x0000FF), (31, 71, 0x0000FF), (16, 56, 0x0000FF)])
    out += rect(0, 0, 0, 0, -224)  # LastRect
    return bytes([0, 0]) + struct.pack(">H", 0xFFFF) + bytes(out)

def recv_exact(c, n):
    b = b""
    while len(b) < n:
        d = c.recv(n - len(b))
        if not d: raise EOFError
        b += d
    return b

def ext_clip(flags, payload=b""):
    body = struct.pack(">I", flags) + payload
    return bytes([3, 0, 0, 0]) + struct.pack(">i", -len(body)) + body

CAPS, REQ, PEEK, NOTIFY, PROVIDE, TEXT = 1 << 24, 1 << 25, 1 << 26, 1 << 27, 1 << 28, 1

def serve():
    global W, H
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT)); s.listen(4)
    while True:
        c, _ = s.accept()
        try:
            session(c)
        except (EOFError, ConnectionError, OSError):
            pass
        except Exception:
            import traceback; traceback.print_exc()
        finally:
            c.close()

class Locked:
    """Serialises writes: the push thread and the request handler share one socket."""
    def __init__(self, sock): self.sock, self.lock = sock, threading.Lock()
    def sendall(self, b):
        with self.lock: self.sock.sendall(b)
    def recv(self, n): return self.sock.recv(n)

def session(c):
    global W, H, streams
    c = Locked(c)
    streams = [zlib.compressobj() for _ in range(4)]  # zlib state is per connection, like a real server
    c.sendall(b"RFB 003.008\n"); recv_exact(c, 12)
    c.sendall(bytes([1, 19])); assert recv_exact(c, 1)[0] == 19
    c.sendall(bytes([0, 2])); recv_exact(c, 2); c.sendall(bytes([0]))
    sub = 256 if AUTH == "plain" else 2
    c.sendall(bytes([1]) + struct.pack(">I", sub))
    assert struct.unpack(">I", recv_exact(c, 4))[0] == sub
    if sub == 256:
        ul, pl = struct.unpack(">II", recv_exact(c, 8))
        user, pw = recv_exact(c, ul).decode(), recv_exact(c, pl).decode()
        ok = (user, pw) == ("circe", "secret")
    else:
        c.sendall(bytes(range(16))); recv_exact(c, 16); ok = True
    if not ok:
        msg = b"Authentication failure"
        c.sendall(struct.pack(">I", 1) + struct.pack(">I", len(msg)) + msg); return
    c.sendall(struct.pack(">I", 0))
    recv_exact(c, 1)
    name = b"Fake TigerVNC (Linux)"
    c.sendall(struct.pack(">HH", W, H) + bytes(16) + struct.pack(">I", len(name)) + name)
    sent_first = False
    cu = {"on": False}
    def pusher():  # continuous updates: push a changing pixel every 50 ms without being asked
        n = 0
        while True:
            threading.Event().wait(0.05)
            if not cu["on"]: continue
            rx, ry, rw, rh = cu.get("region", (0, 0, W, H))
            if not (rx <= W - 1 < rx + rw and ry <= H - 1 < ry + rh): continue  # like Xvnc: only the requested region
            n += 1
            try:
                c.sendall(bytes([0, 0]) + struct.pack(">H", 1) + rect(W - 1, H - 1, 1, 1, 7) + bytes([0x80]) + rgb(n * 1234567 & 0xFFFFFF))
            except OSError:
                return
    threading.Thread(target=pusher, daemon=True).start()
    while True:
        t = recv_exact(c, 1)[0]
        if t == 0: recv_exact(c, 19)
        elif t == 2:
            n = struct.unpack(">xH", recv_exact(c, 3))[0]; recv_exact(c, 4 * n)
        elif t == 3:
            incremental = recv_exact(c, 9)[0]
            if cu["on"] and incremental: cu["stray_requests"] = cu.get("stray_requests", 0) + 1
            if not incremental:  # like a real server: full refresh on request (e.g. after a resize)
                c.sendall(build_update())
            if not sent_first:
                sent_first = True
                c.sendall(bytes([150]))  # EndOfContinuousUpdates: "I support them"
                c.sendall(ext_clip(CAPS | TEXT | REQ | PEEK | NOTIFY | PROVIDE, struct.pack(">I", 1 << 20)))
        elif t == 4: recv_exact(c, 7)
        elif t == 5: recv_exact(c, 5)
        elif t == 6:
            recv_exact(c, 3); ln = struct.unpack(">i", recv_exact(c, 4))[0]
            body = recv_exact(c, abs(ln))
            if ln < 0:
                flags = struct.unpack(">I", body[:4])[0]
                if flags & CAPS:  # client caps received -> announce our clipboard text
                    c.sendall(ext_clip(NOTIFY | TEXT))
                elif flags & REQ:
                    raw = CLIP_TEXT.encode() + b"\0"
                    c.sendall(ext_clip(PROVIDE | TEXT, zlib.compress(struct.pack(">I", len(raw)) + raw)))
        elif t == 150:
            enable, rx, ry, rw, rh = struct.unpack(">BHHHH", recv_exact(c, 9)); cu["on"] = bool(enable)
            cu["region"] = (rx, ry, rw, rh)
            c.sendall(bytes([248, 0, 0, 0]) + struct.pack(">I", (1 << 31) | 0b11) + bytes([2]) + b"hi")  # fence request
        elif t == 248:
            recv_exact(c, 3); recv_exact(c, 4); ln = recv_exact(c, 1)[0]; recv_exact(c, ln)
            cu["fenced"] = True
        elif t == 251:
            recv_exact(c, 1); w, h, n = struct.unpack(">HHB", recv_exact(c, 5)); recv_exact(c, 1 + 16 * n)
            W, H = w, h
            c.sendall(bytes([0, 0]) + struct.pack(">H", 1) + rect(1, 0, W, H, -308)
                      + bytes([1, 0, 0, 0]) + struct.pack(">IHHHHI", 7, 0, 0, W, H, 0))
        else:
            raise EOFError

if __name__ == "__main__":
    build_update(); streams = [zlib.compressobj() for _ in range(4)]  # precompute expectations only
    print(" ".join(f"--expect {x},{y}=0x{c:06X}" for x, y, c in expect), flush=True)
    threading.Thread(target=serve, daemon=True).start()
    threading.Event().wait()
