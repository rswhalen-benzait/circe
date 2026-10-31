import AppKit
import ApplicationServices
import CirceCore
import CoreMedia
import CryptoKit
import Foundation
import OpenDirectory

// MARK: - Audio

/// Turns ScreenCaptureKit audio into Opus packets (PCM16 fallback if no Opus encoder).
final class AudioPacketizer {
    private let opus = OpusEncoder()

    var format: AudioFormatDescriptor {
        AudioFormatDescriptor(encoding: opus != nil ? .opus : .pcm16, sampleRate: 48_000, channels: 2)
    }

    func packets(from sb: CMSampleBuffer, captureMicros: UInt64) -> [AudioPacket] {
        guard let samples = Self.interleavedFloats(sb), !samples.isEmpty else { return [] }
        if let opus {
            return opus.encode(interleaved: samples).map {
                AudioPacket(captureMicros: captureMicros, frames: OpusFormat.framesPerPacket, data: $0)
            }
        }
        var out = Data(count: samples.count * 2)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            for i in 0..<samples.count { dst[i] = Int16(max(-1, min(1, samples[i])) * 32_767).littleEndian }
        }
        return [AudioPacket(captureMicros: captureMicros, frames: UInt32(samples.count / 2), data: out)]
    }

    /// ScreenCaptureKit float PCM (usually non-interleaved) -> interleaved stereo floats.
    static func interleavedFloats(_ sb: CMSampleBuffer) -> [Float]? {
        guard let fmt = sb.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return nil }
        var blockBuffer: CMBlockBuffer?
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil,
                                                                bufferListSize: 0, blockBufferAllocator: nil,
                                                                blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let listPtr = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16)
        defer { listPtr.deallocate() }
        let abl = listPtr.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer) == noErr else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(abl)
        let frames = CMSampleBufferGetNumSamples(sb)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard isFloat, asbd.mBitsPerChannel == 32, frames > 0, buffers.count > 0 else { return nil }
        var out = [Float](repeating: 0, count: frames * 2)
        if nonInterleaved {
            let l = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            let r = buffers[min(1, buffers.count - 1)].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { out[i * 2] = l[i]; out[i * 2 + 1] = r[i] }
        } else {
            let chans = Int(asbd.mChannelsPerFrame)
            let p = buffers[0].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<frames { out[i * 2] = p[i * chans]; out[i * 2 + 1] = p[i * chans + min(1, chans - 1)] }
        }
        return out
    }
}

// MARK: - Cursor

/// Watches the system cursor image so the client can render the cursor locally with zero latency.
@MainActor
final class CursorMonitor {
    private var timer: Timer?
    private var lastHash: Data?
    private var ids: [Data: UInt32] = [:]
    private var nextID: UInt32 = 1
    private var pngs: [UInt32: Data] = [:]
    var onShape: ((CursorShape) -> Void)?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func stop() { timer?.invalidate(); timer = nil }

    func resend() { lastHash = nil; poll() }

    private func poll() {
        guard let cursor = NSCursor.currentSystem ?? Optional(NSCursor.current) else { return }
        let image = cursor.image
        guard let tiff = image.tiffRepresentation else { return }
        let hash = Data(SHA256.hash(data: tiff))
        guard hash != lastHash else { return }
        lastHash = hash
        // Always ship the full image: clients join at different times and can't share our cache.
        // Cursor changes are rare and images are small (~10 KB).
        let id: UInt32
        if let known = ids[hash] { id = known } else { id = nextID; nextID += 1; ids[hash] = id }
        let png = pngs[id] ?? (NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) ?? Data())
        pngs[id] = png
        onShape?(CursorShape(id: id, hotspotX: Float(cursor.hotSpot.x), hotspotY: Float(cursor.hotSpot.y),
                             width: Float(image.size.width), height: Float(image.size.height), png: png))
    }
}

// MARK: - Permissions

/// Host-side permission state and deep links into System Settings.
public enum Permissions {
    public static var screenRecording: Bool { CGPreflightScreenCaptureAccess() }
    public static var accessibility: Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    @discardableResult
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    public static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    public static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - Account password verification

enum AccountVerifier {
    /// Verifies a local macOS account password via OpenDirectory (same credentials as Screen Sharing).
    static func verify(username: String, password: String) -> Bool {
        guard !username.isEmpty, !password.isEmpty else { return false }
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: username, attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - File transfer

/// Receives dropped files into ~/Downloads on the host, then reveals them.
final class FileReceiver {
    private var files: [UInt32: (handle: FileHandle, url: URL, expected: UInt64, written: UInt64)] = [:]
    private let maxFiles = 64
    /// Test hook: receive into this directory and don't reveal in Finder.
    static let overrideDirectory = ProcessInfo.processInfo.environment["CIRCE_RECEIVE_DIR"].map { URL(fileURLWithPath: $0) }

    func begin(id: UInt32, name: String, size: UInt64) {
        guard files.count < maxFiles else { return }
        // Never trust a remote path: keep only the last component and strip leading dots.
        var safe = (name as NSString).lastPathComponent.replacingOccurrences(of: "/", with: "_")
        while safe.hasPrefix(".") { safe.removeFirst() }
        if safe.isEmpty { safe = "Received file" }
        let dir = Self.overrideDirectory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let first = dir.appendingPathComponent(safe)
        let base = first.deletingPathExtension().lastPathComponent, ext = first.pathExtension
        // O_EXCL makes "pick a free name" atomic, even with several sessions dropping the same file name.
        var url = first
        var fd: Int32 = -1
        for n in 1...10_000 {
            if n > 1 { url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)") }
            fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 || errno != EEXIST { break }
        }
        guard fd >= 0 else { return }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        files[id] = (h, url, size, 0)
    }

    func chunk(id: UInt32, data: Data) {
        guard var f = files[id] else { return }
        f.written += UInt64(data.count)
        guard f.written <= f.expected else { end(id: id, cancelled: true); return }
        try? f.handle.write(contentsOf: data)
        files[id] = f
    }

    func end(id: UInt32, cancelled: Bool) {
        guard let f = files.removeValue(forKey: id) else { return }
        try? f.handle.close()
        if cancelled || f.written != f.expected {
            try? FileManager.default.removeItem(at: f.url)
        } else if Self.overrideDirectory == nil {
            let url = f.url
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    func cancelAll() { for id in Array(files.keys) { end(id: id, cancelled: true) } }
}
