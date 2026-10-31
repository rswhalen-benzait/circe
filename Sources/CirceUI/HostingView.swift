import SwiftUI

public struct HostingSetupView: View {
    @ObservedObject private var model: CirceModel
    @Environment(\.dismiss) private var dismiss
    public init(model: CirceModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                CirceMark(size: 38)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 25, height: 25).background(CirceStyle.line.opacity(0.5), in: Circle()) }
                    .buttonStyle(.plain).help("Close").accessibilityLabel("Close sharing settings")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Make yourself at home.").font(.system(size: 29, weight: .regular, design: .serif)).tracking(-0.7).accessibilityAddTraits(.isHeader)
                Text("Share \(model.computerName) with your other computers. Circe needs two permissions to show your screen and pass through input.")
                    .font(.system(size: 13)).foregroundStyle(CirceStyle.secondaryInk).lineSpacing(3)
            }
            VStack(spacing: 0) {
                permission("Screen Recording", detail: "See this Mac’s desktop remotely.", symbol: "rectangle.inset.filled", granted: model.screenRecordingGranted, action: model.requestScreenRecording)
                Divider().padding(.leading, 51)
                permission("Accessibility", detail: "Use your keyboard, mouse, and trackpad.", symbol: "cursorarrow.motionlines", granted: model.accessibilityGranted, action: model.requestAccessibility)
            }.padding(.horizontal, 15).background(CirceStyle.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CirceStyle.line))
            if let error = model.hostError { InlineNotice(title: "Sharing couldn’t start", message: error) }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow others to connect").font(.system(size: 13, weight: .semibold))
                    Text(model.isHosting ? "Visible to nearby Macs running Circe." : "Pairing is required for every new computer.")
                        .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                }
                Spacer()
                Toggle("Allow others to connect to this Mac", isOn: Binding(get: { model.sharingEnabled }, set: { model.setHosting($0) }))
                    .labelsHidden().toggleStyle(.switch).tint(CirceStyle.primaryFill)
                    .disabled(model.isHostStarting || (!model.sharingEnabled && (!model.screenRecordingGranted || !model.accessibilityGranted)))
            }
            Text("Sharing also turns on Open Circe at login.").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
            if let error = model.loginItemError { InlineNotice(title: "Login setup needs attention", message: error) }
            if model.isHosting, let pin = model.pairingPIN {
                VStack(alignment: .leading, spacing: 8) {
                    SectionEyebrow(title: "Pairing code")
                    Text(pin).accessibilityLabel("Pairing code").accessibilityValue(pin.map(String.init).joined(separator: " ")).font(.system(size: 31, weight: .medium, design: .rounded)).tracking(7).textSelection(.enabled)
                    Text("Enter this code on your connecting computer.").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(CirceStyle.violetWash, in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text("You can manage sharing from the menu bar.").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }.padding(30).frame(width: 490).background(CirceStyle.paper).foregroundStyle(CirceStyle.ink)
            .focusSection()
            .onAppear { model.refreshPermissions() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }
    private func permission(_ title: String, detail: String, symbol: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).font(.system(size: 19, weight: .light)).foregroundStyle(CirceStyle.violet).frame(width: 23).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(CirceStyle.green).accessibilityLabel("\(title) allowed")
            } else { Button("Allow…", action: action).accessibilityLabel("Allow \(title)").accessibilityHint("Opens privacy settings for \(title) on this Mac.").buttonStyle(QuietButtonStyle()) }
        }.padding(.vertical, 17)
    }
}

public struct HostMenuView: View {
    @ObservedObject private var model: CirceModel
    @Environment(\.openWindow) private var openWindow
    @CirceViewState<Bool> private var showSetup = false
    public init(model: CirceModel) { self.model = model }
    public var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 10) {
                CirceMark(size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Circe").font(.system(size: 17, weight: .medium, design: .serif))
                    Text(model.computerName).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusDot(color: model.isHosting ? CirceStyle.green : .secondary)
            }
            Toggle("Allow others to connect to this Mac", isOn: Binding(get: { model.sharingEnabled }, set: { value in
                if value && (!model.screenRecordingGranted || !model.accessibilityGranted) { showSetup = true }
                else { model.setHosting(value) }
            })).toggleStyle(.switch).tint(CirceStyle.primaryFill).font(.system(size: 12, weight: .medium))
            Text("Sharing also opens Circe at login.").font(.system(size: 10)).foregroundStyle(.secondary)
            if model.isHosting {
                if let pin = model.pairingPIN {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionEyebrow(title: "Pairing code")
                        Text(pin).accessibilityLabel("Pairing code").accessibilityValue(pin.map(String.init).joined(separator: " ")).font(.system(size: 27, weight: .medium, design: .rounded)).tracking(5).textSelection(.enabled)
                    }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background(CirceStyle.violet.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }
                Text(model.connectedClientCount == 0 ? "Waiting for a connection" : "\(model.connectedClientCount) connected \(model.connectedClientCount == 1 ? "computer" : "computers")")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else { Text("This Mac is private. Turn on sharing to connect from another computer.").font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if let error = model.hostError { Text(error).font(.system(size: 11)).foregroundStyle(CirceStyle.error).fixedSize(horizontal: false, vertical: true) }
            if let error = model.loginItemError { Text(error).font(.system(size: 11)).foregroundStyle(CirceStyle.error).fixedSize(horizontal: false, vertical: true) }
            if model.loginItemStatus == .requiresApproval {
                Button("Allow Circe in Login Items…") { model.openLoginSettings() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(CirceStyle.violet)
            }
            if !model.sharingConnections.isEmpty {
                VStack(spacing: 10) {
                    ForEach(model.sharingConnections) { client in
                        HStack(spacing: 8) {
                            Image(systemName: "desktopcomputer").accessibilityHidden(true).foregroundStyle(CirceStyle.violet)
                            Text(client.name).accessibilityValue(client.isStreaming ? "Connected" : "Authenticating").font(.system(size: 11)).lineLimit(1)
                            Spacer()
                            Button { model.disconnectClient(client.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                                .buttonStyle(.plain).help("Disconnect \(client.name)").accessibilityLabel("Disconnect \(client.name)")
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Circe") { NSApp.activate(ignoringOtherApps: true); if !CirceWindows.showLauncherIfOpen() { openWindow(id: "launcher") } }.buttonStyle(.plain).font(.system(size: 12))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.accessibilityLabel("Quit Circe").buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(20).frame(width: 290).sheet(isPresented: $showSetup) { HostingSetupView(model: model) }
            .focusSection()
            .onAppear { model.refreshPermissions() }
    }
}
