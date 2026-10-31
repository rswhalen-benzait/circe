import Foundation

public let circeProtocolVersion: UInt16 = 1
public let circeBonjourType = "_circe._tcp"
public let circeDefaultPort: UInt16 = 47_800

// MARK: - Control payloads (JSON; infrequent)

public struct ClientHello: Codable, Sendable {
    public var version: UInt16
    public var deviceID: String
    public var deviceName: String
    public var staticKey: Data
    public var ephemeralKey: Data
    public init(version: UInt16, deviceID: String, deviceName: String, staticKey: Data, ephemeralKey: Data) {
        self.version = version; self.deviceID = deviceID; self.deviceName = deviceName; self.staticKey = staticKey; self.ephemeralKey = ephemeralKey
    }
}

public struct ServerHello: Codable, Sendable {
    public var version: UInt16
    public var deviceID: String
    public var deviceName: String
    public var modelIdentifier: String
    public var staticKey: Data
    public var ephemeralKey: Data
    /// True when the host already trusts this client's static key (no prompt needed).
    public var clientIsTrusted: Bool
    public var authMethods: [AuthMethod]
    public init(version: UInt16, deviceID: String, deviceName: String, modelIdentifier: String, staticKey: Data, ephemeralKey: Data, clientIsTrusted: Bool, authMethods: [AuthMethod]) {
        self.version = version; self.deviceID = deviceID; self.deviceName = deviceName; self.modelIdentifier = modelIdentifier
        self.staticKey = staticKey; self.ephemeralKey = ephemeralKey; self.clientIsTrusted = clientIsTrusted; self.authMethods = authMethods
    }
}

public enum AuthMethod: String, Codable, Sendable {
    /// Previously paired device key; the handshake itself proves possession.
    case trustedKey
    /// 6-digit PIN shown on the host.
    case pin
    /// macOS account name + password of the host.
    case password
    /// Host accepts anyone (loopback / explicit opt-in only).
    case none
}

public struct AuthRequest: Codable, Sendable {
    public var method: AuthMethod
    public var pin: String?
    public var username: String?
    public var password: String?
    public init(method: AuthMethod, pin: String? = nil, username: String? = nil, password: String? = nil) {
        self.method = method; self.pin = pin; self.username = username; self.password = password
    }
}

public struct AuthResult: Codable, Sendable {
    public var ok: Bool
    public var reason: String?
    /// Methods the client may retry with.
    public var retryMethods: [AuthMethod]
    public init(ok: Bool, reason: String?, retryMethods: [AuthMethod]) { self.ok = ok; self.reason = reason; self.retryMethods = retryMethods }
}

public enum VideoCodec: String, Codable, Sendable { case hevc, h264 }

public struct DisplayDescriptor: Codable, Sendable, Equatable {
    public var displayID: UInt32
    public var name: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var pointWidth: Double
    public var pointHeight: Double
    public var refreshRate: Double
    public init(displayID: UInt32, name: String, pixelWidth: Int, pixelHeight: Int, pointWidth: Double, pointHeight: Double, refreshRate: Double) {
        self.displayID = displayID; self.name = name; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
        self.pointWidth = pointWidth; self.pointHeight = pointHeight; self.refreshRate = refreshRate
    }
}

/// Host -> client after authentication and whenever the stream geometry changes.
public struct StreamStart: Codable, Sendable {
    public var codec: VideoCodec
    public var display: DisplayDescriptor
    public var displays: [DisplayDescriptor]
    public var encodedWidth: Int
    public var encodedHeight: Int
    public var audio: AudioFormatDescriptor?
    public var hostClockMicros: UInt64
    public init(codec: VideoCodec, display: DisplayDescriptor, displays: [DisplayDescriptor], encodedWidth: Int, encodedHeight: Int, audio: AudioFormatDescriptor?, hostClockMicros: UInt64) {
        self.codec = codec; self.display = display; self.displays = displays; self.encodedWidth = encodedWidth
        self.encodedHeight = encodedHeight; self.audio = audio; self.hostClockMicros = hostClockMicros
    }
}

public struct AudioFormatDescriptor: Codable, Sendable {
    public enum Encoding: String, Codable, Sendable { case pcm16, opus }
    public var encoding: Encoding
    public var sampleRate: Double
    public var channels: Int
    public init(encoding: Encoding, sampleRate: Double, channels: Int) { self.encoding = encoding; self.sampleRate = sampleRate; self.channels = channels }
}

public enum QualityPreset: String, Codable, Sendable, CaseIterable {
    /// Lowest bandwidth for remote links.
    case balanced
    /// LAN default: high bitrate, 60fps.
    case high
    /// Near lossless text and highest frame rate the display allows.
    case ultra
}

/// Client -> host preferences; may be sent at any time to reconfigure.
public struct StreamConfig: Codable, Sendable, Equatable {
    public var displayID: UInt32?
    public var quality: QualityPreset
    public var maxFPS: Int
    /// Requested bitrate in bits/sec, nil = derive from quality preset and resolution.
    public var bitrate: Int?
    public var audioEnabled: Bool
    public var localCursor: Bool
    /// Client's view size in pixels; host may scale the stream down to it.
    public var viewportPixelWidth: Int?
    public var viewportPixelHeight: Int?
    public var codecs: [VideoCodec]
    /// Ask the host to switch its display mode to best fit the client's window (restored afterwards).
    public var matchResolution: Bool?
    public var viewportPointWidth: Double?
    public var viewportPointHeight: Double?
    /// Client window is hidden/minimized: stop sending video (audio continues).
    public var videoPaused: Bool?

    public init(displayID: UInt32? = nil, quality: QualityPreset = .high, maxFPS: Int = 60, bitrate: Int? = nil,
                audioEnabled: Bool = true, localCursor: Bool = true, viewportPixelWidth: Int? = nil,
                viewportPixelHeight: Int? = nil, codecs: [VideoCodec] = [.hevc, .h264]) {
        self.displayID = displayID; self.quality = quality; self.maxFPS = maxFPS; self.bitrate = bitrate
        self.audioEnabled = audioEnabled; self.localCursor = localCursor
        self.viewportPixelWidth = viewportPixelWidth; self.viewportPixelHeight = viewportPixelHeight; self.codecs = codecs
    }
}

public struct ClipboardPayload: Codable, Sendable, Equatable {
    /// UTI -> data, e.g. "public.utf8-plain-text", "public.png", "public.rtf"
    public var items: [String: Data]
    public var changeCount: Int
    public init(items: [String: Data], changeCount: Int) { self.items = items; self.changeCount = changeCount }
}

public struct Goodbye: Codable, Sendable {
    public var reason: String
    public init(reason: String) { self.reason = reason }
}

// MARK: - Binary payloads (hot path)

public struct VideoFrame: Sendable {
    public static let flagKeyframe: UInt8 = 1

    public var frameNumber: UInt32
    /// Host monotonic clock, microseconds, at capture.
    public var captureMicros: UInt64
    public var flags: UInt8
    /// Codec parameter sets (VPS/SPS/PPS) — present on keyframes.
    public var parameterSets: [Data]
    /// Length-prefixed (4 byte) NAL units, AVCC/HVCC style.
    public var data: Data

    public var isKeyframe: Bool { flags & Self.flagKeyframe != 0 }

    public init(frameNumber: UInt32, captureMicros: UInt64, flags: UInt8, parameterSets: [Data], data: Data) {
        self.frameNumber = frameNumber; self.captureMicros = captureMicros; self.flags = flags
        self.parameterSets = parameterSets; self.data = data
    }

    public func encode(into w: inout ByteWriter) {
        w.u32(frameNumber); w.u64(captureMicros); w.u8(flags)
        w.u8(UInt8(parameterSets.count))
        for p in parameterSets { w.blob(p) }
        w.blob(data)
    }

    public static func decode(_ r: inout ByteReader) throws -> VideoFrame {
        let n = try r.u32(); let t = try r.u64(); let f = try r.u8()
        let count = Int(try r.u8())
        var ps: [Data] = []
        for _ in 0..<count { ps.append(try r.blob()) }
        return VideoFrame(frameNumber: n, captureMicros: t, flags: f, parameterSets: ps, data: try r.blob())
    }
}

public struct AudioPacket: Sendable {
    public var captureMicros: UInt64
    public var frames: UInt32
    public var data: Data
    public init(captureMicros: UInt64, frames: UInt32, data: Data) {
        self.captureMicros = captureMicros; self.frames = frames; self.data = data
    }
}

public enum MouseButton: UInt8, Sendable { case left = 0, right = 1, middle = 2, back = 3, forward = 4 }

public enum InputEvent: Sendable, Equatable {
    /// Absolute position, normalized 0...1 within the streamed display.
    case mouseMove(x: Float, y: Float)
    /// Relative motion in points (pointer-lock / games).
    case mouseRelative(dx: Float, dy: Float)
    case mouseButton(button: MouseButton, down: Bool, x: Float, y: Float, clickCount: UInt8)
    /// Pixel deltas with trackpad phases so momentum scrolling feels native.
    case scroll(dx: Float, dy: Float, phase: UInt8, momentumPhase: UInt8, precise: Bool)
    /// macOS virtual key code + CGEventFlags raw value.
    case key(keyCode: UInt16, down: Bool, flags: UInt64)
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    /// Trackpad magnify/rotate/smart-zoom gestures.
    case magnify(amount: Float, phase: UInt8)
    /// Release everything held (focus lost) so the host never gets stuck keys.
    case releaseAll

    public func encode(into w: inout ByteWriter) {
        switch self {
        case let .mouseMove(x, y): w.u8(1); w.f32(x); w.f32(y)
        case let .mouseRelative(dx, dy): w.u8(2); w.f32(dx); w.f32(dy)
        case let .mouseButton(b, down, x, y, c): w.u8(3); w.u8(b.rawValue); w.bool(down); w.f32(x); w.f32(y); w.u8(c)
        case let .scroll(dx, dy, p, m, precise): w.u8(4); w.f32(dx); w.f32(dy); w.u8(p); w.u8(m); w.bool(precise)
        case let .key(k, down, flags): w.u8(5); w.u16(k); w.bool(down); w.u64(flags)
        case let .flagsChanged(k, flags): w.u8(6); w.u16(k); w.u64(flags)
        case let .magnify(a, p): w.u8(7); w.f32(a); w.u8(p)
        case .releaseAll: w.u8(8)
        }
    }

    public static func decode(_ r: inout ByteReader) throws -> InputEvent {
        switch try r.u8() {
        case 1: return .mouseMove(x: try r.f32(), y: try r.f32())
        case 2: return .mouseRelative(dx: try r.f32(), dy: try r.f32())
        case 3:
            guard let b = MouseButton(rawValue: try r.u8()) else { throw WireError.malformed("button") }
            return .mouseButton(button: b, down: try r.bool(), x: try r.f32(), y: try r.f32(), clickCount: try r.u8())
        case 4: return .scroll(dx: try r.f32(), dy: try r.f32(), phase: try r.u8(), momentumPhase: try r.u8(), precise: try r.bool())
        case 5: return .key(keyCode: try r.u16(), down: try r.bool(), flags: try r.u64())
        case 6: return .flagsChanged(keyCode: try r.u16(), flags: try r.u64())
        case 7: return .magnify(amount: try r.f32(), phase: try r.u8())
        case 8: return .releaseAll
        case let t: throw WireError.malformed("input kind \(t)")
        }
    }
}

public struct CursorShape: Sendable {
    /// Stable identifier so the client can cache shapes.
    public var id: UInt32
    public var hotspotX: Float
    public var hotspotY: Float
    /// Size in points.
    public var width: Float
    public var height: Float
    /// PNG (may be @2x); empty when re-using a cached id.
    public var png: Data
    public init(id: UInt32, hotspotX: Float, hotspotY: Float, width: Float, height: Float, png: Data) {
        self.id = id; self.hotspotX = hotspotX; self.hotspotY = hotspotY; self.width = width; self.height = height; self.png = png
    }
}

// MARK: - Envelope

public enum Message: Sendable {
    case clientHello(ClientHello)
    case serverHello(ServerHello)
    case auth(AuthRequest)
    case authResult(AuthResult)
    case streamStart(StreamStart)
    case configure(StreamConfig)
    case video(VideoFrame)
    case audio(AudioPacket)
    case requestKeyframe
    case input(InputEvent)
    case cursorShape(CursorShape)
    /// Normalized position + visibility of the host cursor.
    case cursorPosition(x: Float, y: Float, visible: Bool, shapeID: UInt32)
    case clipboard(ClipboardPayload)
    case ping(id: UInt32, sentMicros: UInt64)
    case pong(id: UInt32, sentMicros: UInt64, peerMicros: UInt64)
    case goodbye(Goodbye)
    /// Drag-and-drop file transfer (client -> host).
    case fileBegin(id: UInt32, name: String, size: UInt64)
    case fileChunk(id: UInt32, data: Data)
    case fileEnd(id: UInt32, cancelled: Bool)

    enum Kind: UInt8 {
        case clientHello = 1, serverHello, auth, authResult, streamStart, configure
        case video = 0x10, audio, requestKeyframe
        case input = 0x20
        case cursorShape = 0x30, cursorPosition
        case clipboard = 0x40
        case ping = 0x50, pong
        case fileBegin = 0x60, fileChunk, fileEnd
        case goodbye = 0x7F
    }

    private static let json: JSONEncoder = {
        let e = JSONEncoder()
        e.dataEncodingStrategy = .base64
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public func encoded() throws -> Data {
        var w = ByteWriter(capacity: 128)
        func js<T: Encodable>(_ k: Kind, _ v: T) throws { w.u8(k.rawValue); w.bytes(try Message.json.encode(v)) }
        switch self {
        case .clientHello(let v): try js(.clientHello, v)
        case .serverHello(let v): try js(.serverHello, v)
        case .auth(let v): try js(.auth, v)
        case .authResult(let v): try js(.authResult, v)
        case .streamStart(let v): try js(.streamStart, v)
        case .configure(let v): try js(.configure, v)
        case .clipboard(let v): try js(.clipboard, v)
        case .goodbye(let v): try js(.goodbye, v)
        case .video(let f):
            w = ByteWriter(capacity: f.data.count + 64)
            w.u8(Kind.video.rawValue); f.encode(into: &w)
        case .audio(let a):
            w.u8(Kind.audio.rawValue); w.u64(a.captureMicros); w.u32(a.frames); w.blob(a.data)
        case .requestKeyframe: w.u8(Kind.requestKeyframe.rawValue)
        case .input(let e): w.u8(Kind.input.rawValue); e.encode(into: &w)
        case .cursorShape(let c):
            w.u8(Kind.cursorShape.rawValue); w.u32(c.id); w.f32(c.hotspotX); w.f32(c.hotspotY)
            w.f32(c.width); w.f32(c.height); w.blob(c.png)
        case let .cursorPosition(x, y, visible, shape):
            w.u8(Kind.cursorPosition.rawValue); w.f32(x); w.f32(y); w.bool(visible); w.u32(shape)
        case let .ping(id, t): w.u8(Kind.ping.rawValue); w.u32(id); w.u64(t)
        case let .pong(id, t, p): w.u8(Kind.pong.rawValue); w.u32(id); w.u64(t); w.u64(p)
        case let .fileBegin(id, name, size): w.u8(Kind.fileBegin.rawValue); w.u32(id); w.string(name); w.u64(size)
        case let .fileChunk(id, data):
            w = ByteWriter(capacity: data.count + 16)
            w.u8(Kind.fileChunk.rawValue); w.u32(id); w.blob(data)
        case let .fileEnd(id, cancelled): w.u8(Kind.fileEnd.rawValue); w.u32(id); w.bool(cancelled)
        }
        return w.data
    }

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dataDecodingStrategy = .base64
        return d
    }()

    public static func decode(_ data: Data) throws -> Message {
        var r = ByteReader(data)
        let raw = try r.u8()
        guard let kind = Kind(rawValue: raw) else { throw WireError.unknownMessage(raw) }
        func js<T: Decodable>(_: T.Type) throws -> T { try jsonDecoder.decode(T.self, from: r.rest()) }
        switch kind {
        case .clientHello: return .clientHello(try js(ClientHello.self))
        case .serverHello: return .serverHello(try js(ServerHello.self))
        case .auth: return .auth(try js(AuthRequest.self))
        case .authResult: return .authResult(try js(AuthResult.self))
        case .streamStart: return .streamStart(try js(StreamStart.self))
        case .configure: return .configure(try js(StreamConfig.self))
        case .clipboard: return .clipboard(try js(ClipboardPayload.self))
        case .goodbye: return .goodbye(try js(Goodbye.self))
        case .video: return .video(try VideoFrame.decode(&r))
        case .audio: return .audio(AudioPacket(captureMicros: try r.u64(), frames: try r.u32(), data: try r.blob()))
        case .requestKeyframe: return .requestKeyframe
        case .input: return .input(try InputEvent.decode(&r))
        case .cursorShape:
            return .cursorShape(CursorShape(id: try r.u32(), hotspotX: try r.f32(), hotspotY: try r.f32(),
                                            width: try r.f32(), height: try r.f32(), png: try r.blob()))
        case .cursorPosition:
            return .cursorPosition(x: try r.f32(), y: try r.f32(), visible: try r.bool(), shapeID: try r.u32())
        case .ping: return .ping(id: try r.u32(), sentMicros: try r.u64())
        case .pong: return .pong(id: try r.u32(), sentMicros: try r.u64(), peerMicros: try r.u64())
        case .fileBegin: return .fileBegin(id: try r.u32(), name: try r.string(), size: try r.u64())
        case .fileChunk: return .fileChunk(id: try r.u32(), data: try r.blob())
        case .fileEnd: return .fileEnd(id: try r.u32(), cancelled: try r.bool())
        }
    }
}

/// Monotonic microsecond clock shared by host and client code.
public enum Clock {
    public static func micros() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000 }
}
