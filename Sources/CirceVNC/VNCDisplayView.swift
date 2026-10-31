import AppKit
import CirceClient

/// Remote screen for VNC / Apple Screen Sharing servers.
public final class VNCDisplayView: NSView {
    let imageLayer = CALayer()
    var client: RFBClient?
    var isApple = false
    var framebufferSize = CGSize(width: 16, height: 10) { didSet { needsLayout = true; window?.invalidateCursorRects(for: self) } }

    public var capturesSystemShortcuts = true { didSet { updateKeyboardCapture() } }
    var onFocusChange: ((Bool) -> Void)?

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
        guard let w = window else { keyboardCapture?.stop(); return }
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
                    guard let self, let e = NSEvent(cgEvent: cg) else { return }
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

    private var capturing: Bool { keyboardCapture?.isRunning ?? false }

    private func releaseAll() {
        for (_, sym) in downKeys { client?.sendKey(sym, down: false) }
        for (_, sym) in modifiers { client?.sendKey(sym, down: false) }
        downKeys.removeAll()
        modifiers.removeAll()
        if buttons != 0 { buttons = 0; sendPointer(nil) }
    }

    private func key(_ e: NSEvent, down: Bool) {
        if down {
            guard let sym = KeySyms.keysym(for: e) else { return }
            if let prev = downKeys[e.keyCode], prev != sym { client?.sendKey(prev, down: false) }
            downKeys[e.keyCode] = sym
            client?.sendKey(sym, down: true)
        } else if let sym = downKeys.removeValue(forKey: e.keyCode) {
            client?.sendKey(sym, down: false)
        }
    }

    private func flags(_ e: NSEvent) {
        guard let sym = KeySyms.modifier(e.keyCode, apple: isApple), let flag = KeySyms.modifierFlag(e.keyCode) else { return }
        let down = e.modifierFlags.contains(flag) && modifiers[e.keyCode] == nil
        if down { modifiers[e.keyCode] = sym } else { modifiers[e.keyCode] = nil }
        client?.sendKey(sym, down: down)
    }

    public override func keyDown(with e: NSEvent) { if !capturing { key(e, down: true) } }
    public override func keyUp(with e: NSEvent) { if !capturing { key(e, down: false) } }
    public override func flagsChanged(with e: NSEvent) { if !capturing { flags(e) } }

    public override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, !e.modifierFlags.isSuperset(of: [.control, .option, .command]) else { return false }
        if !capturing { key(e, down: true) }
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
