import SwiftUI

public struct CirceSettingsView: View {
    @ObservedObject private var model: CirceModel
    @ObservedObject private var preferences: CircePreferences
    @CirceViewState<Bool> private var showHosting = false
    public init(model: CirceModel) { self.model = model; self.preferences = model.preferences }
    public var body: some View {
        TabView {
            Form {
                Section("Connections") {
                    Toggle("Fit remote display to window", isOn: $preferences.matchesWindowResolution)
                    Text("For new Circe sessions, adjusts the remote Mac’s display resolution as you resize the window. Its previous resolution returns when you disconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Client Accessibility", value: model.accessibilityGranted ? "Allowed" : "Not allowed")
                    if !model.accessibilityGranted {
                        Text("Allow Accessibility on this Mac to send ⌘-Tab and ⌘-Space to the remote computer.").font(.caption).foregroundStyle(.secondary)
                        Button("Allow Accessibility…") { model.requestAccessibility() }
                    }
                    Toggle("Show connection stats", isOn: $preferences.showStats)
                    Text("New sessions use this preference. You can also show or hide stats from the session toolbar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Startup") {
                    Toggle("Open Circe at login", isOn: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                    if model.loginItemStatus == .requiresApproval {
                        Text("Allow Circe in Login Items to finish enabling it.").font(.caption).foregroundStyle(.secondary)
                        Button("Open Login Items…") { model.openLoginSettings() }
                    }
                    if let error = model.loginItemError { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section("Sharing this Mac") {
                    LabeledContent("Computer name", value: model.computerName)
                    LabeledContent("Status", value: model.isHosting ? "Available to connect" : "Private")
                    Button("Set up sharing…") { showHosting = true }
                }
                Section {
                    Text("To release the remote keyboard, press Control–Option–Command–Escape. Full screen: Control–Option–Command–F. Hold these three modifiers to use shortcuts on this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Section("Access") {
                    Toggle("Allow Mac account sign-in", isOn: Binding(get: { model.allowPasswordAuthentication }, set: { model.setPasswordAuthentication($0) }))
                    Text("Connecting computers can sign in with this Mac’s account name and password, or pair using the six-digit code.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Paired computers") {
                    if model.pairedComputers.isEmpty {
                        Text("Computers you pair with this Mac appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
                    } else {
                        ForEach(model.pairedComputers) { peer in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(peer.name).font(.system(size: 12, weight: .medium))
                                    Text(peer.fingerprint).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Forget") { model.forgetComputer(peer.id) }.help("Require \(peer.name) to pair again")
                            }
                        }
                    }
                }
                if !model.fingerprint.isEmpty {
                    Section("This Mac’s fingerprint") {
                        Text(model.fingerprint).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Sharing", systemImage: "person.2") }
            VStack(spacing: 14) {
                CirceMark(size: 78)
                Text("Circe").font(.system(size: 36, weight: .regular, design: .serif)).tracking(-1)
                Text("Your Mac. Wherever you are.").font(.system(size: 13)).foregroundStyle(.secondary)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("Named for the goddess of enchantment.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(CirceStyle.paper).preferredColorScheme(.light)
                .tabItem { Label("About", systemImage: "sparkles") }
        }.frame(width: 520, height: 390).tint(CirceStyle.violet)
            .onAppear { model.refreshPermissions() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
            .sheet(isPresented: $showHosting) { HostingSetupView(model: model) }
    }
}
