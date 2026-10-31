import AppKit
import ApplicationServices
import CirceCore
import CoreMedia
import CryptoKit
import Foundation
import OpenDirectory

// MARK: - Audio

enum AudioPacketizer {
    static let format = AudioFormatDescriptor(encoding: .pcm16, sampleRate: 48_000, channels: 2)

    /// Converts a ScreenCaptureKit float PCM sample buffer to interleaved little-endian Int16 stereo.
    static func packet(from sb: CMSampleBuffer, captureMicros: UInt64) -> AudioPacket? {
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
        guard isFloat, asbd.mBitsPerChannel == 32, frames > 0 else { return nil }

        var out = Data(count: frames * 2 * MemoryLayout<Int16>.size)
        out.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            func sample(_ ch: Int, _ i: Int) -> Float {
                if nonInterleaved {
                    let b = buffers[min(ch, buffers.count - 1)]
                    return b.mData!.assumingMemoryBound(to: Float.self)[i]
                }
                let chans = Int(asbd.mChannelsPerFrame)
                return buffers[0].mData!.assumingMemoryBound(to: Float.self)[i * chans + min(ch, chans - 1)]
            }
            for i in 0..<frames {
                for ch in 0..<2 {
                    let v = max(-1, min(1, sample(ch, i)))
                    dst[i * 2 + ch] = Int16(v * 32_767).littleEndian
                }
            }
        }
        return AudioPacket(captureMicros: captureMicros, frames: UInt32(frames), data: out)
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
        let id: UInt32
        var png = Data()
        if let known = ids[hash] {
            id = known
        } else {
            id = nextID; nextID += 1; ids[hash] = id
            if let rep = NSBitmapImageRep(data: tiff) { png = rep.representation(using: .png, properties: [:]) ?? Data() }
        }
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
