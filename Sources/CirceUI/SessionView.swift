import AppKit
import SwiftUI

public struct SessionView: View {
    @ObservedObject private var session: RemoteSession
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @CirceViewState<Bool> private var hoveringToolbar = false
    @CirceViewState<Bool> private var toolbarVisible = true
    @CirceViewState<Task<Void, Never>?> private var hideTask = nil
    @CirceViewState<NSWindow?> private var window = nil
    @CirceViewState<Bool> private var sizedToRemote = false
    public init(session: RemoteSession) { self.session = session }
    public var body: some View {
        ZStack(alignment: .top) {
            CirceStyle.canvas
            switch session.phase {
            case .connecting: connecting
            case .pairing: PairingView(session: session)
            case .streaming, .reconnecting:
                SessionSurface(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if case .reconnecting(let attempt) = session.phase {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text("Reconnecting to \(session.name)…").font(.system(size: 12, weight: .medium))
                        Text("Attempt \(attempt)").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 18).padding(.vertical, 12).background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom).allowsHitTesting(false)
                }
                if session.showStats {
                    stats.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).allowsHitTesting(false)
                }
                VStack(spacing: 8) {
                    toolbar.opacity(toolbarVisible ? 1 : 0)
                        .offset(y: toolbarVisible ? 0 : -12).allowsHitTesting(toolbarVisible)
                        .onHover { hoveringToolbar = $0; if $0 { revealToolbar() } else { scheduleHide() } }
                    if session.showAccessibilityHint { accessibilityHint.padding(.horizontal, 16) }
                }.padding(.top, 12).animation(.easeInOut(duration: 0.2), value: toolbarVisible)
            case .disconnected(let reason): if let reason { disconnected(reason) } else { Color.clear }
            }
        }.frame(minWidth: 400, minHeight: 320).ignoresSafeArea()
            .background(WindowReader(onWindow: { if window !== $0 { window = $0; configureWindow() } }, onTopEdge: { revealToolbar() }, onReleaseKeyboard: {
                guard session.keyboardReleaseAvailable else { return false }
                session.releaseKeyboard(); revealToolbar(); return true
            }))
            .navigationTitle(session.name)
            .onAppear { scheduleHide(); closeIfEndedCleanly() }
            .onDisappear { hideTask?.cancel(); session.disconnect() }
            .onChange(of: session.phase) { _, value in
                if value == .streaming { revealToolbar() }
                configureWindow(); closeIfEndedCleanly()
            }
            .onChange(of: session.remotePixelSize) { _, _ in configureWindow() }
            .onChange(of: toolbarVisible) { _, _ in updateTrafficLights() }
            .onChange(of: session.showAccessibilityHint) { _, shown in if shown { revealToolbar() } else { scheduleHide() } }
            .onReceive(NotificationCenter.default.publisher(for: .circeDisconnectSession)) { _ in
                if window?.isKeyWindow == true { session.disconnect() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .circeToggleStats)) { _ in
                if window?.isKeyWindow == true { session.showStats.toggle() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .circeReleaseInput)) { _ in
                if window?.isKeyWindow == true { session.releaseKeyboard(); revealToolbar() }
            }
    }
    private var connecting: some View {
        VStack(spacing: 18) {
            CirceMark(size: 62)
            ProgressView().controlSize(.small).tint(.white)
            Text("Connecting to \(session.name)").font(.system(size: 17, weight: .medium))
            Text("Making yourself at home.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            Button("Cancel") { session.disconnect() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65)).padding(.top, 4)
        }.foregroundStyle(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func disconnected(_ reason: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "rectangle.slash").font(.system(size: 39, weight: .ultraLight)).foregroundStyle(CirceStyle.violet)
            VStack(spacing: 9) {
                Text("Session ended").font(.system(size: 30, weight: .regular, design: .serif))
                Text(reason.isEmpty ? "The connection to \(session.name) closed." : reason)
                    .font(.system(size: 13)).foregroundStyle(CirceStyle.secondaryInk).multilineTextAlignment(.center).frame(maxWidth: 380)
            }
            HStack(spacing: 10) {
                Button("Back to Macs") { if !CirceWindows.showLauncherIfOpen() { openWindow(id: "launcher") }; dismissWindow() }.buttonStyle(QuietButtonStyle())
                if session.canReconnect { Button("Reconnect") { session.reconnect() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
            }
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity).background(CirceStyle.paper).foregroundStyle(CirceStyle.ink).preferredColorScheme(.light)
    }
    private var toolbar: some View {
        HStack(spacing: 4) {
            HStack(spacing: 7) {
                StatusDot()
                Text(session.name).font(.system(size: 11, weight: .medium)).lineLimit(1).frame(maxWidth: 140)
            }.padding(.leading, 11).padding(.trailing, 7)
            separator
            tool("Full screen (⌃⌥⌘F)", symbol: "arrow.up.left.and.arrow.down.right") { window?.toggleFullScreen(nil) }
            Menu {
                ForEach(DisplayScale.allCases) { scale in
                    Button { session.setScale(scale) } label: { Label(scale.rawValue, systemImage: session.scale == scale ? "checkmark" : "") }
                }
            } label: { Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left").frame(width: 31, height: 30) }
                .menuStyle(.borderlessButton).fixedSize().help("Display scale")
                .disabled(!session.scaleAvailable)
            Menu {
                if session.displays.count > 1 {
                    Picker("Display", selection: Binding(get: { session.selectedDisplayID }, set: { if let id = $0 { session.selectDisplay(id) } })) {
                        ForEach(session.displays) { display in Text(display.name).tag(Optional(display.id)) }
                    }
                    Divider()
                }
                Toggle("Fit remote display to window", isOn: Binding(get: { session.matchesWindowResolution }, set: { session.setMatchesWindowResolution($0) }))
                    .disabled(!session.resolutionMatchingAvailable)
                Divider()
                Toggle("Sync clipboard", isOn: Binding(get: { session.clipboardEnabled }, set: { session.setClipboard($0) })).disabled(!session.clipboardAvailable)
                Toggle("Play remote audio", isOn: Binding(get: { session.audioEnabled }, set: { session.setAudio($0) })).disabled(!session.audioAvailable)
                Divider()
                Picker("Quality", selection: Binding(get: { session.quality }, set: { session.setQuality($0) })) {
                    ForEach(StreamQuality.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(!session.qualityAvailable)
                Toggle("Show connection stats", isOn: $session.showStats)
                Divider()
                Button("Release keyboard") { session.releaseKeyboard() }
                    .disabled(!session.keyboardReleaseAvailable)
                Text("Control–Option–Command–Escape")
            } label: { Image(systemName: "slider.horizontal.3").frame(width: 31, height: 30) }
                .menuStyle(.borderlessButton).fixedSize().help("Session options")
            separator
            tool("Disconnect (⌃⌥⌘D)", symbol: "power") { session.disconnect() }
        }.padding(5).foregroundStyle(.white.opacity(0.9))
            .background(.ultraThinMaterial, in: Capsule()).environment(\.colorScheme, .dark)
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 5).fixedSize(horizontal: true, vertical: false)
            .help("Local shortcuts: ⌃⌥⌘F full screen · ⌃⌥⌘Esc release input · ⌃⌥⌘D disconnect · ⌃⌥⌘S stats")
    }
    private var accessibilityHint: some View {
        HStack(spacing: 9) {
            Image(systemName: "keyboard").font(.system(size: 15)).foregroundStyle(.white.opacity(0.7))
            Text("Allow Accessibility to send ⌘-Tab to \(session.name).")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            Button("Allow…") { session.requestAccessibility() }.buttonStyle(.bordered).controlSize(.small)
            Button { session.dismissAccessibilityHint() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 20, height: 24) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Dismiss Accessibility hint").accessibilityLabel("Dismiss Accessibility hint")
        }.padding(11).frame(maxWidth: 420)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.12)))
            .environment(\.colorScheme, .dark)
    }
    private var separator: some View { Rectangle().fill(.white.opacity(0.17)).frame(width: 1, height: 17).padding(.horizontal, 3) }
    private func tool(_ label: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12)).frame(width: 31, height: 30).contentShape(Circle()) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private var stats: some View {
        HStack(spacing: 14) {
            stat(String(format: "%.0f", session.fps), "fps")
            stat(String(format: "%.1f", session.latencyMs), "ms")
            stat(String(format: "%.1f", session.bitrateMbps), "Mb/s")
        }.padding(.horizontal, 13).padding(.vertical, 9).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            .accessibilityElement(children: .combine)
    }
    private func stat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(.white)
            Text(unit).font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
    }
    private func closeIfEndedCleanly() {
        if case .disconnected(nil) = session.phase { dismissWindow() }
    }
    private func configureWindow() {
        guard let window else { return }
        window.isRestorable = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isMovableByWindowBackground = false
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        updateTrafficLights()
        guard session.phase == .streaming, !sizedToRemote,
              session.remotePixelSize.width > 0, session.remotePixelSize.height > 0,
              !window.styleMask.contains(.fullScreen) else { return }
        sizedToRemote = true
        let visible = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let ratio = session.remotePixelSize.width / session.remotePixelSize.height
        var width = min(1280, visible.width * 0.88)
        var height = width / ratio
        if height > visible.height * 0.88 { height = visible.height * 0.88; width = height * ratio }
        let size = NSSize(width: max(400, width), height: max(320, height))
        window.setContentSize(size)
        window.center()
    }
    private func updateTrafficLights() {
        guard let window else { return }
        let streaming = session.phase == .streaming || { if case .reconnecting = session.phase { return true }; return false }()
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(type)?.isHidden = streaming && !toolbarVisible
        }
    }
    private func revealToolbar() { toolbarVisible = true; scheduleHide() }
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, !hoveringToolbar, !session.showAccessibilityHint else { return }
            toolbarVisible = false
        }
    }
}

private struct SessionSurface: NSViewRepresentable {
    @ObservedObject var session: RemoteSession
    func makeNSView(context: Context) -> SessionContainer { let view = SessionContainer(); update(view); return view }
    func updateNSView(_ nsView: SessionContainer, context: Context) { update(nsView) }
    private func update(_ view: SessionContainer) {
        view.scale = session.scale
        view.remotePixels = session.remotePixelSize
        if let display = session.displayView { view.install(display) }
        view.needsLayout = true
    }
}

private final class SessionContainer: NSView {
    private let scroll = NSScrollView()
    var scale: DisplayScale = .fit
    var remotePixels = CGSize(width: 1280, height: 800)
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        scroll.backgroundColor = .black; scroll.drawsBackground = true
        scroll.borderType = .noBorder; scroll.autohidesScrollers = true
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func install(_ display: NSView) {
        guard scroll.documentView !== display else { return }
        display.removeFromSuperview()
        display.translatesAutoresizingMaskIntoConstraints = true
        scroll.documentView = display
        DispatchQueue.main.async { [weak self, weak display] in
            guard let display else { return }
            self?.window?.makeFirstResponder(display)
        }
    }
    override func layout() {
        super.layout()
        scroll.frame = bounds
        let actual = scale == .actual
        scroll.hasHorizontalScroller = actual; scroll.hasVerticalScroller = actual
        let viewport = scroll.contentSize
        let backing = window?.backingScaleFactor ?? 2
        let size = actual ? CGSize(width: max(viewport.width, remotePixels.width / backing), height: max(viewport.height, remotePixels.height / backing)) : viewport
        scroll.documentView?.setFrameSize(size)
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
}

struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void
    var onTopEdge: (() -> Void)? = nil
    var onReleaseKeyboard: (() -> Bool)? = nil
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.onTopEdge = onTopEdge
        context.coordinator.onReleaseKeyboard = onReleaseKeyboard
        context.coordinator.install()
        DispatchQueue.main.async { view.window?.acceptsMouseMovedEvents = true; onWindow(view.window) }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onTopEdge = onTopEdge
        context.coordinator.onReleaseKeyboard = onReleaseKeyboard
        DispatchQueue.main.async { onWindow(nsView.window) }
    }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator {
        weak var view: NSView?
        var onTopEdge: (() -> Void)?
        var onReleaseKeyboard: (() -> Bool)?
        private var monitor: Any?
        func install() {
            // Observe pointer motion without placing an invisible hit target over the remote menu bar.
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown]) { [weak self] event in
                guard let self, let window = self.view?.window, event.window === window,
                      let content = window.contentView else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 3, event.modifierFlags.isSuperset(of: [.control, .option, .command]) {
                        window.toggleFullScreen(nil); return nil
                    }
                    if event.keyCode == 53, event.modifierFlags.isSuperset(of: [.control, .option, .command]), self.onReleaseKeyboard?() == true { return nil }
                    return event
                }
                let point = content.convert(event.locationInWindow, from: nil)
                let atTop = content.isFlipped ? point.y <= content.bounds.minY + 14 : point.y >= content.bounds.maxY - 14
                if atTop { self.onTopEdge?() }
                return event
            }
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { remove() }
    }
}

public extension Notification.Name {
    static let circeDisconnectSession = Notification.Name("CirceDisconnectSession")
    static let circeToggleStats = Notification.Name("CirceToggleStats")
    static let circeReleaseInput = Notification.Name("CirceReleaseInput")
}
