import AVFoundation
import Foundation

/// 48 kHz stereo Opus in 10 ms packets via AudioToolbox (~128 kbps instead of 1.5 Mbps PCM).
public enum OpusFormat {
    public static let sampleRate = 48_000.0
    public static let channels: AVAudioChannelCount = 2
    public static let framesPerPacket: AVAudioFrameCount = 480

    static let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!

    static let opus: AVAudioFormat = {
        var d = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                            mBytesPerPacket: 0, mFramesPerPacket: framesPerPacket, mBytesPerFrame: 0,
                                            mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &d)!
    }()
}

public final class OpusEncoder {
    private let converter: AVAudioConverter
    private var pending: [Float] = []

    public init?(bitrate: Int = 128_000) {
        guard let c = AVAudioConverter(from: OpusFormat.pcm, to: OpusFormat.opus) else { return nil }
        c.bitRate = bitrate
        converter = c
    }

    /// Interleaved stereo float samples in; zero or more complete Opus packets out.
    public func encode(interleaved samples: [Float]) -> [Data] {
        pending.append(contentsOf: samples)
        let n = Int(OpusFormat.framesPerPacket)
        var packets: [Data] = []
        while pending.count >= n * 2 {
            guard let input = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: OpusFormat.framesPerPacket) else { break }
            input.frameLength = OpusFormat.framesPerPacket
            let l = input.floatChannelData![0], r = input.floatChannelData![1]
            pending.withUnsafeBufferPointer { p in
                for i in 0..<n { l[i] = p[i * 2]; r[i] = p[i * 2 + 1] }
            }
            pending.removeFirst(n * 2)
            let out = AVAudioCompressedBuffer(format: OpusFormat.opus, packetCapacity: 1,
                                              maximumPacketSize: max(converter.maximumOutputPacketSize, 1500))
            var fed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if fed { outStatus.pointee = .noDataNow; return nil }
                fed = true
                outStatus.pointee = .haveData
                return input
            }
            if status != .error, out.byteLength > 0 {
                packets.append(Data(bytes: out.data, count: Int(out.byteLength)))
            }
        }
        return packets
    }
}

public final class OpusDecoder {
    private let converter: AVAudioConverter

    public init?() {
        guard let c = AVAudioConverter(from: OpusFormat.opus, to: OpusFormat.pcm) else { return nil }
        converter = c
    }

    /// One Opus packet in; interleaved stereo floats out.
    public func decode(_ packet: Data) -> [Float]? {
        let input = AVAudioCompressedBuffer(format: OpusFormat.opus, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { input.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                         mDataByteSize: UInt32(packet.count))
        guard let out = AVAudioPCMBuffer(pcmFormat: OpusFormat.pcm, frameCapacity: OpusFormat.framesPerPacket * 2) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        let n = Int(out.frameLength)
        let l = out.floatChannelData![0], r = out.floatChannelData![1]
        var result = [Float](repeating: 0, count: n * 2)
        for i in 0..<n { result[i * 2] = l[i]; result[i * 2 + 1] = r[i] }
        return result
    }
}
