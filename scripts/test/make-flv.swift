// Writes a short H.264 FLV (what Circe's Linux video helper streams) using VideoToolbox.
// usage: swift scripts/test/make-flv.swift OUT.flv [frames] [WxH]
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "test.flv"
let count = args.count > 2 ? Int(args[2])! : 120
let dims = (args.count > 3 ? args[3] : "320x240").split(separator: "x").map { Int($0)! }
let (w, h) = (dims[0], dims[1])

var flv = Data([0x46, 0x4C, 0x56, 1, 1, 0, 0, 0, 9, 0, 0, 0, 0])
func tag(_ body: Data, millis: UInt32) {
    let n = body.count
    flv += [9, UInt8(n >> 16), UInt8(n >> 8 & 255), UInt8(n & 255),
            UInt8(millis >> 16 & 255), UInt8(millis >> 8 & 255), UInt8(millis & 255), UInt8(millis >> 24), 0, 0, 0]
    flv += body
    let total = UInt32(11 + n)
    flv += [UInt8(total >> 24), UInt8(total >> 16 & 255), UInt8(total >> 8 & 255), UInt8(total & 255)]
}

var session: VTCompressionSession?
guard VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                 encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                 outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr, let session else {
    fatalError("no H.264 encoder")
}
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)
var wroteConfig = false
let lock = NSLock()

for i in 0..<count {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt32.self)
    let stride = CVPixelBufferGetBytesPerRow(pb!) / 4
    for y in 0..<h { for x in 0..<w {
        // Blue background with a moving white bar: obvious motion, easy to check by eye.
        base[y * stride + x] = (x + i * 4) % w < 24 ? 0xFFFF_FFFF : 0xFFFF_0000
    } }
    CVPixelBufferUnlockBaseAddress(pb!, [])
    let millis = UInt32(i * 1000 / 60)
    VTCompressionSessionEncodeFrame(session, imageBuffer: pb!, presentationTimeStamp: CMTime(value: CMTimeValue(millis), timescale: 1000),
                                    duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
        guard status == noErr, let sample, let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
        lock.lock(); defer { lock.unlock() }
        if !wroteConfig,
           let atoms = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
           let avcC = atoms["avcC"] as? Data {
            tag(Data([0x17, 0, 0, 0, 0]) + avcC, millis: 0)
            wroteConfig = true
        }
        let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(atts?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        var len = 0
        var ptr: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(CMSampleBufferGetDataBuffer(sample)!, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
        tag(Data([key ? 0x17 : 0x27, 1, 0, 0, 0]) + Data(bytes: ptr!, count: len), millis: millis)
    }
    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
}
try! flv.write(to: URL(fileURLWithPath: out))
print("wrote \(out): \(count) frames, \(flv.count) bytes")
