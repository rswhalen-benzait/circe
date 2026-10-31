import CoreVideo
import Foundation

/// IOSurface-backed BGRA framebuffer the decoders write into and a CALayer displays directly.
final class RFBFramebuffer {
    let width: Int
    let height: Int
    let pixelBuffer: CVPixelBuffer
    private(set) var base: UnsafeMutablePointer<UInt32>!
    private(set) var stride = 0 // in pixels

    init?(width: Int, height: Int) {
        self.width = width
        self.height = height
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferCGImageCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let pb else { return nil }
        pixelBuffer = pb
    }

    var surface: IOSurfaceRef? { CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() }

    func lock() {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt32.self)
        stride = CVPixelBufferGetBytesPerRow(pixelBuffer) / 4
    }

    func unlock() { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    @inline(__always) func clip(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (Int, Int, Int, Int)? {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(width, x + w), y1 = min(height, y + h)
        return x1 > x0 && y1 > y0 ? (x0, y0, x1 - x0, y1 - y0) : nil
    }

    func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ color: UInt32) {
        guard let (x, y, w, h) = clip(x, y, w, h) else { return }
        for row in y..<(y + h) {
            (base + row * stride + x).update(repeating: color | 0xFF00_0000, count: w)
        }
    }

    /// Copies little-endian 32bpp pixels (`src` rows are `w` pixels wide).
    func blit(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ src: UnsafeRawBufferPointer, srcBytesPerPixel bpp: Int = 4) {
        for row in 0..<h where y + row >= 0 && y + row < height {
            let dst = base + (y + row) * stride
            let line = src.baseAddress! + row * w * bpp
            for col in 0..<w where x + col >= 0 && x + col < width {
                let p = line + col * bpp
                let v: UInt32 = bpp == 4 ? p.loadUnaligned(as: UInt32.self).littleEndian
                    : UInt32(p.load(as: UInt8.self)) | UInt32(p.load(fromByteOffset: 1, as: UInt8.self)) << 8
                        | UInt32(p.load(fromByteOffset: 2, as: UInt8.self)) << 16
                dst[x + col] = v | 0xFF00_0000
            }
        }
    }

    func copyRect(from sx: Int, _ sy: Int, to dx: Int, _ dy: Int, _ w: Int, _ h: Int) {
        guard let (cx, cy, cw, ch) = clip(dx, dy, w, h), clip(sx, sy, w, h) != nil else { return }
        let ox = sx - dx, oy = sy - dy
        let rows = Array(cy..<(cy + ch))
        for row in (oy < 0 ? rows : rows.reversed()).reversed() where row + oy >= 0 && row + oy < height {
            let src = base + (row + oy) * stride + cx + ox
            (base + row * stride + cx).update(from: src, count: cw)
        }
    }
}

/// Little cursor sink (VNC "Cursor" pseudo-encoding) → BGRA + alpha.
struct RFBCursor {
    var width: Int
    var height: Int
    var hotX: Int
    var hotY: Int
    var rgba: Data
}
