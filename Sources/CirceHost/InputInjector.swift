import CirceCore
import CoreGraphics
import Foundation

/// Replays client input on this Mac via CGEvent. Requires Accessibility permission.
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var displayID: CGDirectDisplayID
    private var heldButtons: Set<MouseButton> = []
    private var heldKeys: Set<UInt16> = []
    private var flags: CGEventFlags = []
    private var lastPoint: CGPoint = .zero
    private var scrollRemainder = CGPoint.zero

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
        lastPoint = CGEvent(source: nil)?.location ?? .zero
        // Don't suppress local hardware events while remote input is being injected.
        source?.localEventsSuppressionInterval = 0
    }

    func setDisplay(_ id: CGDirectDisplayID) { displayID = id }

    private func point(_ x: Float, _ y: Float) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        let cx = min(max(CGFloat(x), 0), 1), cy = min(max(CGFloat(y), 0), 1)
        return CGPoint(x: b.minX + cx * (b.width - 1), y: b.minY + cy * (b.height - 1))
    }

    private func cgButton(_ b: MouseButton) -> CGMouseButton {
        switch b {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        case .back: return CGMouseButton(rawValue: 3)!
        case .forward: return CGMouseButton(rawValue: 4)!
        }
    }

    private func post(_ e: CGEvent?) {
        guard let e else { return }
        e.flags = e.type == .flagsChanged ? e.flags : flags.union(e.flags)
        e.post(tap: .cghidEventTap)
    }

    private func moveType() -> CGEventType {
        if heldButtons.contains(.left) { return .leftMouseDragged }
        if heldButtons.contains(.right) { return .rightMouseDragged }
        if !heldButtons.isEmpty { return .otherMouseDragged }
        return .mouseMoved
    }

    private func dragButton() -> CGMouseButton {
        if heldButtons.contains(.left) { return .left }
        if heldButtons.contains(.right) { return .right }
        return heldButtons.first.map(cgButton) ?? .left
    }

    func handle(_ event: InputEvent) {
        switch event {
        case let .mouseMove(x, y):
            let p = point(x, y)
            let e = CGEvent(mouseEventSource: source, mouseType: moveType(), mouseCursorPosition: p, mouseButton: dragButton())
            e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(p.x - lastPoint.x))
            e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(p.y - lastPoint.y))
            lastPoint = p
            post(e)

        case let .mouseRelative(dx, dy):
            let b = CGDisplayBounds(displayID)
            let p = CGPoint(x: min(max(lastPoint.x + CGFloat(dx), b.minX), b.maxX - 1),
                            y: min(max(lastPoint.y + CGFloat(dy), b.minY), b.maxY - 1))
            let e = CGEvent(mouseEventSource: source, mouseType: moveType(), mouseCursorPosition: p, mouseButton: dragButton())
            e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
            lastPoint = p
            post(e)

        case let .mouseButton(button, down, x, y, clicks):
            let p = point(x, y)
            lastPoint = p
            let type: CGEventType
            switch (button, down) {
            case (.left, true): type = .leftMouseDown
            case (.left, false): type = .leftMouseUp
            case (.right, true): type = .rightMouseDown
            case (.right, false): type = .rightMouseUp
            case (_, true): type = .otherMouseDown
            case (_, false): type = .otherMouseUp
            }
            if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
            let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: cgButton(button))
            e?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clicks, 1)))
            post(e)

        case let .scroll(dx, dy, phase, momentum, precise):
            let fx = CGFloat(dx) + scrollRemainder.x
            let fy = CGFloat(dy) + scrollRemainder.y
            let ix = fx.rounded(.towardZero), iy = fy.rounded(.towardZero)
            scrollRemainder = CGPoint(x: fx - ix, y: fy - iy)
            let e = CGEvent(scrollWheelEvent2Source: source, units: precise ? .pixel : .line, wheelCount: 2,
                            wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0)
            if precise {
                e?.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                e?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
                e?.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
                e?.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(dy))
                e?.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dx))
            }
            e?.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
            e?.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))
            e?.location = lastPoint
            post(e)

        case let .key(code, down, rawFlags):
            flags = CGEventFlags(rawValue: rawFlags).intersection(Self.modifierMask)
            if down { heldKeys.insert(code) } else { heldKeys.remove(code) }
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            e?.flags = CGEventFlags(rawValue: rawFlags)
            e?.post(tap: .cghidEventTap)

        case let .flagsChanged(code, rawFlags):
            flags = CGEventFlags(rawValue: rawFlags).intersection(Self.modifierMask)
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
            e?.type = .flagsChanged
            e?.flags = CGEventFlags(rawValue: rawFlags)
            e?.post(tap: .cghidEventTap)

        case .magnify:
            // Gesture synthesis needs private API; pinch is forwarded as ⌘-scroll by the client instead.
            break

        case .releaseAll:
            releaseAll()
        }
    }

    func releaseAll() {
        for code in heldKeys {
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
            e?.post(tap: .cghidEventTap)
        }
        heldKeys.removeAll()
        if !flags.isEmpty {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 0x38, keyDown: false)
            e?.type = .flagsChanged
            e?.flags = []
            e?.post(tap: .cghidEventTap)
            flags = []
        }
        for b in heldButtons {
            let type: CGEventType = b == .left ? .leftMouseUp : b == .right ? .rightMouseUp : .otherMouseUp
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPoint, mouseButton: cgButton(b))?
                .post(tap: .cghidEventTap)
        }
        heldButtons.removeAll()
    }

    static let modifierMask: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskAlphaShift, .maskSecondaryFn]
}
