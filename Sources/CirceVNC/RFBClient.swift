import Foundation
import Network

/// RFB 3.8 protocol engine. Runs its read loop on a dedicated thread; delegates hop to main.
final class RFBClient: @unchecked Sendable {
    struct Credentials { var username: String; var password: String }

    enum Event {
        case needsCredentials(usernameRequired: Bool, error: String?)
        case connected(name: String, width: Int, height: Int, isApple: Bool)
        case resized(width: Int, height: Int)
        case frameUpdated(RFBFramebuffer)
        case cursor(RFBCursor)
        case clipboard(String)
        case bell
        case closed(String?)
    }

    private let stream: RFBStream
    private let onEvent: (Event) -> Void
    private var fb: RFBFramebuffer?
    private let zlib = ZlibStream()
    private var thread: Thread?
    private let credentialLock = NSCondition()
    private var pendingCredentials: Credentials?
    private var cancelled = false
    private(set) var isApple = false
    private(set) var bytesIn: UInt64 = 0
    var initialCredentials: Credentials?

    init(endpoint: NWEndpoint, onEvent: @escaping (Event) -> Void) {
        stream = RFBStream(endpoint: endpoint)
        self.onEvent = onEvent
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.name = "circe.vnc.reader"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }

    func stop() {
        cancelled = true
        credentialLock.lock(); credentialLock.broadcast(); credentialLock.unlock()
        stream.close()
    }

    func provideCredentials(_ c: Credentials) {
        credentialLock.lock()
        pendingCredentials = c
        credentialLock.broadcast()
        credentialLock.unlock()
    }

    private func waitForCredentials(usernameRequired: Bool, error: String?) throws -> Credentials {
        if error == nil, let c = initialCredentials { initialCredentials = nil; return c }
        onEvent(.needsCredentials(usernameRequired: usernameRequired, error: error))
        credentialLock.lock()
        defer { credentialLock.unlock() }
        while pendingCredentials == nil && !cancelled { credentialLock.wait() }
        if cancelled { throw RFBError.closed }
        let c = pendingCredentials!
        pendingCredentials = nil
        return c
    }

    private func run() {
        do {
            try stream.open()
            try handshake()
            try messageLoop()
        } catch {
            if !cancelled { onEvent(.closed(Self.describe(error))) }
            stream.close()
            return
        }
    }

    static func describe(_ e: Error) -> String {
        if let r = e as? RFBError { return r.description }
        if let nw = e as? NWError, case .posix(let code) = nw, code == .ECONNREFUSED {
            return "That computer isn't accepting screen sharing connections."
        }
        return e.localizedDescription
    }

    // MARK: Handshake

    private func handshake() throws {
        let version = String(decoding: try stream.read(12), as: UTF8.self)
        guard version.hasPrefix("RFB ") else { throw RFBError.protocolError("Not a VNC server") }
        let minor = Int(version.dropFirst(8).prefix(3)) ?? 3
        let useMinor = minor >= 8 ? 8 : (minor >= 7 ? 7 : 3)
        stream.write(Data(String(format: "RFB 003.%03d\n", useMinor).utf8))

        var types: [UInt8]
        if useMinor >= 7 {
            let n = Int(try stream.u8())
            if n == 0 { throw RFBError.authFailed(try reason()) }
            types = Array(try stream.read(n))
        } else {
            types = [UInt8(truncatingIfNeeded: try stream.u32())]
        }
        isApple = types.contains(30)

        var lastError: String?
        // Retry loop: wrong password -> prompt again (server closes, so reconnect isn't possible on 3.8; we report).
        let chosen: UInt8
        if types.contains(1) { chosen = 1 }
        else if types.contains(30) { chosen = 30 }
        else if types.contains(2) { chosen = 2 }
        else { throw RFBError.unsupported("This server needs an authentication method Circe doesn't support yet (\(types)).") }
        if useMinor >= 7 { stream.write(Data([chosen])) }

        switch chosen {
        case 1:
            break
        case 2:
            let challenge = try stream.read(16)
            let c = try waitForCredentials(usernameRequired: false, error: lastError)
            stream.write(RFBCrypto.vncAuthResponse(challenge: challenge, password: c.password))
        case 30:
            let gen = try stream.read(2)
            let keyLen = Int(try stream.u16())
            let prime = try stream.read(keyLen)
            let serverPub = try stream.read(keyLen)
            let c = try waitForCredentials(usernameRequired: true, error: lastError)
            let (enc, pub) = RFBCrypto.ardResponse(generator: gen, prime: prime, serverPublic: serverPub,
                                                   username: c.username, password: c.password)
            stream.write(enc + pub)
        default:
            break
        }
        if chosen != 1 || useMinor >= 8 {
            let result = try stream.u32()
            if result != 0 {
                lastError = useMinor >= 8 ? (try? reason()) : nil
                throw RFBError.authFailed(lastError.map { "Authentication failed: \($0)" } ?? "Incorrect name or password.")
            }
        }

        stream.write(Data([1])) // ClientInit: shared session, don't kick other viewers
        let w = Int(try stream.u16()), h = Int(try stream.u16())
        try stream.skip(16) // server pixel format; we set our own
        let name = String(decoding: try stream.read(Int(try stream.u32())), as: UTF8.self)

        setPixelFormat()
        setEncodings()
        try resize(w, h)
        onEvent(.connected(name: name, width: w, height: h, isApple: isApple))
        requestUpdate(incremental: false)
    }

    private func reason() throws -> String {
        String(decoding: try stream.read(Int(try stream.u32())), as: UTF8.self)
    }

    private func setPixelFormat() {
        // 32bpp little-endian true colour, R at bit 16, G 8, B 0  ==  BGRA in memory.
        var d = Data([0, 0, 0, 0])
        d += [32, 24, 0, 1]
        d += [0, 255, 0, 255, 0, 255]
        d += [16, 8, 0, 0, 0, 0]
        stream.write(d)
    }

    private func setEncodings() {
        let encodings: [Int32] = [16 /*ZRLE*/, 5 /*Hextile*/, 1 /*CopyRect*/, 0 /*Raw*/,
                                  -223 /*DesktopSize*/, -239 /*Cursor*/]
        var d = Data([2, 0])
        d += be16(UInt16(encodings.count))
        for e in encodings { d += be32(UInt32(bitPattern: e)) }
        stream.write(d)
    }

    private func resize(_ w: Int, _ h: Int) throws {
        guard let f = RFBFramebuffer(width: w, height: h) else { throw RFBError.protocolError("framebuffer \(w)x\(h)") }
        fb = f
    }

    // MARK: Client -> server

    func requestUpdate(incremental: Bool) {
        guard let fb else { return }
        var d = Data([3, incremental ? 1 : 0])
        d += be16(0) + be16(0) + be16(UInt16(fb.width)) + be16(UInt16(fb.height))
        stream.write(d)
    }

    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        var d = Data([5, buttons])
        d += be16(UInt16(clamping: max(0, x))) + be16(UInt16(clamping: max(0, y)))
        stream.write(d)
    }

    func sendKey(_ keysym: UInt32, down: Bool) {
        var d = Data([4, down ? 1 : 0, 0, 0])
        d += be32(keysym)
        stream.write(d)
    }

    func sendClipboard(_ text: String) {
        let bytes = text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
        var d = Data([6, 0, 0, 0])
        d += be32(UInt32(bytes.count))
        d += bytes
        stream.write(d)
    }

    // MARK: Server -> client

    private func messageLoop() throws {
        while !cancelled {
            switch try stream.u8() {
            case 0: try framebufferUpdate()
            case 1:
                try stream.skip(3)
                let n = Int(try stream.u16())
                try stream.skip(n * 6)
            case 2: onEvent(.bell)
            case 3:
                try stream.skip(3)
                let text = String(data: try stream.read(Int(try stream.u32())), encoding: .isoLatin1) ?? ""
                onEvent(.clipboard(text))
            case let t:
                throw RFBError.protocolError("unknown server message \(t)")
            }
        }
    }

    private func framebufferUpdate() throws {
        try stream.skip(1)
        let rects = Int(try stream.u16())
        // Pipeline the next request so the server can start encoding while we decode.
        var resized = false
        guard let fb0 = fb else { throw RFBError.protocolError("no framebuffer") }
        fb0.lock()
        defer { fb?.unlock() }
        for _ in 0..<rects {
            let x = Int(try stream.u16()), y = Int(try stream.u16())
            let w = Int(try stream.u16()), h = Int(try stream.u16())
            let enc = try stream.i32()
            guard let fb else { break }
            switch enc {
            case 0:
                let data = try stream.read(w * h * 4)
                data.withUnsafeBytes { fb.blit(x, y, w, h, $0) }
            case 1:
                let sx = Int(try stream.u16()), sy = Int(try stream.u16())
                fb.copyRect(from: sx, sy, to: x, y, w, h)
            case 5: try decodeHextile(fb, x, y, w, h)
            case 16: try decodeZRLE(fb, x, y, w, h)
            case -223:
                fb.unlock()
                try resize(w, h)
                self.fb?.lock()
                resized = true
                onEvent(.resized(width: w, height: h))
            case -239:
                let pixels = try stream.read(w * h * 4)
                let mask = try stream.read(((w + 7) / 8) * h)
                if w > 0 && h > 0 { onEvent(.cursor(Self.cursor(w, h, x, y, pixels, mask))) }
            default:
                throw RFBError.protocolError("unsupported encoding \(enc)")
            }
        }
        if let fb { onEvent(.frameUpdated(fb)) }
        requestUpdate(incremental: !resized)
    }

    private static func cursor(_ w: Int, _ h: Int, _ hx: Int, _ hy: Int, _ px: Data, _ mask: Data) -> RFBCursor {
        var rgba = Data(count: w * h * 4)
        let rowBytes = (w + 7) / 8
        px.withUnsafeBytes { p in
            mask.withUnsafeBytes { m in
                rgba.withUnsafeMutableBytes { o in
                    for y in 0..<h {
                        for x in 0..<w {
                            let i = (y * w + x) * 4
                            let visible = m[y * rowBytes + x / 8] & (0x80 >> (x % 8)) != 0
                            // server pixel is B,G,R,X -> RGBA premultiplied
                            o[i] = visible ? p[i + 2] : 0
                            o[i + 1] = visible ? p[i + 1] : 0
                            o[i + 2] = visible ? p[i] : 0
                            o[i + 3] = visible ? 255 : 0
                        }
                    }
                }
            }
        }
        return RFBCursor(width: w, height: h, hotX: hx, hotY: hy, rgba: rgba)
    }

    // MARK: Hextile

    private func pixel() throws -> UInt32 {
        let d = try stream.read(4)
        return d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    }

    private func decodeHextile(_ fb: RFBFramebuffer, _ rx: Int, _ ry: Int, _ rw: Int, _ rh: Int) throws {
        var bg: UInt32 = 0, fg: UInt32 = 0
        for ty in stride(from: ry, to: ry + rh, by: 16) {
            for tx in stride(from: rx, to: rx + rw, by: 16) {
                let tw = min(16, rx + rw - tx), th = min(16, ry + rh - ty)
                let sub = try stream.u8()
                if sub & 1 != 0 {
                    let data = try stream.read(tw * th * 4)
                    data.withUnsafeBytes { fb.blit(tx, ty, tw, th, $0) }
                    continue
                }
                if sub & 2 != 0 { bg = try pixel() }
                fb.fill(tx, ty, tw, th, bg)
                if sub & 4 != 0 { fg = try pixel() }
                if sub & 8 != 0 {
                    let n = Int(try stream.u8())
                    let coloured = sub & 16 != 0
                    for _ in 0..<n {
                        let c = coloured ? try pixel() : fg
                        let xy = try stream.u8(), wh = try stream.u8()
                        fb.fill(tx + Int(xy >> 4), ty + Int(xy & 15), Int(wh >> 4) + 1, Int(wh & 15) + 1, c)
                    }
                }
            }
        }
    }

    // MARK: ZRLE

    private func decodeZRLE(_ fb: RFBFramebuffer, _ rx: Int, _ ry: Int, _ rw: Int, _ rh: Int) throws {
        let len = Int(try stream.u32())
        let raw = try zlib.inflate(try stream.read(len))
        try raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var p = 0
            func u8() throws -> UInt8 {
                guard p < buf.count else { throw RFBError.protocolError("ZRLE underrun") }
                defer { p += 1 }
                return buf[p]
            }
            func cpixel() throws -> UInt32 {
                guard p + 3 <= buf.count else { throw RFBError.protocolError("ZRLE underrun") }
                defer { p += 3 }
                return UInt32(buf[p]) | UInt32(buf[p + 1]) << 8 | UInt32(buf[p + 2]) << 16 | 0xFF00_0000
            }
            var tile = [UInt32](repeating: 0, count: 64 * 64)
            for ty in stride(from: ry, to: ry + rh, by: 64) {
                for tx in stride(from: rx, to: rx + rw, by: 64) {
                    let tw = min(64, rx + rw - tx), th = min(64, ry + rh - ty)
                    let n = tw * th
                    let sub = Int(try u8())
                    switch sub {
                    case 0:
                        for i in 0..<n { tile[i] = try cpixel() }
                    case 1:
                        let c = try cpixel()
                        fb.fill(tx, ty, tw, th, c)
                        continue
                    case 2...16:
                        var palette = [UInt32]()
                        for _ in 0..<sub { palette.append(try cpixel()) }
                        let bits = sub == 2 ? 1 : sub <= 4 ? 2 : 4
                        let mask = (1 << bits) - 1
                        for y in 0..<th {
                            var byte = 0, nbits = 0
                            for x in 0..<tw {
                                if nbits == 0 { byte = Int(try u8()); nbits = 8 }
                                nbits -= bits
                                tile[y * tw + x] = palette[min((byte >> nbits) & mask, palette.count - 1)]
                            }
                        }
                    case 128:
                        var i = 0
                        while i < n {
                            let c = try cpixel()
                            var run = 1
                            var b: UInt8
                            repeat { b = try u8(); run += Int(b) } while b == 255
                            for _ in 0..<min(run, n - i) { tile[i] = c; i += 1 }
                        }
                    case 130...255:
                        var palette = [UInt32]()
                        for _ in 0..<(sub - 128) { palette.append(try cpixel()) }
                        var i = 0
                        while i < n {
                            let idx = try u8()
                            var run = 1
                            if idx & 128 != 0 {
                                var b: UInt8
                                repeat { b = try u8(); run += Int(b) } while b == 255
                            }
                            let c = palette[min(Int(idx & 127), palette.count - 1)]
                            for _ in 0..<min(run, n - i) { tile[i] = c; i += 1 }
                        }
                    default:
                        throw RFBError.protocolError("ZRLE subencoding \(sub)")
                    }
                    for y in 0..<th where ty + y < fb.height {
                        let dst = fb.base + (ty + y) * fb.stride + tx
                        tile.withUnsafeBufferPointer { t in
                            dst.update(from: t.baseAddress! + y * tw, count: min(tw, fb.width - tx))
                        }
                    }
                }
            }
        }
    }
}

@inline(__always) func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xFF)]) }
@inline(__always) func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]) }
