import CirceCore
import Foundation

/// Splits the remote encoder's FLV byte stream into H.264 frames.
///
/// FLV because every ffmpeg build has it and each tag carries its own length: a frame is usable the
/// moment its last byte arrives (raw Annex-B can only be split when the *next* frame starts, which
/// would add a frame of latency and stall the final frame of every still screen). Its NAL units are
/// already 4-byte length-prefixed, which is what VideoToolbox wants.
struct FLVDemuxer {
    enum Output: Equatable {
        /// SPS and PPS from the AVCDecoderConfigurationRecord.
        case config([Data])
        /// AVCC sample; `millis` is the encoder timestamp.
        case frame(keyframe: Bool, millis: UInt32, data: Data)
    }

    enum Failure: Error, Equatable { case notFLV, unsupportedCodec(Int), badConfig }

    private var buffer = Data()
    private var headerDone = false
    private var lengthSize = 4
    /// Safety net: no single FLV tag is ever this large for a desktop stream.
    static let maxTag = 12 << 20

    mutating func feed(_ chunk: Data) throws -> [Output] {
        buffer.append(chunk)
        var out: [Output] = []
        var p = buffer.startIndex
        func u8(_ i: Int) -> Int { Int(buffer[p + i]) }
        func u24(_ i: Int) -> Int { u8(i) << 16 | u8(i + 1) << 8 | u8(i + 2) }
        if !headerDone {
            guard buffer.count >= 13 else { return out } // 9-byte header + PreviousTagSize0
            guard u8(0) == 0x46, u8(1) == 0x4C, u8(2) == 0x56 else { throw Failure.notFLV }
            let headerSize = Int(buffer[p + 5]) << 24 | u24(6)
            guard headerSize >= 9, headerSize < 64 else { throw Failure.notFLV }
            guard buffer.count >= headerSize + 4 else { return out }
            p += headerSize + 4
            headerDone = true
        }
        while buffer.endIndex - p >= 11 {
            let type = u8(0) & 0x1F
            let size = u24(1)
            let millis = UInt32(u8(7)) << 24 | UInt32(u24(4))
            guard size <= Self.maxTag else { throw Failure.notFLV }
            guard buffer.endIndex - p >= 11 + size + 4 else { break }
            if type == 9, size >= 5 {
                let body = buffer[(p + 11)..<(p + 11 + size)]
                if let o = try video(body, millis: millis) { out.append(o) }
            }
            p += 11 + size + 4
        }
        buffer = Data(buffer[p...])
        return out
    }

    private mutating func video(_ body: Data, millis: UInt32) throws -> Output? {
        let b = Array(body.prefix(5))
        let codec = Int(b[0] & 0x0F), frameType = Int(b[0] >> 4)
        guard codec == 7 else { throw Failure.unsupportedCodec(codec) }
        let payload = body.dropFirst(5)
        switch b[1] {
        case 0:
            let (sets, len) = try Self.parseConfig(Data(payload))
            lengthSize = len
            return .config(sets)
        case 1:
            guard !payload.isEmpty else { return nil }
            let data = lengthSize == 4 ? Data(payload) : try Self.normalize(Data(payload), from: lengthSize)
            return .frame(keyframe: frameType == 1, millis: millis, data: data)
        default:
            return nil // end of sequence
        }
    }

    /// AVCDecoderConfigurationRecord → [SPS…, PPS…] and the NAL length size.
    static func parseConfig(_ d: Data) throws -> ([Data], Int) {
        let b = [UInt8](d)
        guard b.count >= 7, b[0] == 1 else { throw Failure.badConfig }
        let lengthSize = Int(b[4] & 3) + 1
        var i = 5
        var sets: [Data] = []
        for pass in 0..<2 {
            guard i < b.count else { throw Failure.badConfig }
            let count = pass == 0 ? Int(b[i] & 0x1F) : Int(b[i])
            i += 1
            for _ in 0..<count {
                guard i + 2 <= b.count else { throw Failure.badConfig }
                let n = Int(b[i]) << 8 | Int(b[i + 1])
                i += 2
                guard i + n <= b.count, n > 0 else { throw Failure.badConfig }
                sets.append(Data(b[i..<(i + n)]))
                i += n
            }
        }
        guard sets.count >= 2 else { throw Failure.badConfig }
        return (sets, lengthSize)
    }

    /// Rewrites 1/2/3-byte NAL lengths as 4-byte ones.
    static func normalize(_ d: Data, from size: Int) throws -> Data {
        let b = [UInt8](d)
        var out = Data(capacity: b.count + b.count / 64)
        var i = 0
        while i < b.count {
            guard i + size <= b.count else { throw Failure.badConfig }
            var n = 0
            for k in 0..<size { n = n << 8 | Int(b[i + k]) }
            i += size
            guard i + n <= b.count else { throw Failure.badConfig }
            out += be32(UInt32(n))
            out += b[i..<(i + n)]
            i += n
        }
        return out
    }

    private static func be32(_ v: UInt32) -> Data { Data([UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]) }
}

/// Turns demuxed FLV into the `VideoFrame`s Circe's hardware renderer already plays.
struct LinuxVideoFramer {
    private var demux = FLVDemuxer()
    private var sets: [Data] = []
    private var frameNumber: UInt32 = 0
    private var origin: UInt64?

    mutating func feed(_ chunk: Data) throws -> [VideoFrame] {
        var frames: [VideoFrame] = []
        for o in try demux.feed(chunk) {
            switch o {
            case .config(let s):
                sets = s
            case let .frame(key, millis, data):
                guard !sets.isEmpty else { continue }
                frameNumber &+= 1
                // Present immediately on arrival; the encoder clock only orders samples.
                let base = origin ?? Clock.micros() - UInt64(millis) * 1000
                origin = base
                frames.append(VideoFrame(frameNumber: frameNumber, captureMicros: base + UInt64(millis) * 1000,
                                         flags: key ? VideoFrame.flagKeyframe : 0,
                                         parameterSets: key ? sets : [], data: data))
            }
        }
        return frames
    }
}
