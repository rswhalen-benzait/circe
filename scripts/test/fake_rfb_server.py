#!/usr/bin/env python3
"""Tiny RFB 3.8 server (no auth) that sends Raw, ZRLE (all subencodings), Hextile and CopyRect
rectangles with known colours. Prints the --expect arguments for `circe-cli vnc` on stdout."""
import socket, struct, sys, zlib

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 5999
W, H = 200, 120
RED, GREEN, BLUE, WHITE, BLACK, YELLOW = 0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF, 0x000000, 0xFFFF00

def px32(c): return struct.pack("<I", c)          # B,G,R,X for our requested format
def cpx(c): return bytes([c & 255, (c >> 8) & 255, (c >> 16) & 255])
def rect(x, y, w, h, enc): return struct.pack(">HHHHi", x, y, w, h, enc)

expect = []
z = zlib.compressobj()

def zrle_tile(kind, tw, th):
    if kind == "solid": return bytes([1]) + cpx(GREEN), lambda x, y: GREEN
    if kind == "raw":
        f = lambda x, y: BLUE if (x + y) % 2 else WHITE
        return bytes([0]) + b"".join(cpx(f(x, y)) for y in range(th) for x in range(tw)), f
    if kind == "packed":  # 2-colour palette, 1 bit per pixel, rows padded
        f = lambda x, y: RED if (x // 4) % 2 else BLACK
        out = bytearray([2]) + cpx(BLACK) + cpx(RED)
        for y in range(th):
            bits = [1 if f(x, y) == RED else 0 for x in range(tw)]
            for i in range(0, tw, 8):
                b = 0
                for k, v in enumerate(bits[i:i + 8]): b |= v << (7 - k)
                out.append(b)
        return bytes(out), f
    if kind == "rle":  # plain RLE: top half yellow, bottom half red
        n = tw * th; half = tw * (th // 2)
        def run(c, length):
            r = bytearray(cpx(c)); length -= 1
            while length >= 255: r.append(255); length -= 255
            r.append(length); return bytes(r)
        f = lambda x, y: YELLOW if y < th // 2 else RED
        return bytes([128]) + run(YELLOW, half) + run(RED, n - half), f
    if kind == "prle":  # palette RLE: alternating rows of white (run) / blue (single pixels)
        out = bytearray([130]) + cpx(WHITE) + cpx(BLUE)
        f = lambda x, y: WHITE if y % 2 == 0 else BLUE
        for y in range(th):
            if y % 2 == 0:
                out.append(0x80 | 0); l = tw - 1
                while l >= 255: out.append(255); l -= 255
                out.append(l)
            else:
                out += bytes([1]) * tw
        return bytes(out), f

def zrle_rect(rx, ry, rw, rh, kinds):
    data = bytearray(); k = 0
    for ty in range(ry, ry + rh, 64):
        for tx in range(rx, rx + rw, 64):
            tw, th = min(64, rx + rw - tx), min(64, ry + rh - ty)
            body, f = zrle_tile(kinds[k % len(kinds)], tw, th); k += 1
            data += body
            for (sx, sy) in [(0, 0), (tw - 1, th - 1), (tw // 2, th // 2), (min(5, tw - 1), min(1, th - 1))]:
                expect.append((tx + sx, ty + sy, f(sx, sy)))
    comp = z.compress(bytes(data)) + z.flush(zlib.Z_SYNC_FLUSH)
    return rect(rx, ry, rw, rh, 16) + struct.pack(">I", len(comp)) + comp

def hextile_rect(x, y):  # 32x32 = four 16x16 tiles; bg white + one coloured subrect each
    out = bytearray(rect(x, y, 32, 32, 5))
    for ty in range(2):
        for tx in range(2):
            out.append(2 | 8 | 16) ; out += px32(WHITE); out.append(1)
            out += px32(RED) + bytes([(2 << 4) | 3, ((4 - 1) << 4) | (5 - 1)])
    for (tx, ty) in [(0, 0), (16, 16)]:
        expect.append((x + tx, y + ty, WHITE))
        expect.append((x + tx + 2, y + ty + 3, RED))
        expect.append((x + tx + 5, y + ty + 7, RED))
    return bytes(out)

def serve():
    s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(("127.0.0.1", PORT)); s.listen(1)
    c, _ = s.accept()
    c.sendall(b"RFB 003.008\n"); c.recv(12)
    c.sendall(bytes([1, 1])); c.recv(1); c.sendall(struct.pack(">I", 0))
    c.recv(1)
    name = b"Fake RFB"
    c.sendall(struct.pack(">HH", W, H) + bytes(16) + struct.pack(">I", len(name)) + name)
    c.settimeout(0.5)
    sent = 0
    while True:
        try:
            d = c.recv(65536)
            if not d: break
        except socket.timeout:
            continue
        if b"\x03" in d and sent < 2:
            if sent == 0:
                body = rect(0, 0, 10, 10, 0) + px32(RED) * 100
                body += zrle_rect(10, 0, 100, 80, ["solid", "raw", "packed", "rle"])
                body += hextile_rect(120, 0)
                body += rect(150, 50, 10, 10, 1) + struct.pack(">HH", 0, 0)
                n = 4
            else:
                body = zrle_rect(0, 90, 70, 30, ["prle", "solid"])  # second rect: persistent zlib stream
                n = 1
            c.sendall(bytes([0, 0]) + struct.pack(">H", n) + body)
            sent += 1

if __name__ == "__main__":
    expect += [(0, 0, RED), (9, 9, RED), (150, 50, RED), (159, 59, RED)]
    # Precompute expectations by building the rects once (zlib state is reset afterwards).
    zrle_rect(10, 0, 100, 80, ["solid", "raw", "packed", "rle"]); hextile_rect(120, 0); zrle_rect(0, 90, 70, 30, ["prle", "solid"])
    z = zlib.compressobj()
    print(" ".join(f"--expect {x},{y}=0x{c:06X}" for x, y, c in expect), flush=True)
    serve()
