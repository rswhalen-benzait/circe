import AppKit
import AVFoundation
import CirceCore

/// The remote screen. Renders video, draws the remote cursor shape locally (zero-latency pointer),
/// and turns every mouse, trackpad and keyboard event into Circe input.
public final class SessionDisplayView: NSView {
    let renderer = VideoRenderer()
    var onInput: ((InputEvent) -> Void)?
    var onFocusChange: ((Bool) -> Void)?
    /// Size in points after the user stops resizing (debounced).
    var onSettledResize: ((CGSize) -> Void)?
    var onDropFiles: (([URL]) -> Void)?
    var onVisibilityChange: ((Bool) -> Void)?
    private var resizeWork: DispatchWorkItem?

    /// Remote display size in points; used to letterbox and map coordinates.
    var remoteSize = CGSize(width: 16, height: 10) { didSet { needsLayout = true; window?.invalidateCursorRects(for: self) } }

    /// Grab ⌘-Tab, ⌘-Space and friends while focused (needs Accessibility).
    public var capturesSystemShortcuts = true { didSet { updateKeyboardCapture() } }

    /// When true the host isn't drawing its cursor into the video; we show its shape as our cursor.
    var localCursor = true { didSet { window?.invalidateCursorRects(for: self) } }

    private var remoteCursor: NSCursor = .arrow
    private var cursorCache: [UInt32: NSCursor] = [:]
    private var tracking: NSTrackingArea?
    private var keyboardCapture: KeyboardCapture?
    private var pressedKeys = Set<UInt16>()
    private var lastMove = CGPoint(x: -1, y: -1)

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(renderer.layer)
        layerContentsRedrawPolicy = .never
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Drag & drop files to the remote Mac

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Layout

    /// Aspect-fit rect of the remote screen inside the view.
    var videoRect: CGRect {
        let b = bounds
        guard remoteSize.width > 0, remoteSize.height > 0, b.width > 0, b.height > 0 else { return b }
        let s = min(b.width / remoteSize.width, b.height / remoteSize.height)
        let w = (remoteSize.width * s).rounded(), h = (remoteSize.height * s).rounded()
        return CGRect(x: ((b.width - w) / 2).rounded(), y: ((b.height - h) / 2).rounded(), width: w, height: h)
    }

    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        renderer.layer.frame = videoRect
        renderer.layer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
        resizeWork?.cancel()
        let size = bounds.size
        let work = DispatchWorkItem { [weak self] in self?.onSettledResize?(size) }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    /// Size of the view in device pixels — lets the host downscale to exactly what we show.
    var backingPixelSize: CGSize { convertToBacking(bounds).size }

    // MARK: Cursor

    func setCursorShape(_ shape: CursorShape) {
        if !shape.png.isEmpty, let image = NSImage(data: shape.png) {
            image.size = NSSize(width: CGFloat(shape.width), height: CGFloat(shape.height))
            cursorCache[shape.id] = NSCursor(image: image, hotSpot: NSPoint(x: CGFloat(shape.hotspotX), y: CGFloat(shape.hotspotY)))
        }
        if let c = cursorCache[shape.id] {
            remoteCursor = c
            window?.invalidateCursorRects(for: self)
            if let w = window, w.isKeyWindow, videoRect.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) { c.set() }
        }
    }

    private static let hiddenCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

    public override func resetCursorRects() {
        addCursorRect(videoRect, cursor: localCursor ? remoteCursor : Self.hiddenCursor)
    }

    // MARK: Focus

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let w = window else { stopKeyboardCapture(); return }
        for (name, sel) in [(NSWindow.didBecomeKeyNotification, #selector(windowFocusChanged)),
                            (NSWindow.didResignKeyNotification, #selector(windowFocusChanged))] {
            NotificationCenter.default.addObserver(self, selector: sel, name: name, object: w)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged),
                                               name: NSApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: w)
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window else { return }
            w.makeFirstResponder(self)
            w.acceptsMouseMovedEvents = true
            self.windowFocusChanged()
        }
    }

    @objc private func occlusionChanged() {
        onVisibilityChange?(window?.occlusionState.contains(.visible) ?? false)
    }

    @objc private func windowFocusChanged() {
        let focused = (window?.isKeyWindow ?? false) && NSApp.isActive
        if !focused {
            // Never leave keys or buttons stuck down on the remote Mac.
            onInput?(.releaseAll)
            pressedKeys.removeAll()
        }
        updateKeyboardCapture()
        onFocusChange?(focused)
    }

    /// Keys go remote only while the remote screen itself has focus (not a toolbar field or pairing sheet).
    private var hasInputFocus: Bool {
        (window?.isKeyWindow ?? false) && NSApp.isActive && window?.firstResponder === self
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        DispatchQueue.main.async { [weak self] in self?.updateKeyboardCapture() }
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        onInput?(.releaseAll)
        pressedKeys.removeAll()
        DispatchQueue.main.async { [weak self] in self?.updateKeyboardCapture() }
        return ok
    }

    /// Hand the keyboard and mouse back to this Mac (e.g. ⌃⌥⌘-Esc or a toolbar control).
    /// Clicking the remote screen captures again.
    public func releaseInput() {
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        onInput?(.releaseAll)
        pressedKeys.removeAll()
        stopKeyboardCapture()
    }

    /// Give the remote screen keyboard focus.
    public func captureInput() {
        window?.makeFirstResponder(self)
    }

    public var hasKeyboardFocus: Bool { hasInputFocus }

    private func updateKeyboardCapture() {
        if hasInputFocus && capturesSystemShortcuts {
            if keyboardCapture == nil {
                keyboardCapture = KeyboardCapture { [weak self] e in self?.forward(cgEvent: e) }
            }
            keyboardCapture?.start()
        } else {
            stopKeyboardCapture()
        }
    }

    private func stopKeyboardCapture() {
        keyboardCapture?.stop()
        keyboardCapture = nil
    }

    var isCapturingSystemKeys: Bool { keyboardCapture?.isRunning ?? false }

    // MARK: Keyboard

    private func forward(cgEvent e: CGEvent) {
        let code = UInt16(e.getIntegerValueField(.keyboardEventKeycode))
        let flags = e.flags.rawValue
        switch e.type {
        case .keyDown:
            pressedKeys.insert(code)
            onInput?(.key(keyCode: code, down: true, flags: flags))
        case .keyUp:
            pressedKeys.remove(code)
            onInput?(.key(keyCode: code, down: false, flags: flags))
        case .flagsChanged:
            onInput?(.flagsChanged(keyCode: code, flags: flags))
        default: break
        }
    }

    private func isEscapeCombo(_ e: NSEvent) -> Bool {
        e.modifierFlags.isSuperset(of: [.control, .option, .command])
    }

    public override func keyDown(with event: NSEvent) {
        guard !isCapturingSystemKeys else { return }
        pressedKeys.insert(event.keyCode)
        onInput?(.key(keyCode: event.keyCode, down: true, flags: cgFlags(event)))
    }

    public override func keyUp(with event: NSEvent) {
        guard !isCapturingSystemKeys else { return }
        pressedKeys.remove(event.keyCode)
        onInput?(.key(keyCode: event.keyCode, down: false, flags: cgFlags(event)))
    }

    public override func flagsChanged(with event: NSEvent) {
        guard !isCapturingSystemKeys else { return }
        onInput?(.flagsChanged(keyCode: event.keyCode, flags: cgFlags(event)))
    }

    /// ⌘-shortcuts go to the remote Mac, not our menu bar — except the ⌃⌥⌘ escape hatch.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !isEscapeCombo(event) else { return false }
        if isCapturingSystemKeys { return true }
        keyDown(with: event)
        return true
    }

    private func cgFlags(_ e: NSEvent) -> UInt64 { e.cgEvent?.flags.rawValue ?? UInt64(e.modifierFlags.rawValue) }

    // MARK: Mouse

    private func normalized(_ event: NSEvent) -> (Float, Float) {
        let p = convert(event.locationInWindow, from: nil)
        let r = videoRect
        let x = (p.x - r.minX) / max(r.width, 1)
        let y = (p.y - r.minY) / max(r.height, 1)
        return (Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1)))
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func move(_ event: NSEvent) {
        let (x, y) = normalized(event)
        let p = CGPoint(x: CGFloat(x), y: CGFloat(y))
        guard p != lastMove else { return }
        lastMove = p
        onInput?(.mouseMove(x: x, y: y))
    }

    private func button(_ b: MouseButton, _ down: Bool, _ event: NSEvent) {
        if down, window?.firstResponder !== self { window?.makeFirstResponder(self) }
        let (x, y) = normalized(event)
        onInput?(.mouseButton(button: b, down: down, x: x, y: y, clickCount: UInt8(clamping: event.clickCount)))
    }

    public override func mouseMoved(with event: NSEvent) { move(event) }
    public override func mouseDragged(with event: NSEvent) { move(event) }
    public override func rightMouseDragged(with event: NSEvent) { move(event) }
    public override func otherMouseDragged(with event: NSEvent) { move(event) }
    public override func mouseDown(with event: NSEvent) { button(.left, true, event) }
    public override func mouseUp(with event: NSEvent) { button(.left, false, event) }
    public override func rightMouseDown(with event: NSEvent) { button(.right, true, event) }
    public override func rightMouseUp(with event: NSEvent) { button(.right, false, event) }

    private func otherButton(_ event: NSEvent) -> MouseButton {
        switch event.buttonNumber {
        case 3: return .back
        case 4: return .forward
        default: return .middle
        }
    }
    public override func otherMouseDown(with event: NSEvent) { button(otherButton(event), true, event) }
    public override func otherMouseUp(with event: NSEvent) { button(otherButton(event), false, event) }

    public override func scrollWheel(with event: NSEvent) {
        let precise = event.hasPreciseScrollingDeltas
        let dx = Float(precise ? event.scrollingDeltaX : event.scrollingDeltaX)
        let dy = Float(precise ? event.scrollingDeltaY : event.scrollingDeltaY)
        onInput?(.scroll(dx: dx, dy: dy, phase: Self.cgScrollPhase(event.phase),
                         momentumPhase: Self.cgMomentumPhase(event.momentumPhase), precise: precise))
    }

    public override func magnify(with event: NSEvent) {
        onInput?(.magnify(amount: Float(event.magnification), phase: Self.cgScrollPhase(event.phase)))
    }

    /// NSEvent.Phase -> CGScrollPhase raw values.
    static func cgScrollPhase(_ p: NSEvent.Phase) -> UInt8 {
        if p.contains(.began) { return 1 }
        if p.contains(.changed) || p.contains(.stationary) { return 2 }
        if p.contains(.ended) { return 4 }
        if p.contains(.cancelled) { return 8 }
        if p.contains(.mayBegin) { return 128 }
        return 0
    }

    /// NSEvent.Phase -> CGMomentumScrollPhase raw values.
    static func cgMomentumPhase(_ p: NSEvent.Phase) -> UInt8 {
        if p.contains(.began) { return 1 }
        if p.contains(.changed) || p.contains(.stationary) { return 2 }
        if p.contains(.ended) || p.contains(.cancelled) { return 3 }
        return 0
    }
}
