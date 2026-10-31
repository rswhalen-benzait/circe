import CirceCore
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures one display (video + system audio) with ScreenCaptureKit.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Options {
        var displayID: CGDirectDisplayID?
        var fps: Int
        var showsCursor: Bool
        var captureAudio: Bool
        /// Max encoded size; stream is downscaled proportionally to fit.
        var maxPixelWidth: Int?
        var maxPixelHeight: Int?
    }

    private(set) var display: DisplayDescriptor?
    private(set) var encodedSize: (width: Int, height: Int) = (0, 0)
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "circe.capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "circe.capture.audio", qos: .userInteractive)

    var onVideo: ((CVPixelBuffer, UInt64) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onStop: ((Error?) -> Void)?

    static func displays() async throws -> [DisplayDescriptor] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays.map(describe)
    }

    static func describe(_ d: SCDisplay) -> DisplayDescriptor {
        let mode = CGDisplayCopyDisplayMode(d.displayID)
        let pw = mode?.pixelWidth ?? d.width
        let ph = mode?.pixelHeight ?? d.height
        let rate = mode?.refreshRate ?? 60
        return DisplayDescriptor(displayID: d.displayID, name: displayName(d.displayID),
                                 pixelWidth: pw, pixelHeight: ph,
                                 pointWidth: Double(d.width), pointHeight: Double(d.height),
                                 refreshRate: rate > 0 ? rate : 60)
    }

    static func displayName(_ id: CGDirectDisplayID) -> String {
        if CGDisplayIsBuiltin(id) != 0 { return "Built-in Display" }
        for screen in NSScreenList.screens where screen.id == id { return screen.name }
        return "Display \(id)"
    }

    func start(_ options: Options) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == options.displayID })
                ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw WireError.protocolViolation("no displays available")
        }
        let desc = Self.describe(scDisplay)
        display = desc

        var w = desc.pixelWidth, h = desc.pixelHeight
        if let mw = options.maxPixelWidth, let mh = options.maxPixelHeight, mw > 0, mh > 0, w > mw || h > mh {
            let s = min(Double(mw) / Double(w), Double(mh) / Double(h))
            w = Int(Double(w) * s); h = Int(Double(h) * s)
        }
        w &= ~1; h &= ~1
        encodedSize = (w, h)

        let config = SCStreamConfiguration()
        config.width = w
        config.height = h
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(options.fps, 1)))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.queueDepth = 4
        config.showsCursor = options.showsCursor
        config.scalesToFit = true
        config.capturesAudio = options.captureAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if options.captureAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .screen:
            guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = atts.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let pb = sb.imageBuffer else { return }
            onVideo?(pb, Clock.micros())
        case .audio:
            onAudio?(sb)
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}

/// Thin wrapper so this file doesn't need AppKit's main-actor NSScreen at call sites.
enum NSScreenList {
    struct Screen { let id: CGDirectDisplayID; let name: String }
    static var screens: [Screen] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).map { Screen(id: $0, name: "Display \($0)") }
    }
}
