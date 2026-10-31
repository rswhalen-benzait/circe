import AppKit

// MARK: - Clipboard

/// Bidirectional pasteboard sync. Echo-suppressed via change counts.
@MainActor
public final class ClipboardSync {
    public static let types: [NSPasteboard.PasteboardType] = [.string, .rtf, .html, .png, .tiff, .URL]
    public static let maxBytes = 32 * 1024 * 1024

    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount
    public var onLocalChange: ((ClipboardPayload) -> Void)?

    public init() {}

    public func start() {
        lastChange = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    public func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        if let payload = Self.read(pb) { onLocalChange?(payload) }
    }

    public static func read(_ pb: NSPasteboard) -> ClipboardPayload? {
        var items: [String: Data] = [:]
        var total = 0
        for t in types {
            if let d = pb.data(forType: t), total + d.count <= maxBytes {
                items[t.rawValue] = d
                total += d.count
            }
        }
        return items.isEmpty ? nil : ClipboardPayload(items: items, changeCount: pb.changeCount)
    }

    public func apply(_ payload: ClipboardPayload) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        for (t, d) in payload.items { item.setData(d, forType: NSPasteboard.PasteboardType(t)) }
        pb.writeObjects([item])
        lastChange = pb.changeCount
    }
}

