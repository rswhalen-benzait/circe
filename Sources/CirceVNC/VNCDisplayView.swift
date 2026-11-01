import AppKit
import CirceClient

/// Remote screen for VNC / Apple Screen Sharing servers.
public final class VNCDisplayView: NSView {
    let imageLayer = CALayer()
    /// Hardware-decoded video of the same desktop (Linux H.264 stream), shown over the VNC image.
    private(set) var videoLayer: CALayer?
    var client: RFBClient? {
        willSet {
            // A new connection has no knowledge of the old connection's pressed keys.
            if client !== newValue { releaseAll() }
        }
    }
    var isApple = false
    var framebufferSize = CGSize(width: 16, height: 10) { didSet { needsLayout = true; window?.invalidateCursorRects(for: self) } }

    public var capturesSystemShortcuts = true { didSet { updateKeyboardCapture() } }
    var onFocusChange: ((Bool) -> Void)?
    var onSettledResize: ((CGSize) -> Void)?
    private var resizeWork: DispatchWorkItem?
    var commandMapping: CommandKeyMapping = .control

    private var buttons: UInt8 = 0
    private var downKeys: [UInt16: UInt32] = [:]
    private var modifiers: [UInt16: UInt32] = [:]
    private var scrollAccum = CGPoint.zero
    private var tracking: NSTrackingArea?
    private var keyboardCapture: KeyboardCapture?
    private var remoteCursor: NSCursor = .arrow

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .nearest
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    var videoRect: CGRect {
        let b = bounds
        guard framebufferSize.width > 0, framebufferSize.height > 0 else { return b }
        // Framebuffers are in device pixels; treat Retina-size framebuffers as 2x points.
        let s = min(b.width / framebufferSize.width, b.height / framebufferSize.height)
        let w = (framebufferSize.width * s).rounded(), h = (framebufferSize.height * s).rounded()
        return CGRect(x: ((b.width - w) / 2).rounded(), y: ((b.height - h) / 2).rounded(), width: w, height: h)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = videoRect
        videoLayer?.frame = videoRect
        CATransaction.commit()
        resizeWork?.cancel()
        let size = bounds.size
        let work = DispatchWorkItem { [weak self] in self?.onSettledResize?(size) }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func setVideoLayer(_ l: CALayer?) {
        guard l !== videoLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer?.removeFromSuperlayer()
        videoLayer = l
        if let l {
            l.frame = videoRect
            layer?.insertSublayer(l, above: imageLayer)
        }
        CATransaction.commit()
    }

    func show(_ fb: RFBFramebuffer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if imageLayer.contents == nil || (imageLayer.contents as AnyObject) !== (fb.surface as AnyObject?) {
            imageLayer.contents = fb.surface
        }
        // IOSurface contents only re-composite when told the surface changed.
        let sel = Selector(("setContentsChanged"))
        if imageLayer.responds(to: sel) {
            imageLayer.perform(sel)
        } else {
            imageLayer.contents = nil
            imageLayer.contents = fb.surface
        }
        CATransaction.commit()
    }

    func setCursor(_ c: RFBCursor) {
        guard let provider = CGDataProvider(data: c.rgba as CFData),
              let img = CGImage(width: c.width, height: c.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: c.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        // Scale cursor from framebuffer pixels to view points.
        let scale = videoRect.width / max(framebufferSize.width, 1)
        let size = NSSize(width: CGFloat(c.width) * scale, height: CGFloat(c.height) * scale)
        remoteCursor = NSCursor(image: NSImage(cgImage: img, size: size),
                                hotSpot: NSPoint(x: CGFloat(c.hotX) * scale, y: CGFloat(c.hotY) * scale))
        window?.invalidateCursorRects(for: self)
    }

    public override func resetCursorRects() { addCursorRect(videoRect, cursor: remoteCursor) }

    // MARK: Focus & keyboard capture

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let w = window else { keyboardCapture?.stop(); releaseAll(); return }
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: n, object: w)
        }
        for n in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(focusChanged), name: n, object: nil)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.acceptsMouseMovedEvents = true
            w.makeFirstResponder(self)
        }
    }

    private var hasInputFocus: Bool { (window?.isKeyWindow ?? false) && NSApp.isActive && window?.firstResponder === self }

    @objc private func focusChanged() {
        onFocusChange?((window?.isKeyWindow ?? false) && NSApp.isActive)
        if !hasInputFocus { releaseAll() }
        updateKeyboardCapture()
    }

    public override func becomeFirstResponder() -> Bool {
        defer { DispatchQueue.main.async { [weak self] in self?.updateKeyboardCapture() } }
        return super.becomeFirstResponder()
    }

    public override func resignFirstResponder() -> Bool {
        keyboardCapture?.stop()
        releaseAll()
        defer { DispatchQueue.main.async { [weak self] in self?.updateKeyboardCapture() } }
        return super.resignFirstResponder()
    }

    public func releaseInput() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        releaseAll()
        keyboardCapture?.stop()
    }

    public func captureInput() { window?.makeFirstResponder(self) }

    private func updateKeyboardCapture() {
        if hasInputFocus && capturesSystemShortcuts {
            if keyboardCapture == nil {
                keyboardCapture = KeyboardCapture { [weak self] cg in
                    guard let self, self.hasInputFocus, let e = NSEvent(cgEvent: cg) else { return }
                    switch e.type {
                    case .keyDown: self.key(e, down: true)
                    case .keyUp: self.key(e, down: false)
                    case .flagsChanged: self.flags(e)
                    default: break
                    }
                }
            }
            keyboardCapture?.start()
        } else {
            keyboardCapture?.stop()
        }
    }

    private func releaseAll() {
        for (_, sym) in downKeys { client?.sendKey(sym, down: false) }
        for sym in Set(modifiers.values).sorted() { client?.sendKey(sym, down: false) }
        downKeys.removeAll()
        modifiers.removeAll()
        if buttons != 0 { buttons = 0; sendPointer(nil) }
    }

    private func key(_ e: NSEvent, down: Bool) {
        reconcileModifiers(e)
        if down {
            guard let sym = KeySyms.keysym(for: e) else { return }
            // A fresh press after a lost key-up must not remain a duplicate down on wayvnc.
            if let prev = downKeys[e.keyCode], prev != sym || !e.isARepeat { client?.sendKey(prev, down: false) }
            downKeys[e.keyCode] = sym
            client?.sendKey(sym, down: true)
        } else if let sym = downKeys.removeValue(forKey: e.keyCode) {
            client?.sendKey(sym, down: false)
        }
    }

    // Device-side bits from IOKit/hidsystem/IOLLEvent.h. Aggregate flags alone cannot tell
    // which Command was released when both are held. Synthetic events may omit these bits.
    private static let modifierGroups: [(NSEvent.ModifierFlags, [(UInt16, UInt)])] = [
        (.shift, [(0x38, 0x02), (0x3C, 0x04)]),
        (.control, [(0x3B, 0x01), (0x3E, 0x2000)]),
        (.option, [(0x3A, 0x20), (0x3D, 0x40)]),
        (.command, [(0x37, 0x08), (0x36, 0x10)]),
    ]

    private func reconcileModifiers(_ e: NSEvent) {
        // Caps Lock keeps its existing lock-key behavior; reconcile momentary modifiers only.
        var wanted = modifiers.filter { $0.key == 0x39 }
        for (flag, sides) in Self.modifierGroups where e.modifierFlags.contains(flag) {
            let physical = sides.filter { e.modifierFlags.rawValue & $0.1 != 0 }.map { $0.0 }
            let codes: [UInt16]
            if !physical.isEmpty {
                codes = physical
            } else {
                // Without side bits, retain a known side or choose the changed/canonical key.
                let held = sides.map { $0.0 }.filter { modifiers[$0] != nil }
                codes = held.isEmpty ? [sides.first(where: { $0.0 == e.keyCode })?.0 ?? sides[0].0] : held
            }
            for code in codes { wanted[code] = KeySyms.modifier(code, apple: isApple, command: commandMapping) }
        }
        // Command-as-Control aliases physical keys to Control_R. Release it only when no
        // physical owner remains, and never turn a repeated flags snapshot into a key-up.
        let old = Set(modifiers.values), new = Set(wanted.values)
        for sym in old.subtracting(new).sorted() { client?.sendKey(sym, down: false) }
        for sym in new.subtracting(old).sorted() { client?.sendKey(sym, down: true) }
        modifiers = wanted
    }

    private func flags(_ e: NSEvent) {
        reconcileModifiers(e)
        if e.keyCode == 0x39, let sym = KeySyms.modifier(e.keyCode, apple: isApple, command: commandMapping) {
            let down = e.modifierFlags.contains(.capsLock) && modifiers[e.keyCode] == nil
            if down { modifiers[e.keyCode] = sym } else { modifiers[e.keyCode] = nil }
            client?.sendKey(sym, down: down)
        }
    }

    // The tap returns nil for captured events, so they never reach AppKit. Events that
    // do reach us may have been queued before the tap started: don't discard them based
    // on its current state. Keep the local escape chord out of the remote key-down path.
    public override func keyDown(with e: NSEvent) {
        if !e.modifierFlags.isSuperset(of: [.control, .option, .command]) { key(e, down: true) }
    }
    public override func keyUp(with e: NSEvent) { key(e, down: false) }
    public override func flagsChanged(with e: NSEvent) { flags(e) }

    public override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, !e.modifierFlags.isSuperset(of: [.control, .option, .command]) else { return false }
        key(e, down: true)
        // AppKit handles Command equivalents separately from keyDown; a matching keyUp
        // is not assured. Balance the press here so the next identical chord can fire.
        if e.modifierFlags.contains(.command) { key(e, down: false) }
        return true
    }

    // MARK: Pointer

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private var lastPoint = CGPoint.zero

    private func sendPointer(_ e: NSEvent?) {
        if let e {
            let p = convert(e.locationInWindow, from: nil)
            let r = videoRect
            lastPoint = CGPoint(x: (p.x - r.minX) / max(r.width, 1) * framebufferSize.width,
                                y: (p.y - r.minY) / max(r.height, 1) * framebufferSize.height)
        }
        client?.sendPointer(x: Int(min(max(lastPoint.x, 0), framebufferSize.width - 1)),
                            y: Int(min(max(lastPoint.y, 0), framebufferSize.height - 1)), buttons: buttons)
    }

    private func setButton(_ bit: UInt8, _ down: Bool, _ e: NSEvent) {
        if down, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        if down { buttons |= bit } else { buttons &= ~bit }
        sendPointer(e)
    }

    public override func mouseMoved(with e: NSEvent) { sendPointer(e) }
    public override func mouseDragged(with e: NSEvent) { sendPointer(e) }
    public override func rightMouseDragged(with e: NSEvent) { sendPointer(e) }
    public override func otherMouseDragged(with e: NSEvent) { sendPointer(e) }
    public override func mouseDown(with e: NSEvent) { setButton(1, true, e) }
    public override func mouseUp(with e: NSEvent) { setButton(1, false, e) }
    public override func rightMouseDown(with e: NSEvent) { setButton(4, true, e) }
    public override func rightMouseUp(with e: NSEvent) { setButton(4, false, e) }
    public override func otherMouseDown(with e: NSEvent) { setButton(2, true, e) }
    public override func otherMouseUp(with e: NSEvent) { setButton(2, false, e) }

    public override func scrollWheel(with e: NSEvent) {
        // RFB only knows wheel "clicks" (buttons 4-7); convert smooth deltas into clicks.
        let step: CGFloat = e.hasPreciseScrollingDeltas ? 12 : 1
        scrollAccum.x += e.scrollingDeltaX
        scrollAccum.y += e.scrollingDeltaY
        func click(_ bit: UInt8) {
            client?.sendPointer(x: Int(lastPoint.x), y: Int(lastPoint.y), buttons: buttons | bit)
            client?.sendPointer(x: Int(lastPoint.x), y: Int(lastPoint.y), buttons: buttons)
        }
        while scrollAccum.y >= step { click(8); scrollAccum.y -= step }
        while scrollAccum.y <= -step { click(16); scrollAccum.y += step }
        while scrollAccum.x >= step { click(32); scrollAccum.x -= step }
        while scrollAccum.x <= -step { click(64); scrollAccum.x += step }
        if e.phase.contains(.ended) || e.momentumPhase.contains(.ended) { scrollAccum = .zero }
    }
}
