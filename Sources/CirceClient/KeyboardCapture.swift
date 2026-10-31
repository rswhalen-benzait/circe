import AppKit
import ApplicationServices
import CoreGraphics

/// Grabs the keyboard system-wide while a session is focused so ⌘-Tab, ⌘-Space, Mission Control
/// keys etc. go to the remote Mac — just like sitting in front of it.
/// Needs Accessibility permission; without it, the session view falls back to normal key events.
/// Escape hatch: holding ⌃⌥⌘ passes keys through to this Mac.
public final class KeyboardCapture {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let handler: (CGEvent) -> Void

    public static let escapeFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]

    public var isRunning: Bool { tap != nil }

    public init(handler: @escaping (CGEvent) -> Void) {
        self.handler = handler
    }

    public static var isPermitted: Bool { AXIsProcessTrusted() }

    @discardableResult
    public func start() -> Bool {
        guard tap == nil, Self.isPermitted else { return tap != nil }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(mask), callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyboardCapture>.fromOpaque(refcon).takeUnretainedValue()
            return me.process(type, event)
        }, userInfo: refcon) else { return false }
        tap = t
        runLoopSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }

    public func stop() {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func process(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // Only steal keys while we're the frontmost app (the view stops us on resign, but be safe).
        guard NSApp.isActive else { return Unmanaged.passUnretained(event) }
        if type != .flagsChanged && event.flags.isSuperset(of: Self.escapeFlags) {
            return Unmanaged.passUnretained(event)
        }
        handler(event)
        return nil
    }

    deinit { stop() }
}
