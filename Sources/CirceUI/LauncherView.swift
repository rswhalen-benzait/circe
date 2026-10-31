import SwiftUI

private final class LauncherWindowReference { weak var window: NSWindow? }

public struct LauncherView: View {
    @ObservedObject private var model: CirceModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @CirceViewState<String> private var address = ""
    @CirceViewState<String?> private var addressError = nil
    private enum Sheet: String, Identifiable { case welcome, sharing, addComputer; var id: Self { self } }
    @CirceViewState<SavedComputer?> private var editingComputer: SavedComputer? = nil
    @CirceViewState<Sheet?> private var sheet = nil
    @CirceViewState<Bool> private var shareAfterWelcome = false
    @CirceViewState<LauncherWindowReference> private var windowReference = LauncherWindowReference()
    @FocusState private var addressFocused: Bool
    public init(model: CirceModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    introduction
                    savedComputers.focusSection()
                    nearby.focusSection()
                    recents.focusSection()
                    manualConnection.focusSection()
                }.padding(.horizontal, 32).padding(.top, 20).padding(.bottom, 30)
            }.scrollIndicators(.hidden)
            footer
        }
        .frame(minWidth: 540, idealWidth: 640, minHeight: 570, idealHeight: 650)
        .background(CirceStyle.paper).foregroundStyle(CirceStyle.ink)

        .background(WindowReader(onWindow: { window in
            windowReference.window = window
            window?.identifier = NSUserInterfaceItemIdentifier("circe.launcher")
            if CirceStartup.isQuietLaunch { window?.orderOut(nil) }
            else if window?.isVisible == true { presentWelcomeIfNeeded() }
        }))
        .sheet(item: $sheet, onDismiss: {
            if shareAfterWelcome { shareAfterWelcome = false; sheet = .sharing }
        }) { item in
            switch item {
            case .welcome:
                WelcomeView { destination in
                    shareAfterWelcome = destination == .share
                    sheet = nil
                }
            case .sharing: HostingSetupView(model: model)
            case .addComputer: AddComputerView(model: model)
            }
        }
        .sheet(item: $editingComputer) { AddComputerView(model: model, computer: $0) }
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didFinishLaunchingNotification)) { _ in presentWelcomeIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .circeLauncherRevealed)) { notification in
            if (notification.object as? NSWindow) === windowReference.window { presentWelcomeIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { notification in
            if (notification.object as? NSWindow) === windowReference.window { presentWelcomeIfNeeded() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CirceMark(size: 31)
            Text("Circe").font(.system(size: 20, weight: .semibold, design: .serif)).tracking(-0.5)
            Spacer()
            Button { sheet = .addComputer } label: { Label("Add a computer", systemImage: "plus") }.buttonStyle(QuietButtonStyle())
            Button { openSettings() } label: { Image(systemName: "slider.horizontal.3").font(.system(size: 15)).frame(width: 30, height: 30) }
                .buttonStyle(.plain).foregroundStyle(CirceStyle.secondaryInk).help("Settings…").accessibilityLabel("Open settings")
        }.padding(.horizontal, 32).padding(.top, 18).padding(.bottom, 12)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Your desktop.\nWherever you are.")
                .font(.system(size: 36, weight: .regular, design: .serif)).tracking(-1.2).lineSpacing(-1).accessibilityAddTraits(.isHeader)
            Text("A familiar desktop, just a connection away.")
                .font(.system(size: 13)).foregroundStyle(CirceStyle.secondaryInk)
        }.padding(.bottom, 3)
    }

    @ViewBuilder private var savedComputers: some View {
        if !model.computers.isEmpty {
            VStack(alignment: .leading, spacing: 11) {
                SectionEyebrow(title: "Saved computers")
                ForEach(model.computers) { computer in
                    Button {
                        if model.isSettingUp(computer.id) { editingComputer = computer }
                        else { connect(model.connect(to: computer)) }
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: computer.symbol).font(.system(size: 26, weight: .ultraLight)).foregroundStyle(CirceStyle.violet).frame(width: 35)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(computer.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(model.isSettingUp(computer.id) ? "Setting up Linux…" : computer.detail)
                                    .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).lineLimit(1)
                            }
                            Spacer()
                            if model.isSettingUp(computer.id) { ProgressView().controlSize(.small) }
                            else { Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(CirceStyle.violet) }
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(CirceStyle.surface, in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(CirceStyle.line))
                            .contentShape(RoundedRectangle(cornerRadius: 13))
                    }.buttonStyle(FocusOutlineButtonStyle(cornerRadius: 13))
                        .accessibilityLabel(model.isSettingUp(computer.id) ? "Show setup progress for \(computer.name)" : "Connect to \(computer.name)").accessibilityValue(computer.detail)
                        .contextMenu {
                            Button(model.isSettingUp(computer.id) ? "Show setup progress…" : "Connection settings…") { editingComputer = computer }
                            Button("Remove saved computer") { model.removeComputer(computer.id) }.disabled(model.isSettingUp(computer.id))
                        }
                }
            }
        }
    }

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionEyebrow(title: "Nearby Macs")
                Spacer()
                if !model.hosts.isEmpty {
                    Text("\(model.hosts.count) available").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                }
                Button { model.refreshDiscovery() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(CirceStyle.secondaryInk).help("Refresh nearby Macs").accessibilityLabel("Refresh nearby Macs")
            }
            if let error = model.discoveryError {
                InlineNotice(title: "Discovery needs attention", message: error)
            }
            if model.hosts.isEmpty {
                HStack(spacing: 15) {
                    ZStack {
                        Circle().fill(CirceStyle.violetWash).frame(width: 50, height: 50)
                        Image(systemName: "antenna.radiowaves.left.and.right").accessibilityHidden(true).font(.system(size: 21, weight: .light)).foregroundStyle(CirceStyle.violet)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Looking for your Macs").font(.system(size: 13, weight: .semibold))
                        Text("Open Circe on the other Mac and turn on sharing.\nMacs on your local network appear here.")
                            .font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk).lineSpacing(3)
                    }
                    Spacer(minLength: 0)
                }.padding(20).frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .background(CirceStyle.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CirceStyle.line, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                    ForEach(model.hosts) { host in
                        HostCard(host: host) { connect(model.connect(to: host)) }
                    }
                }
            }
        }
    }

    @ViewBuilder private var recents: some View {
        if !model.recentConnections.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionEyebrow(title: "Recent connections")
                    Spacer()
                    Button("Clear") { model.clearRecents() }.accessibilityLabel("Clear recent connections").buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                }
                VStack(spacing: 7) {
                    ForEach(model.recentConnections) { recent in
                        Button { connect(model.connect(to: recent)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: recent.nearbyHost?.symbol ?? "clock.arrow.circlepath")
                                    .font(.system(size: 20, weight: .light)).foregroundStyle(CirceStyle.violet).frame(width: 29)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(recent.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text(recent.detail).font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                            }.padding(.horizontal, 15).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(CirceStyle.surface.opacity(0.75), in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(CirceStyle.line))
                                .contentShape(RoundedRectangle(cornerRadius: 11))
                        }.buttonStyle(FocusOutlineButtonStyle()).accessibilityLabel("Reconnect to \(recent.name)").accessibilityValue(recent.detail)
                            .accessibilityHint("Opens a remote desktop session.")
                            .contextMenu { Button("Remove from recents") { model.removeRecent(recent.id) } }
                    }
                }
            }
        }
    }

    private var manualConnection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionEyebrow(title: "Connect by address")
            HStack(spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "network").foregroundStyle(CirceStyle.secondaryInk).accessibilityHidden(true)
                    TextField("Hostname or IP address", text: $address)
                        .textFieldStyle(.plain).font(.system(size: 13)).focused($addressFocused)
                        .onSubmit(connectManually).accessibilityLabel("Remote computer address")
                        .accessibilityHint("Enter a hostname, IP address, or VNC address, then press Return to connect.")
                }.padding(.horizontal, 13).frame(height: 38)
                    .background(CirceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(addressFocused ? CirceStyle.violet : CirceStyle.controlBorder))
                Button("Connect", action: connectManually).accessibilityLabel("Connect to entered address").buttonStyle(PrimaryButtonStyle())
                    .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = addressError {
                Text(error).font(.system(size: 11)).foregroundStyle(CirceStyle.error).accessibilityLabel("Address error: \(error)")
            } else {
                Text("Use a hostname, IP address, or vnc://host for Screen Sharing.")
                    .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            StatusDot(color: model.isHosting ? CirceStyle.green : CirceStyle.secondaryInk.opacity(0.5))
            Text(model.isHosting ? "This Mac is available" : "This Mac is private")
                .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
            Spacer()
            Button { sheet = .sharing } label: {
                HStack(spacing: 5) { Text(model.isHosting ? "Sharing settings" : "Share this Mac"); Image(systemName: "arrow.up.right").font(.system(size: 9)) }
            }.buttonStyle(QuietButtonStyle())
        }.padding(.horizontal, 32).padding(.vertical, 16)
            .background(CirceStyle.surface.opacity(0.5)).overlay(alignment: .top) { Rectangle().fill(CirceStyle.line.opacity(0.65)).frame(height: 1) }
    }

    private func connect(_ session: RemoteSession) { openWindow(value: session.id) }
    private func presentWelcomeIfNeeded() {
        guard sheet == nil, windowReference.window?.isVisible == true else { return }
        if model.claimWelcomePresentation(quietLaunch: CirceStartup.isQuietLaunch) { sheet = .welcome }
    }
    private func connectManually() {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            let endpoint = try ConnectionAddress(value)
            addressError = nil
            connect(model.connect(address: endpoint.normalized))
        } catch { addressError = error.localizedDescription }

    }
}

private struct HostCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let host: NearbyMac
    let action: () -> Void
    @CirceViewState<Bool> private var hovered = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: host.symbol).font(.system(size: 31, weight: .ultraLight)).foregroundStyle(CirceStyle.violet)
                        .frame(height: 37)
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(hovered ? CirceStyle.violet : CirceStyle.secondaryInk.opacity(0.5))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(host.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) { StatusDot(); Text("Ready to connect").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk) }
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(hovered ? CirceStyle.surface : CirceStyle.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 15))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(hovered ? CirceStyle.violet.opacity(0.4) : CirceStyle.line))
                .shadow(color: CirceStyle.violet.opacity(hovered ? 0.07 : 0), radius: 12, y: 5)
                .contentShape(RoundedRectangle(cornerRadius: 15))
        }.buttonStyle(FocusOutlineButtonStyle(cornerRadius: 15)).onHover { hovered = $0 }.animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
            .accessibilityLabel("Connect to \(host.name)").accessibilityHint("Opens a remote desktop session.")
    }
}
