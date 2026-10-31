import Foundation

/// Splits an Ogg stream into its packets (for Opus from the Linux audio helper: ~128 kb/s instead of
/// 1.5 Mb/s of raw PCM on the same SSH/IAP link as the video).
struct OggDemuxer {
    enum Failure: Error, Equatable { case notOgg }

    private var buffer = Data()
    private var partial = Data()
    /// Packets so far, including the OpusHead / OpusTags headers.
    private(set) var packetCount = 0

    mutating func feed(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var out: [Data] = []
        var p = buffer.startIndex
        while buffer.endIndex - p >= 27 {
            guard buffer[p] == 0x4F, buffer[p + 1] == 0x67, buffer[p + 2] == 0x67, buffer[p + 3] == 0x53 else { throw Failure.notOgg }
            let segments = Int(buffer[p + 26])
            guard buffer.endIndex - p >= 27 + segments else { break }
            let table = buffer[(p + 27)..<(p + 27 + segments)]
            let bodySize = table.reduce(0) { $0 + Int($1) }
            guard buffer.endIndex - p >= 27 + segments + bodySize else { break }
            var q = p + 27 + segments
            if buffer[p + 5] & 1 == 0 { partial.removeAll() } // not a continuation: drop any orphan
            for lace in table {
                partial += buffer[q..<(q + Int(lace))]
                q += Int(lace)
                if lace < 255 { // a packet ends here
                    out.append(partial)
                    packetCount += 1
                    partial = Data()
                }
            }
            p = q
        }
        buffer = Data(buffer[p...])
        return out
    }
}

/// Remote audio arrives either as raw PCM (`parec`) or Ogg/Opus (Circe's audio helper); the first
/// bytes tell which.
struct RemoteAudioStream {
    enum Kind: Equatable { case unknown, pcm, opus }
    private(set) var kind = Kind.unknown
    private var head = Data()
    private var ogg = OggDemuxer()
    private var carry = Data()

    /// Returns audio payloads for `AudioPlayer`: whole-frame PCM chunks, or single Opus packets.
    mutating func feed(_ chunk: Data) throws -> [Data] {
        var data = chunk
        if kind == .unknown {
            head += chunk
            guard head.count >= 4 else { return [] }
            kind = head.prefix(4) == Data("OggS".utf8) ? .opus : .pcm
            data = head
            head = Data()
        }
        switch kind {
        case .opus:
            // Skip the two Ogg Opus header packets (OpusHead, OpusTags).
            let before = ogg.packetCount
            let packets = try ogg.feed(data)
            return Array(packets.dropFirst(max(0, 2 - before)))
        default:
            carry += data
            let usable = carry.count - carry.count % 4 // whole s16le stereo frames only
            guard usable > 0 else { return [] }
            let out = Data(carry.prefix(usable))
            carry = Data(carry.dropFirst(usable))
            return [out]
        }
    }
}
