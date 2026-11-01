import CoreGraphics
import Foundation
import ImageIO
import Network

/// RFB 3.8 protocol engine. Runs its read loop on a dedicated thread; delegates hop to main.
final class RFBClient: @unchecked Sendable {
    struct Credentials: Equatable { var username: String; var password: String }

    enum Event {
        case needsCredentials(usernameRequired: Bool, error: String?)
        case credentialsAccepted(Credentials)
        case credentialsRejected(Credentials)
        case connected(name: String, width: Int, height: Int, isApple: Bool)
        /// The server can resize its desktop on request (ExtendedDesktopSize).
        case canResizeDesktop
        case resized(width: Int, height: Int)
        /// `coverage`: fraction of the framebuffer this update repainted (0…1).
        case frameUpdated(RFBFramebuffer, coverage: Double)
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
    private var attemptedCredentials: Credentials?
    private var cancelled = false
    private(set) var isApple = false
    private(set) var bytesIn: UInt64 = 0
    var initialCredentials: Credentials?

    private let bonjourEndpoint: NWEndpoint?
    private var tightStreams = [ZlibStream?](repeating: nil, count: 4)

    // ExtendedDesktopSize
    private var supportsSetDesktopSize = false
    private var screenID: UInt32 = 0
    private var screenFlags: UInt32 = 0

    // Continuous updates: the server pushes frames instead of waiting for a request each time,
    // removing one network round trip per frame (big over the internet).
    private var continuousUpdates = false

    // While a separate video stream shows the desktop, ask VNC for a single pixel: it still carries
    // input, clipboard, resizes and cursor shapes, but no longer spends bandwidth on pixels.
    private let regionLock = NSLock()
    private var pixelsSuppressed = false

    // Extended clipboard (UTF-8)
    private var extendedClipboard = false
    private let clipLock = NSLock()
    private var localClipboard: String?

    init(tunnel: RFBTunnel, bonjourEndpoint: NWEndpoint? = nil, onEvent: @escaping (Event) -> Void) {
        stream = RFBStream(tunnel: tunnel)
        self.bonjourEndpoint = bonjourEndpoint
        self.onEvent = onEvent
    }

    var tunnel: RFBTunnel { stream.tunnel }
    var bytesRead: UInt64 { stream.bytesRead }

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
        if error == nil, let c = initialCredentials { initialCredentials = nil; attemptedCredentials = c; return c }
        onEvent(.needsCredentials(usernameRequired: usernameRequired, error: error))
        credentialLock.lock()
        defer { credentialLock.unlock() }
        while pendingCredentials == nil && !cancelled { credentialLock.wait() }
        if cancelled { throw RFBError.closed }
        let c = pendingCredentials!
        pendingCredentials = nil
        attemptedCredentials = c
        return c
    }

    private func run() {
        do {
            if let bonjourEndpoint { try stream.open(endpoint: bonjourEndpoint) } else { try stream.open() }
            try handshake()
            try messageLoop()
        } catch {
            // For tunnels, ssh/gcloud's own diagnosis beats a generic "connection closed".
            if !cancelled { onEvent(.closed(stream.closeReason() ?? Self.describe(error))) }
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
        else if types.contains(19) { chosen = 19 }
        else { throw RFBError.unsupported("This server needs an authentication method Circe doesn't support yet (\(types)).") }
        if useMinor >= 7 { stream.write(Data([chosen])) }

        switch chosen {
        case 1:
            break
        case 19:
            try veNCrypt(lastError: lastError)
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
                // Only a SecurityResult rejecting a response proves these credentials failed.
                // EOF, tunnel failures and a pre-auth server refusal must never erase a saved password.
                if let attemptedCredentials { onEvent(.credentialsRejected(attemptedCredentials)) }
                lastError = useMinor >= 8 ? (try? reason()) : nil
                throw RFBError.authFailed(lastError.map { "Authentication failed: \($0)" } ?? "Incorrect name or password.")
            }
        }

        if let attemptedCredentials { onEvent(.credentialsAccepted(attemptedCredentials)) }
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

    /// VeNCrypt (TigerVNC's default). Circe speaks the non-TLS subtypes; over SSH / IAP the tunnel already
    /// encrypts everything. TLS subtypes would need anonymous-DH TLS, which macOS doesn't offer.
    private func veNCrypt(lastError: String?) throws {
        let major = try stream.u8(), minor = try stream.u8()
        guard major == 0, minor >= 2 else { throw RFBError.unsupported("Unsupported VeNCrypt version \(major).\(minor)") }
        stream.write(Data([0, 2]))
        guard try stream.u8() == 0 else { throw RFBError.unsupported("The server rejected VeNCrypt 0.2") }
        let n = Int(try stream.u8())
        var subtypes: [UInt32] = []
        for _ in 0..<n { subtypes.append(try stream.u32()) }
        let pick: UInt32
        if subtypes.contains(1) { pick = 1 }            // None
        else if subtypes.contains(2) { pick = 2 }       // VncAuth
        else if subtypes.contains(256) {                // Plain (user + password, e.g. PAM)
            // Plain sends the account password verbatim: only allow it inside an encrypted tunnel.
            guard stream.tunnel.isTunneled else {
                throw RFBError.unsupported("This VNC server would receive your account password unencrypted. Connect to it through SSH or Google Cloud instead.")
            }
            pick = 256
        }
        else {
            throw RFBError.unsupported("This VNC server only allows TLS logins. Set “SecurityTypes=VncAuth” (Circe's setup script does this) and connect through SSH, which encrypts the session.")
        }
        stream.write(be32(pick))
        switch pick {
        case 2:
            let challenge = try stream.read(16)
            let c = try waitForCredentials(usernameRequired: false, error: lastError)
            stream.write(RFBCrypto.vncAuthResponse(challenge: challenge, password: c.password))
        case 256:
            let c = try waitForCredentials(usernameRequired: true, error: lastError)
            let u = Data(c.username.utf8), pw = Data(c.password.utf8)
            stream.write(be32(UInt32(u.count)) + be32(UInt32(pw.count)) + u + pw)
        default:
            break
        }
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

    static let extendedClipboardEncoding = Int32(bitPattern: 0xC0A1_E5CE)

    private func setEncodings() {
        // Over the internet (tunnels) Tight+JPEG is far lighter than ZRLE; on a LAN ZRLE is lossless and cheap.
        // Apple's server doesn't do Tight well, so Macs keep ZRLE.
        let wan = stream.tunnel.isTunneled && !isApple
        var encodings: [Int32] = wan ? [7 /*Tight*/, 16 /*ZRLE*/] : [16, 7]
        encodings += [5 /*Hextile*/, 1 /*CopyRect*/, 0 /*Raw*/,
                      -223 /*DesktopSize*/, -308 /*ExtendedDesktopSize*/, -239 /*Cursor*/, -224 /*LastRect*/,
                      -313 /*ContinuousUpdates*/, -312 /*Fence*/,
                      Self.extendedClipboardEncoding]
        if wan {
            encodings += [-32 + 8 /*JPEG quality 8*/, -256 + 2 /*compression level 2*/]
        }
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
        if continuousUpdates && incremental { return } // the server streams on its own
        var d = Data([3, incremental ? 1 : 0])
        d += updateRegion(fb)
        stream.write(d)
    }

    private func updateRegion(_ fb: RFBFramebuffer) -> Data {
        let tiny = regionLock.withLock { pixelsSuppressed }
        return be16(0) + be16(0) + be16(tiny ? 1 : UInt16(fb.width)) + be16(tiny ? 1 : UInt16(fb.height))
    }

    /// Stop (or resume) pixel updates; resuming fetches a full frame so the VNC image is current.
    func setPixelsSuppressed(_ on: Bool) {
        let changed = regionLock.withLock { () -> Bool in
            defer { pixelsSuppressed = on }
            return pixelsSuppressed != on
        }
        guard changed else { return }
        if continuousUpdates { enableContinuousUpdates() }
        if !on { requestUpdate(incremental: false) }
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
        if clipLock.withLock({ extendedClipboard }) {
            // Extended clipboard: announce UTF-8 text; the server asks for it when it wants it.
            clipLock.withLock { localClipboard = text }
            sendExtendedClipboard(flags: Self.clipNotify | Self.clipText, payload: Data())
            return
        }
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
            case 150:
                // EndOfContinuousUpdates: the server supports them. Turn them on (once).
                if !continuousUpdates { enableContinuousUpdates() }
            case 248:
                try handleFence()
            case 3:
                try stream.skip(3)
                let len = try stream.i32()
                if len < 0 {
                    try handleExtendedClipboard(try stream.read(Int(-Int64(len))))
                } else {
                    let text = String(data: try stream.read(Int(len)), encoding: .isoLatin1) ?? ""
                    onEvent(.clipboard(text))
                }
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
        // 0xFFFF = unknown count; the server ends with a LastRect pseudo-rectangle.
        var remaining = rects == 0xFFFF ? Int.max : rects
        var painted = 0
        rectLoop: while remaining > 0 {
            remaining -= 1
            let x = Int(try stream.u16()), y = Int(try stream.u16())
            let w = Int(try stream.u16()), h = Int(try stream.u16())
            let enc = try stream.i32()
            if enc >= 0 { painted += w * h } // real pixels, not pseudo-encodings
            guard let fb else { break }
            switch enc {
            case 7: try decodeTight(fb, x, y, w, h)
            case -224: break rectLoop
            case -308:
                // ExtendedDesktopSize: x = reason, y = status; the payload lists the screens.
                let count = Int(try stream.u8())
                try stream.skip(3)
                for i in 0..<count {
                    let id = try stream.u32()
                    try stream.skip(8)
                    let flags = try stream.u32()
                    if i == 0 { screenID = id; screenFlags = flags }
                }
                if !supportsSetDesktopSize { supportsSetDesktopSize = true; onEvent(.canResizeDesktop) }
                if x == 1 && y != 0 { break } // our resize request was refused; keep going
                if w != fb.width || h != fb.height {
                    fb.unlock()
                    try resize(w, h)
                    self.fb?.lock()
                    resized = true
                    onEvent(.resized(width: w, height: h))
                }
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
        if let fb { onEvent(.frameUpdated(fb, coverage: Double(painted) / Double(max(fb.width * fb.height, 1)))) }
        if resized && continuousUpdates { enableContinuousUpdates() }
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

    // MARK: Continuous updates & fences

    private func enableContinuousUpdates() {
        guard let fb else { return }
        continuousUpdates = true
        var d = Data([150, 1])
        d += updateRegion(fb)
        stream.write(d)
    }

    /// Fences keep ordering across the pipeline; answer requests with the flags we understand.
    private func handleFence() throws {
        try stream.skip(3)
        let flags = try stream.u32()
        let len = Int(try stream.u8())
        let payload = try stream.read(min(len, 64))
        guard flags & (1 << 31) != 0 else { return } // a response to us; nothing to do
        let supported: UInt32 = 0b111 // BlockBefore | BlockAfter | SyncNext
        var d = Data([248, 0, 0, 0])
        d += be32(flags & supported) + Data([UInt8(payload.count)]) + payload
        stream.write(d)
    }

    // MARK: Desktop size

    /// Ask the server to resize its desktop (e.g. to fit our window). Needs ExtendedDesktopSize support.
    func requestDesktopSize(width: Int, height: Int) {
        guard supportsSetDesktopSize, width >= 320, height >= 240 else { return }
        let w = UInt16(clamping: width & ~1), h = UInt16(clamping: height & ~1)
        var d = Data([251, 0])
        d += be16(w) + be16(h) + Data([1, 0])
        d += be32(screenID) + be16(0) + be16(0) + be16(w) + be16(h) + be32(screenFlags)
        stream.write(d)
    }

    // MARK: Extended clipboard

    static let clipText: UInt32 = 1
    static let clipCaps: UInt32 = 1 << 24, clipRequest: UInt32 = 1 << 25, clipPeek: UInt32 = 1 << 26
    static let clipNotify: UInt32 = 1 << 27, clipProvide: UInt32 = 1 << 28

    private func sendExtendedClipboard(flags: UInt32, payload: Data) {
        var d = Data([6, 0, 0, 0])
        d += be32(UInt32(bitPattern: -Int32(4 + payload.count)))
        d += be32(flags) + payload
        stream.write(d)
    }

    private func handleExtendedClipboard(_ data: Data) throws {
        guard data.count >= 4 else { return }
        let flags = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let body = data.dropFirst(4)
        if flags & Self.clipCaps != 0 {
            clipLock.withLock { extendedClipboard = true }
            // Our capabilities: UTF-8 text, all actions, up to 20 MB.
            let caps = Self.clipCaps | Self.clipText | Self.clipRequest | Self.clipPeek | Self.clipNotify | Self.clipProvide
            sendExtendedClipboard(flags: caps, payload: be32(20 << 20))
        } else if flags & Self.clipRequest != 0, flags & Self.clipText != 0 {
            guard let text = clipLock.withLock({ localClipboard }) else { return }
            var raw = be32(UInt32(text.utf8.count + 1))
            raw += Data(text.utf8) + Data([0])
            sendExtendedClipboard(flags: Self.clipProvide | Self.clipText, payload: zlibCompress(raw))
        } else if flags & Self.clipPeek != 0 {
            let has = clipLock.withLock { localClipboard != nil }
            sendExtendedClipboard(flags: Self.clipNotify | (has ? Self.clipText : 0), payload: Data())
        } else if flags & Self.clipNotify != 0, flags & Self.clipText != 0 {
            sendExtendedClipboard(flags: Self.clipRequest | Self.clipText, payload: Data())
        } else if flags & Self.clipProvide != 0, flags & Self.clipText != 0 {
            let raw = try ZlibStream().inflate(Data(body))
            guard raw.count >= 4 else { return }
            let len = Int(raw.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            var text = raw.dropFirst(4).prefix(len)
            if text.last == 0 { text = text.dropLast() }
            onEvent(.clipboard(String(decoding: text, as: UTF8.self)))
        }
    }

    // MARK: Tight

    private func compactLength() throws -> Int {
        var len = 0
        for i in 0..<3 {
            let b = Int(try stream.u8())
            len |= (i == 2 ? b : b & 0x7F) << (7 * i)
            if i < 2 && b & 0x80 == 0 { break }
        }
        return len
    }

    /// TPIXEL: 3 bytes R, G, B for our 32bpp depth-24 format.
    private static func tpixel(_ p: UnsafeRawBufferPointer, _ i: Int) -> UInt32 {
        0xFF00_0000 | UInt32(p[i]) << 16 | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2])
    }

    private func decodeTight(_ fb: RFBFramebuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int) throws {
        let ctl = try stream.u8()
        for i in 0..<4 where ctl & (1 << i) != 0 { tightStreams[i] = nil }
        let comp = ctl >> 4
        if comp == 8 { // Fill
            let c = try stream.read(3)
            fb.fill(x, y, w, h, c.withUnsafeBytes { Self.tpixel($0, 0) })
            return
        }
        if comp == 9 { // JPEG
            let jpeg = try stream.read(try compactLength())
            try blitJPEG(fb, x, y, w, h, jpeg)
            return
        }
        guard comp & 8 == 0 else { throw RFBError.protocolError("Tight compression \(comp)") }
        let streamID = Int(comp & 3)
        let filter = comp & 4 != 0 ? try stream.u8() : 0
        var palette: [UInt32] = []
        var dataSize = w * h * 3
        switch filter {
        case 0, 2: break
        case 1:
            let n = Int(try stream.u8()) + 1
            let p = try stream.read(n * 3)
            p.withUnsafeBytes { b in for i in 0..<n { palette.append(Self.tpixel(b, i * 3)) } }
            dataSize = n == 2 ? ((w + 7) / 8) * h : w * h
        default: throw RFBError.protocolError("Tight filter \(filter)")
        }
        let data: Data
        if dataSize < 12 {
            data = try stream.read(dataSize)
        } else {
            let z = tightStreams[streamID] ?? ZlibStream()
            tightStreams[streamID] = z
            data = try z.inflate(try stream.read(try compactLength()))
        }
        guard data.count >= dataSize else { throw RFBError.protocolError("Tight data underrun") }

        var row = [UInt32](repeating: 0, count: w)
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            var prev = [UInt8](repeating: 0, count: w * 3) // gradient filter: previous row
            for ry in 0..<h where y + ry < fb.height && y + ry >= 0 {
                switch filter {
                case 1 where palette.count == 2:
                    let rowBytes = (w + 7) / 8
                    for rx in 0..<w {
                        let bit = b[ry * rowBytes + rx / 8] >> (7 - UInt8(rx % 8)) & 1
                        row[rx] = palette[Int(bit)]
                    }
                case 1:
                    for rx in 0..<w { row[rx] = palette[min(Int(b[ry * w + rx]), palette.count - 1)] }
                case 2:
                    var cur = [UInt8](repeating: 0, count: w * 3)
                    for rx in 0..<w {
                        for c in 0..<3 {
                            let left = rx > 0 ? Int(cur[(rx - 1) * 3 + c]) : 0
                            let up = Int(prev[rx * 3 + c])
                            let upLeft = rx > 0 ? Int(prev[(rx - 1) * 3 + c]) : 0
                            let predicted = min(max(left + up - upLeft, 0), 255)
                            cur[rx * 3 + c] = UInt8(truncatingIfNeeded: predicted + Int(b[(ry * w + rx) * 3 + c]))
                        }
                        row[rx] = 0xFF00_0000 | UInt32(cur[rx * 3]) << 16 | UInt32(cur[rx * 3 + 1]) << 8 | UInt32(cur[rx * 3 + 2])
                    }
                    prev = cur
                default:
                    for rx in 0..<w { row[rx] = Self.tpixel(b, (ry * w + rx) * 3) }
                }
                let dst = fb.base + (y + ry) * fb.stride
                for rx in 0..<w where x + rx >= 0 && x + rx < fb.width { dst[x + rx] = row[rx] }
            }
        }
    }

    private func blitJPEG(_ fb: RFBFramebuffer, _ x: Int, _ y: Int, _ w: Int, _ h: Int, _ jpeg: Data) throws {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw RFBError.protocolError("bad JPEG") }
        var pixels = [UInt32](repeating: 0, count: w * h)
        let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw RFBError.protocolError("JPEG context") }
        pixels.withUnsafeBytes { fb.blit(x, y, w, h, $0) }
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
