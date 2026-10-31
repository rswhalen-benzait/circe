import CirceCore
import CoreMedia
import Foundation
import VideoToolbox

/// Hardware low-latency encoder: no B-frames, realtime, keyframes only on demand.
final class VideoEncoder: @unchecked Sendable {
    let codec: VideoCodec
    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    private var frameNumber: UInt32 = 0
    private var forceKeyframe = true
    private let lock = NSLock()

    /// Called on an encoder-owned thread for every encoded frame.
    var onFrame: ((VideoFrame) -> Void)?

    init?(width: Int, height: Int, fps: Int, bitrate: Int, preferred: [VideoCodec]) {
        self.width = width
        self.height = height
        var chosen: (VTCompressionSession, VideoCodec)?
        for codec in preferred {
            if let s = Self.makeSession(codec: codec, width: width, height: height, lowLatency: true)
                ?? Self.makeSession(codec: codec, width: width, height: height, lowLatency: false) {
                chosen = (s, codec); break
            }
        }
        guard let (s, c) = chosen else { return nil }
        session = s
        codec = c
        configure(fps: fps, bitrate: bitrate)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    private static func makeSession(codec: VideoCodec, width: Int, height: Int, lowLatency: Bool) -> VTCompressionSession? {
        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
        var s: VTCompressionSession?
        let type = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                                codecType: type, encoderSpecification: spec as CFDictionary,
                                                imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        return status == noErr ? s : nil
    }

    private func set(_ key: CFString, _ value: Any) {
        guard let session else { return }
        VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
    }

    private func configure(fps: Int, bitrate: Int) {
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        // Keyframes only when asked (new client, loss, decoder reset). Long GOP keeps bitrate for detail.
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, Int32.max)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 3600)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        // Tag colour explicitly so the client renders exactly what the host shows.
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        setBitrate(bitrate)
    }

    func setBitrate(_ bitrate: Int) {
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        // Cap bursts at ~1.5x average over 1s so a scene change can't flood the link.
        set(kVTCompressionPropertyKey_DataRateLimits, [Double(bitrate) * 1.5 / 8, 1.0] as CFArray)
    }

    func requestKeyframe() { lock.withLock { forceKeyframe = true } }

    func encode(_ pixelBuffer: CVPixelBuffer, captureMicros: UInt64) {
        guard let session else { return }
        let key = lock.withLock { () -> Bool in let k = forceKeyframe; forceKeyframe = false; return k }
        let props: CFDictionary? = key ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        let pts = CMTime(value: CMTimeValue(captureMicros), timescale: 1_000_000)
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { [weak self] status, _, sample in
            guard let self, status == noErr, let sample else {
                if status != noErr { self?.requestKeyframe() }
                return
            }
            self.emit(sample, captureMicros: captureMicros)
        }
    }

    private func emit(_ sample: CMSampleBuffer, captureMicros: UInt64) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        var params: [Data] = []
        if isKey, let fmt = CMSampleBufferGetFormatDescription(sample) {
            params = Self.parameterSets(fmt, codec: codec)
        }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
                                          dataPointerOut: &ptr) == noErr, let ptr else { return }
        let data: Data
        if CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: length) {
            data = Data(bytes: ptr, count: length)
        } else {
            var d = Data(count: length)
            d.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            data = d
        }
        let n = lock.withLock { () -> UInt32 in frameNumber &+= 1; return frameNumber }
        onFrame?(VideoFrame(frameNumber: n, captureMicros: captureMicros,
                            flags: isKey ? VideoFrame.flagKeyframe : 0, parameterSets: params, data: data))
    }

    static func parameterSets(_ fmt: CMFormatDescription, codec: VideoCodec) -> [Data] {
        var count = 0
        if codec == .hevc {
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        var out: [Data] = []
        for i in 0..<count {
            var p: UnsafePointer<UInt8>?
            var size = 0
            let st = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if st == noErr, let p { out.append(Data(bytes: p, count: size)) }
        }
        return out
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit { invalidate() }
}

/// Bitrate heuristics: bits per pixel per frame tuned for screen content.
func defaultBitrate(width: Int, height: Int, fps: Int, quality: QualityPreset) -> Int {
    let bpp: Double
    switch quality {
    case .balanced: bpp = 0.05
    case .high: bpp = 0.10
    case .ultra: bpp = 0.20
    }
    let raw = Double(width * height) * Double(min(fps, 60)) * bpp
    return Int(min(max(raw, 4_000_000), 150_000_000))
}
