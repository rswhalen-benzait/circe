import AVFoundation
import CirceCore
import Foundation

/// Low-latency PCM playback with a small adaptive jitter buffer (~30 ms target).
final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private let lock = NSLock()
    private var ring: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var buffered = 0
    private var primed = false
    private let channels = 2
    private let sampleRate: Double
    private let targetFrames: Int
    private let maxFrames: Int

    init(format: AudioFormatDescriptor) {
        sampleRate = format.sampleRate
        targetFrames = Int(format.sampleRate * 0.030)
        maxFrames = Int(format.sampleRate * 0.120)
        ring = [Float](repeating: 0, count: Int(format.sampleRate) * 2 * 2)
        encoding = format.encoding
        opus = format.encoding == .opus ? OpusDecoder() : nil
    }

    func start() {
        guard source == nil,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels)) else { return }
        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, abl in
            self?.render(Int(frameCount), UnsafeMutableAudioBufferListPointer(abl))
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        engine.prepare()
        try? engine.start()
    }

    func stop() {
        engine.stop()
        if let source { engine.detach(source) }
        source = nil
    }

    func setMuted(_ muted: Bool) { engine.mainMixerNode.outputVolume = muted ? 0 : 1 }

    private let opus: OpusDecoder?
    private let encoding: AudioFormatDescriptor.Encoding

    func enqueue(_ packet: AudioPacket) {
        if encoding == .opus {
            if let samples = opus?.decode(packet.data) { enqueue(interleaved: samples) }
            return
        }
        // Interleaved little-endian Int16 stereo.
        let samples = packet.data.withUnsafeBytes { raw -> [Float] in
            raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
        }
        enqueue(interleaved: samples)
    }

    private func enqueue(interleaved samples: [Float]) {
        let frames = samples.count / channels
        lock.lock()
        defer { lock.unlock() }
        let cap = ring.count
        for v in samples {
            ring[writeIndex] = v
            writeIndex = (writeIndex + 1) % cap
        }
        buffered += frames
        // Too much latency accumulated (e.g. after a network hiccup): skip ahead to the target.
        if buffered > maxFrames {
            let drop = buffered - targetFrames
            readIndex = (readIndex + drop * channels) % ring.count
            buffered = targetFrames
        }
        if !primed && buffered >= targetFrames { primed = true }
    }

    private func render(_ frames: Int, _ abl: UnsafeMutableAudioBufferListPointer) {
        lock.lock()
        defer { lock.unlock() }
        let available = primed ? min(frames, buffered) : 0
        let outs = abl.map { $0.mData!.assumingMemoryBound(to: Float.self) }
        for i in 0..<frames {
            for ch in 0..<min(channels, outs.count) {
                if i < available {
                    outs[ch][i] = ring[(readIndex + i * channels + ch) % ring.count]
                } else {
                    outs[ch][i] = 0
                }
            }
        }
        readIndex = (readIndex + available * channels) % ring.count
        buffered -= available
        if buffered == 0 { primed = false }
    }
}
