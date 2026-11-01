import SwiftUI

public struct AddComputerView: View {
    @ObservedObject private var model: CirceModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @CirceViewState<ComputerDraft> private var draft: ComputerDraft
    @CirceViewState<String?> private var error: String? = nil
    @CirceViewState<Bool> private var copied = false
    private let isEditing: Bool
    public init(model: CirceModel, computer: SavedComputer? = nil) {
        self.model = model; isEditing = computer != nil
        var initial = ComputerDraft(computer: computer)
        // Pin today's gcloud account, so switching accounts in gcloud later can't break this computer.
        if computer == nil { initial.account = model.activeGoogleAccount() ?? "" }
        _draft = CirceViewState(initialValue: initial)
    }
    init(model: CirceModel, draft: ComputerDraft) {
        self.model = model; isEditing = false
        _draft = CirceViewState(initialValue: draft)
    }
    private var status: ComputerSetupStatus? { model.computerSetups[draft.id] }
    private var running: Bool { model.isSettingUp(draft.id) }
    private var displayNumber: Int { min(max(Int(draft.display.replacingOccurrences(of: ":", with: "")) ?? 1, 1), 99) }
    public var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack(spacing: 13) {
                CirceMark(size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(running ? "Setting up your desktop." : isEditing ? "Your computer, remembered." : "A desktop without borders.")
                        .font(.system(size: 26, weight: .regular, design: .serif)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                    Text("Connect securely through SSH or Google Cloud.").font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk)
                }
            }
            if let error { InlineNotice(title: "Check the connection details", message: error) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if running {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(draft.name.isEmpty ? (draft.kind == .googleCloud ? draft.instance : draft.destination) : draft.name).font(.system(size: 14, weight: .semibold))
                            Text((try? draft.computer().detail) ?? "").font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        connectionFields.focusSection()
                        preferences
                    }
                    setup.focusSection()
                }.padding(3)
            }.scrollIndicators(.hidden)
            HStack(spacing: 9) {
                Button(running ? "Close" : "Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if running {
                    Text("Setup keeps running if you close this sheet.").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                } else {
                    Button("Save") { if persist() != nil { dismiss() } }.buttonStyle(QuietButtonStyle())
                    Button("Connect") { if let computer = persist() { connect(computer) } }
                        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }.padding(28).frame(width: 570, height: 690)
            .background(CirceStyle.paper).foregroundStyle(CirceStyle.ink)
            .onChange(of: draft) { _, _ in copied = false; error = nil }
    }
    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Connection", selection: $draft.kind) {
                ForEach(ComputerConnectionKind.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Connection type")
            field("Name", placeholder: "Optional friendly name", text: $draft.name)
            if draft.kind == .googleCloud {
                field("Instance", placeholder: "linux-workstation", text: $draft.instance)
                HStack(alignment: .top, spacing: 12) {
                    field("Zone", placeholder: "us-central1-a", text: $draft.zone)
                    field("Project", placeholder: "Optional project ID", text: $draft.project)
                }
                HStack(alignment: .top, spacing: 12) {
                    field("Google account", placeholder: "gcloud’s active account", text: $draft.account)
                    field("Linux user", placeholder: "Optional", text: $draft.linuxUser).frame(width: 150)
                }
                Toggle("Start this computer when I connect if it’s stopped", isOn: $draft.startsWhenConnecting).toggleStyle(.checkbox).font(.system(size: 12))
                Toggle("Use Identity-Aware Proxy (IAP)", isOn: $draft.useIAP).toggleStyle(.checkbox).font(.system(size: 12))
                Text("Uses this Google account’s gcloud sign-in, even if you switch gcloud accounts, and your SSH access. IAP can reach VMs without a public IP. For a guided setup that finds your computer for you, choose Add a computer → Google Cloud computer.")
                    .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    field("Destination", placeholder: "user@host or SSH alias", text: $draft.destination)
                    field("SSH port", placeholder: "22", text: $draft.sshPort).frame(width: 90)
                }
                Text("Uses your SSH keys and SSH-config aliases. Verify the connection in Terminal first.")
                    .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                field("VNC display", placeholder: "1", text: $draft.display).frame(width: 95)
                Text("Display :\(displayNumber) uses port \(String(5900 + displayNumber)) on the remote computer’s localhost.")
                    .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(CirceStyle.secondaryInk)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel(title)
        }
    }
    private var preferences: some View {
        DisclosureGroup("Connection preferences") {
            VStack(alignment: .leading, spacing: 11) {
                Toggle("⌘ acts as Control", isOn: $draft.commandActsAsControl).accessibilityLabel("Command acts as Control")
                Text("Use ⌘C and ⌘V to copy and paste in Linux apps.").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                Toggle("Play remote audio", isOn: $draft.audioEnabled)
                Toggle("Send this Mac’s microphone", isOn: $draft.microphoneEnabled)
                Toggle("Use smooth video", isOn: $draft.videoEnabled)
                Text("Uses H.264 for motion when available. VNC takes over automatically if video stops.").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                Toggle("Fit remote desktop to window", isOn: $draft.fitsDesktopToWindow)
            }.toggleStyle(.checkbox).font(.system(size: 12)).padding(.top, 9)
        }.font(.system(size: 12)).tint(CirceStyle.primaryFill)
    }
    private var setup: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                SectionEyebrow(title: status == nil ? "First connection?" : "Linux setup")
                Spacer()
                if running { ProgressView().controlSize(.small).accessibilityLabel("Setting up Linux") }
                else { Button(status == nil ? "Set up & connect" : "Run setup again") { startSetup() }.buttonStyle(QuietButtonStyle()) }
            }
            Text("Install a lightweight desktop, audio, and smooth video using passwordless sudo. VNC stays private on localhost; existing VNC passwords are kept.")
                .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            if let status {
                if case .failed(let message) = status.phase { InlineNotice(title: "Setup needs attention", message: message) }
                if status.phase == .running { Text("Setting up Linux… This can take several minutes.").font(.system(size: 12, weight: .medium)) }
                if !status.output.isEmpty {
                    ScrollViewReader { reader in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(status.output).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("end")
                            }.padding(10)
                        }.frame(height: 125).background(CirceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityLabel("Linux setup output")
                            .onChange(of: status.output) { _, _ in reader.scrollTo("end", anchor: .bottom) }
                    }
                }
            }
            HStack(spacing: 8) {
                Text("Prefer Terminal?").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                Button(copied ? "Copied" : "Copy setup command") { copyCommand() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(CirceStyle.violet)
                    .accessibilityHint("Copies a command to run on your Mac that sends the bundled installer to this computer over SSH.")
            }
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(CirceStyle.violetWash, in: RoundedRectangle(cornerRadius: 13))
    }
    private func persist() -> SavedComputer? {
        do { let computer = try draft.computer(); try model.saveComputer(computer); error = nil; return computer }
        catch { self.error = error.localizedDescription; return nil }
    }
    private func connect(_ computer: SavedComputer) {
        let session = model.connect(to: computer); openWindow(value: session.id); dismiss()
    }
    private func startSetup() {
        guard let computer = persist() else { return }
        let open = openWindow, close = dismiss
        model.setUpComputer(computer) { session in open(value: session.id); close() }
    }
    private func copyCommand() {
        do {
            let computer = try draft.computer()
            guard let script = LinuxHostSetup.scriptURL else { throw ComputerValidationError("The Linux installer is missing. Reinstall Circe to restore it.") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(LinuxHostSetup.command(for: computer, scriptURL: script), forType: .string)
            copied = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ComputerSettingsView: View {
    @ObservedObject var model: CirceModel
    @CirceViewState<SavedComputer?> private var editing: SavedComputer? = nil
    @CirceViewState<Bool> private var adding = false
    var body: some View {
        Form {
            if model.computers.isEmpty {
                Section { Text("Save a Linux VM or SSH computer here, then connect from the launcher.").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            ForEach(model.computers) { computer in
                Section {
                    Text(computer.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Toggle("⌘ acts as Control", isOn: setting(computer, \.commandActsAsControl))
                        .accessibilityLabel("Command acts as Control on \(computer.name)")
                    Toggle("Play remote audio", isOn: setting(computer, \.audioEnabled))
                    Toggle("Use smooth video", isOn: setting(computer, \.videoEnabled))
                        .accessibilityLabel("Use smooth video on \(computer.name)")
                    Text("H.264 improves motion when available. VNC takes over automatically if video stops.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Fit remote desktop to window", isOn: setting(computer, \.fitsDesktopToWindow))
                    HStack {
                        Button("Edit connection…") { editing = computer }
                        Spacer()
                        Button("Remove") { model.removeComputer(computer.id) }.accessibilityLabel("Remove saved computer \(computer.name)")
                    }
                } header: { Label(computer.name, systemImage: computer.symbol) }
                    .disabled(model.isSettingUp(computer.id))
            }
            Section {
                Button("Add a computer…") { adding = true }
                Text("Command C and Command V become Control C and Control V when mapping is enabled. Your three-modifier local shortcuts still work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
            .sheet(item: $editing) { AddComputerView(model: model, computer: $0) }
            .sheet(isPresented: $adding) { AddComputerView(model: model) }
    }
    private func setting(_ computer: SavedComputer, _ keyPath: WritableKeyPath<SavedComputer, Bool>) -> Binding<Bool> {
        Binding(get: { model.computers.first(where: { $0.id == computer.id })?[keyPath: keyPath] ?? computer[keyPath: keyPath] }, set: { value in
            guard var updated = model.computers.first(where: { $0.id == computer.id }) else { return }
            updated[keyPath: keyPath] = value
            try? model.saveComputer(updated)
        })
    }
}
