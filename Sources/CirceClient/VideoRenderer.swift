import AVFoundation
import CirceCore
import CoreMedia
import Foundation

/// Hardware decode + display through AVSampleBufferDisplayLayer, presenting each frame immediately.
final class VideoRenderer {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?
    private var codec: VideoCodec = .hevc
    private var awaitingKeyframe = true

    /// Called when the decoder needs a fresh keyframe (startup, error, missing parameter sets).
    var onNeedKeyframe: (() -> Void)?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        // Pixel-exact presentation: no smoothing when the stream matches the view's backing size.
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .trilinear
    }

    private var renderer: AVSampleBufferVideoRenderer { layer.sampleBufferRenderer }

    func reset(codec: VideoCodec) {
        self.codec = codec
        format = nil
        awaitingKeyframe = true
        renderer.flush()
    }

    func flush() {
        renderer.flush(removingDisplayedImage: true, completionHandler: nil)
        awaitingKeyframe = true
    }

    func display(_ frame: VideoFrame) {
        if frame.isKeyframe, !frame.parameterSets.isEmpty {
            format = makeFormat(frame.parameterSets)
            awaitingKeyframe = false
        }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            awaitingKeyframe = true
        }
        guard !awaitingKeyframe, let format else { onNeedKeyframe?(); return }
        guard let sample = makeSample(frame, format: format) else { return }
        renderer.enqueue(sample)
    }

    private func makeFormat(_ sets: [Data]) -> CMVideoFormatDescription? {
        var fmt: CMVideoFormatDescription?
        let bufs = sets.map { d -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: d.count)
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { bufs.forEach { $0.deallocate() } }
        let ptrs = bufs.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)
        let status: OSStatus
        if codec == .hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                        parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                        nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: sets.count,
                                                                        parameterSetPointers: ptrs, parameterSetSizes: sizes,
                                                                        nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        }
        return status == noErr ? fmt : nil
    }

    private func makeSample(_ frame: VideoFrame, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let len = frame.data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: len, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: len, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        frame.data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: len) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(frame.captureMicros), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = len
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !frame.isKeyframe {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }
}
