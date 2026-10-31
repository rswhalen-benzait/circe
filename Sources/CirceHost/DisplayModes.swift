import CoreGraphics
import Foundation

/// Switches a host display to the mode that best matches the client's window, and restores it after.
/// Uses session-scoped configuration so macOS reverts automatically if Circe quits unexpectedly.
final class DisplayModeMatcher {
    private var original: [CGDirectDisplayID: CGDisplayMode] = [:]

    /// Picks the closest mode by point size, preferring HiDPI and the current refresh rate.
    static func bestMode(for display: CGDirectDisplayID, pointWidth: Double, pointHeight: Double) -> CGDisplayMode? {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode], !modes.isEmpty else { return nil }
        let current = CGDisplayCopyDisplayMode(display)
        let targetAspect = pointWidth / max(pointHeight, 1)
        func score(_ m: CGDisplayMode) -> Double {
            let w = Double(m.width), h = Double(m.height)
            // Never exceed the window (avoids scaling text down); prefer matching aspect, then size.
            let overflow = max(0, w - pointWidth) + max(0, h - pointHeight)
            let aspectPenalty = abs(w / h - targetAspect) * 2_000
            let sizePenalty = abs(pointWidth - w) + abs(pointHeight - h)
            let hidpi = m.pixelWidth > m.width ? 0.0 : 400
            let refresh = current.map { abs($0.refreshRate - m.refreshRate) * 5 } ?? 0
            return overflow * 4 + aspectPenalty + sizePenalty + hidpi + refresh
        }
        return modes.filter { $0.isUsableForDesktopGUI() }.min { score($0) < score($1) }
    }

    @discardableResult
    func match(display: CGDirectDisplayID, pointWidth: Double, pointHeight: Double) -> Bool {
        guard let mode = Self.bestMode(for: display, pointWidth: pointWidth, pointHeight: pointHeight) else { return false }
        if let cur = CGDisplayCopyDisplayMode(display), cur.ioDisplayModeID == mode.ioDisplayModeID { return false }
        if original[display] == nil { original[display] = CGDisplayCopyDisplayMode(display) }
        return apply(mode, to: display)
    }

    func restore() {
        for (display, mode) in original { _ = apply(mode, to: display) }
        original.removeAll()
    }

    private func apply(_ mode: CGDisplayMode, to display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGConfigureDisplayWithDisplayMode(config, display, mode, nil)
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
