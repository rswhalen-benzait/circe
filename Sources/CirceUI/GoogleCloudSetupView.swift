import SwiftUI

/// Guided Google Cloud setup: account → project → computer → (start) → access checks → desktop → connect.
public struct GoogleCloudSetupView: View {
    @ObservedObject private var model: CirceModel
    @StateObject private var flow: GoogleCloudSetup
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @CirceViewState<Bool> private var copiedRequest = false
    /// "Another Google account" is chosen over the accounts signed in on this Mac.
    @CirceViewState<Bool> private var usingOtherAccount = false

    public init(model: CirceModel, services: CloudServices) {
        self.model = model
        _flow = StateObject(wrappedValue: GoogleCloudSetup(services: services, model: model, suggestedEmail: model.activeGoogleAccount()))
    }
    init(model: CirceModel, flow: GoogleCloudSetup) { self.model = model; _flow = StateObject(wrappedValue: flow) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }.padding(3).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.hidden)
            if flow.adminRequest != nil { adminHandoff }
            footer
        }.padding(28).frame(width: 590, height: 700)
            .background(CirceStyle.paper).foregroundStyle(CirceStyle.ink)
            .onDisappear { flow.cancelRunning() }
            // Set up & connect means connect: open the session right away unless there's something to explain first.
            .onChange(of: flow.step) { _, step in if step == .finished, flow.computer?.startsDesktopOnConnect != true { connectFinished() } }
    }

    // MARK: Frame

    private var titles: (String, String) {
        switch flow.step {
        case .account: return ("Connect your Google Cloud computer.", "Which Google account has access to it?")
        case .project: return ("Choose a project.", "A project is where Google Cloud keeps your computers.")
        case .computer: return ("Choose your computer.", flow.project.map { "In \($0)" } ?? "")
        case .power: return ("Start your computer?", flow.instance?.name ?? "")
        case .access: return ("Checking access.", flow.instance.map { "To \($0.name), through Google’s private connection." } ?? "")
        case .desktop: return ("Choose a desktop.", flow.instance.map { "On \($0.name)" } ?? "")
        case .install: return ("Setting up your desktop.", "This can take a few minutes. You can keep using your Mac.")
        case .finished: return ("Ready.", "From now on, one click connects.")
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            CirceMark(size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(titles.0).font(.system(size: 25, weight: .regular, design: .serif)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                Text(titles.1).font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk).lineLimit(2)
            }
            Spacer()
            if flow.step > .account && flow.step < .finished {
                Text(flow.trimmedEmail).font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).lineLimit(1)
                    .padding(.horizontal, 9).padding(.vertical, 4).background(CirceStyle.violetWash, in: Capsule())
                    .accessibilityLabel("Google account \(flow.trimmedEmail)")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .account: accountStep
        case .project: projectStep
        case .computer: computerStep
        case .power: powerStep
        case .access: accessStep
        case .desktop: desktopStep
        case .install: installStep
        case .finished: finishedStep
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            if flow.step > .account && flow.step != .finished && flow.step != .install {
                Button("Back") { flow.back() }.buttonStyle(QuietButtonStyle())
            }
            Button(flow.step == .finished ? "Done" : "Cancel") { flow.cancelRunning(); dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            Spacer()
            primaryButton
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch flow.step {
        case .account:
            // The sign-in / install cards carry their own action; one primary button per screen.
            if accountNeedsOwnAction { EmptyView() } else {
                Button("Continue") { flow.continueWithAccount(signInIfNeeded: true) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(!flow.emailIsValid || busy)
            }
        case .project:
            if !flow.manualProject.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Use this project") { flow.choose(project: flow.manualProject) }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        case .computer:
            if !flow.manualInstance.isEmpty || !flow.manualZone.isEmpty {
                Button("Find this computer") { flow.chooseManualInstance() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(flow.manualInstance.isEmpty || flow.manualZone.isEmpty)
            }
        case .power:
            Button(flow.instance?.isSuspended == true ? "Resume computer" : "Start computer") { flow.startComputer() }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(isWorking(flow.powerStatus))
        case .access:
            if flow.checks.contains(where: { $0.state == .running }) { ProgressView().controlSize(.small).accessibilityLabel("Checking") }
            else if flow.needsKeyConsent { Button("Check again") { flow.runChecks() }.buttonStyle(QuietButtonStyle()) }
            else { Button("Check again") { flow.runChecks() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
        case .desktop:
            Button(flow.desktopChoice == .install ? (flow.report?.circeInstalled == true ? (flow.report?.circeRunning == true ? "Update & connect" : "Repair & connect") : "Set up & connect") : "Connect") { flow.continueWithDesktop() }
                .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                .disabled(flow.desktopChoice == nil || (flow.desktopChoice == .install && flow.installBlocker != nil))
        case .install: ProgressView().controlSize(.small).accessibilityLabel("Setting up")
        case .finished:
            Button("Connect") { connectFinished() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private var accountNeedsOwnAction: Bool {
        switch flow.accountState { case .needsTools, .needsSignIn, .signingIn, .wrongAccount, .installingTools: return true; default: return false }
    }
    private var busy: Bool {
        switch flow.accountState { case .checking, .signingIn, .installingTools: return true; default: return false }
    }
    private func isWorking(_ status: GoogleCloudSetup.Status) -> Bool { if case .working = status { return true }; return false }

    @ViewBuilder private func statusView(_ status: GoogleCloudSetup.Status) -> some View {
        switch status {
        case .idle: EmptyView()
        case .working(let text): HStack(spacing: 9) { ProgressView().controlSize(.small); Text(text).font(.system(size: 12)) }
        case .failed(let text): InlineNotice(title: "Needs attention", message: text)
        }
    }

    // MARK: Account

    private var accountStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !flow.knownAccounts.isEmpty {
                // Accounts already signed in on this Mac, one already chosen; nothing happens until Continue.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Signed in on this Mac").font(.system(size: 11, weight: .medium)).foregroundStyle(CirceStyle.secondaryInk)
                    ForEach(flow.knownAccounts, id: \.email) { account in
                        radioRow(title: account.email, detail: account.isActive ? "Google Cloud CLI’s current account" : nil,
                                 selected: !showsOtherAccountField && flow.knownAccount(flow.email)?.email == account.email) {
                            usingOtherAccount = false; flow.email = account.email
                        }
                    }
                    radioRow(title: "Another Google account", detail: nil, selected: showsOtherAccountField) {
                        if !showsOtherAccountField { usingOtherAccount = true; flow.email = "" }
                    }
                }
            }
            if showsOtherAccountField {
                field("Google email", placeholder: "you@example.com", text: $flow.email)
                    .onSubmit { if flow.emailIsValid { flow.continueWithAccount(signInIfNeeded: true) } }
            }
            switch flow.accountState {
            case .unknown, .signedIn: EmptyView()
            case .checking: HStack(spacing: 9) { ProgressView().controlSize(.small); Text("Checking your Google sign-in…").font(.system(size: 12)) }
            case .needsTools:
                card(title: "Circe needs Google’s connection tools",
                     message: "Circe downloads Google’s official Cloud tools (about 80 MB) and keeps them inside Circe’s own folder. Nothing else on your Mac changes.") {
                    Button("Install Google Cloud tools") { flow.installTools() }.buttonStyle(PrimaryButtonStyle())
                }
            case .installingTools(let line): HStack(spacing: 9) { ProgressView().controlSize(.small); Text(line).font(.system(size: 12)) }
            case .needsSignIn(let expired):
                card(title: expired ? "Sign in again" : "Sign in to Google",
                     message: expired ? "Google needs you to sign in again as \(flow.trimmedEmail)." :
                        "Circe opens Google’s sign-in page in your browser. Sign in as \(flow.trimmedEmail), then come back here.") {
                    Button("Sign in with Google") { flow.signIn() }.buttonStyle(PrimaryButtonStyle())
                }
            case let .signingIn(page, needsCode):
                card(title: needsCode ? "Enter the code from Google" : "Finish signing in in your browser",
                     message: needsCode ? "After you sign in as \(flow.trimmedEmail), Google shows a verification code. Paste it here." :
                        "Use \(flow.trimmedEmail). Complete any security check Google asks for — Circe never sees your Google password.") {
                    VStack(alignment: .leading, spacing: 10) {
                        if needsCode {
                            HStack(spacing: 8) {
                                SecureField("Verification code", text: $flow.signInCode).textFieldStyle(.roundedBorder).frame(width: 260)
                                    .accessibilityLabel("Verification code").onSubmit { flow.submitSignInCode() }
                                Button("Continue") { flow.submitSignInCode() }.buttonStyle(PrimaryButtonStyle()).disabled(flow.signInCode.isEmpty)
                            }
                        }
                        HStack(spacing: 8) {
                            if !needsCode { ProgressView().controlSize(.small) }
                            if let page { Button(needsCode ? "Open the sign-in page" : "Open the sign-in page again") { NSWorkspace.shared.open(page) }.buttonStyle(QuietButtonStyle()) }
                            if !needsCode { Button("Use a code instead") { flow.signIn(useCode: true) }.buttonStyle(QuietButtonStyle()) }
                            Button("Cancel") { flow.cancelRunning(); flow.continueWithAccount(signInIfNeeded: false) }.buttonStyle(QuietButtonStyle())
                        }
                    }
                }
            case .wrongAccount(let actual):
                card(title: "You signed in as \(actual)", message: "Circe expected \(flow.trimmedEmail). Use the account you signed in with, or sign in again with the other one.") {
                    HStack {
                        Button("Use \(actual)") { flow.useSignedInAccount(actual) }.buttonStyle(PrimaryButtonStyle())
                        Button("Sign in as \(flow.trimmedEmail)") { flow.signIn() }.buttonStyle(QuietButtonStyle())
                    }
                }
            case .failed(let message): InlineNotice(title: "Needs attention", message: message)
            }
        }
    }

    // MARK: Project

    private var projectStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !flow.projects.isEmpty {
                TextField("Search projects", text: $flow.projectQuery).textFieldStyle(.roundedBorder).accessibilityLabel("Search projects")
                VStack(spacing: 6) {
                    ForEach(flow.filteredProjects.prefix(200)) { project in
                        row(title: project.name, detail: project.name == project.id ? nil : project.id) { flow.choose(project: project.id) }
                    }
                    if flow.filteredProjects.count > 200 { Text("Showing 200 of \(flow.filteredProjects.count). Search to narrow the list.").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk) }
                }
            }
            statusView(flow.projectsStatus)
            VStack(alignment: .leading, spacing: 5) {
                Text("Or enter a project ID").font(.system(size: 11, weight: .medium)).foregroundStyle(CirceStyle.secondaryInk)
                TextField("my-project-123", text: $flow.manualProject).textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel("Project ID")
                    .onSubmit { flow.choose(project: flow.manualProject) }
            }.padding(.top, 4)
        }
    }

    // MARK: Computer

    private var computerStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if flow.instances.count > 6 {
                TextField("Search computers", text: $flow.instanceQuery).textFieldStyle(.roundedBorder).accessibilityLabel("Search computers")
            }
            VStack(spacing: 6) {
                ForEach(flow.filteredInstances.prefix(200)) { instance in
                    row(title: instance.name, detail: [instance.statusText, instance.zone, instance.machineType, instance.gpu].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                        badge: instance.isRunning ? nil : instance.statusText) { flow.choose(instance) }
                }
            }
            statusView(flow.instancesStatus)
            DisclosureGroup("Enter a computer’s name and zone") {
                HStack(alignment: .top, spacing: 12) {
                    field("Computer name", placeholder: "linux-workstation", text: $flow.manualInstance)
                    field("Zone", placeholder: "us-central1-a", text: $flow.manualZone).frame(width: 170)
                }.padding(.top, 8)
            }.font(.system(size: 12)).tint(CirceStyle.primaryFill)
        }
    }

    // MARK: Power

    private var powerStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let instance = flow.instance {
                card(title: "\(instance.name) is \(instance.statusText.lowercased())", message: flow.startWarning) {
                    Toggle("Start it automatically whenever I connect", isOn: $flow.startsWhenConnecting).toggleStyle(.checkbox).font(.system(size: 12))
                }
            }
            statusView(flow.powerStatus)
        }
    }

    // MARK: Access

    private var accessStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(flow.checks) { check in
                HStack(alignment: .top, spacing: 11) {
                    Group {
                        switch check.state {
                        case .pending: Image(systemName: "circle").foregroundStyle(CirceStyle.line)
                        case .running: ProgressView().controlSize(.small)
                        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(CirceStyle.violet)
                        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        }
                    }.frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(check.title).font(.system(size: 13, weight: .semibold))
                        switch check.state {
                        case .ok(let detail): Text(detail).font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
                        case .failed(let message): Text(message).font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
                        default: EmptyView()
                        }
                    }
                }.accessibilityElement(children: .combine)
            }
            if flow.needsKeyConsent {
                card(title: "\(flow.instance?.name ?? "This computer") doesn’t recognize this Mac yet",
                     message: "Circe can ask Google Cloud to add this Mac’s sign-in key for \(flow.trimmedEmail) — to your Google Linux profile, or to this computer. Your private key never leaves this Mac.") {
                    VStack(alignment: .leading, spacing: 10) {
                        Button("Add this Mac’s key") { flow.authorizeKey() }.buttonStyle(PrimaryButtonStyle())
                        DisclosureGroup("I sign in to it with a specific Linux user") {
                            HStack(spacing: 8) {
                                TextField("Linux user", text: $flow.manualLinuxUser).textFieldStyle(.roundedBorder).frame(width: 180).accessibilityLabel("Linux user")
                                Button("Try this user") { flow.retryLinuxUser() }.buttonStyle(QuietButtonStyle()).disabled(flow.manualLinuxUser.isEmpty)
                            }.padding(.top, 6)
                        }.font(.system(size: 12)).tint(CirceStyle.primaryFill)
                    }
                }
            }
        }
    }

    // MARK: Desktop

    @ViewBuilder private func existingDesktops(_ desktops: [CloudDesktop]) -> some View {
        ForEach(desktops) { desktop in
            choice(.existing(desktop), title: "\(desktop.title) · Display \(desktop.display)", detail: desktop.isWayland
                   ? "Uses the desktop that’s already running. Smooth video isn’t available for it yet."
                   : "Uses a desktop already running on this computer. It may have its own VNC password.")
        }
    }

    private var desktopStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let report = flow.report {
                if report.circeInstalled, report.circeRunning, let display = report.circeDisplay {
                    choice(.circe(display: display), title: "Circe desktop", detail: "Already set up on this computer.")
                }
                if report.circeInstalled, report.circeRunning, !report.availableDesktops.isEmpty {
                    DisclosureGroup("Other desktops (\(report.availableDesktops.count))") {
                        existingDesktops(report.availableDesktops).padding(.top, 8)
                    }.font(.system(size: 12)).tint(CirceStyle.secondaryInk)
                } else {
                    existingDesktops(report.availableDesktops)
                }
                if report.circeInstalled && report.circeRunning && !report.circeCurrent {
                    choice(.install, title: "Update Circe’s desktop", detail: report.systemDesktop.map { "Shows this computer’s own \($0) desktop, with all its apps." }
                           ?? "Adds the newest improvements, like an Applications menu.")
                } else if report.circeInstalled && !report.circeRunning {
                    choice(.install, title: "Repair Circe’s desktop", detail: "It was set up before but isn’t running. Circe can finish setting it up and start it.")
                } else if !report.circeInstalled {
                    choice(.install, title: report.availableDesktops.isEmpty ? "Set up a desktop" : "Set up a separate Circe desktop",
                           detail: report.availableDesktops.isEmpty ? "\(report.osName.isEmpty ? "This computer" : report.osName) doesn’t have a desktop Circe can show yet." : "A private desktop just for Circe, next to what’s there.")
                }
                if flow.desktopChoice == .install && report.withoutAdmin && report.sudo == "password" {
                    // Only when both ways can actually run: no-password first, because many accounts have no Linux password.
                    Picker("How to set up", selection: $flow.installWithoutAdmin) {
                        Text("No password needed (recommended)").tag(true)
                        Text("With \(report.user)’s Linux password, for everyone on this computer").tag(false)
                    }.pickerStyle(.radioGroup).font(.system(size: 12)).accessibilityLabel("How to set up the desktop")
                }
                if flow.desktopChoice == .install {
                    if let blocker = flow.installBlocker { InlineNotice(title: "Can’t set up here", message: blocker) }
                    else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Setup will:").font(.system(size: 11, weight: .medium)).foregroundStyle(CirceStyle.secondaryInk)
                            ForEach(flow.installPlan, id: \.self) { line in
                                HStack(alignment: .top, spacing: 7) { Text("•"); Text(line).fixedSize(horizontal: false, vertical: true) }.font(.system(size: 11))
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(CirceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        if flow.needsSudoPassword && !flow.installWithoutAdmin {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Linux password for \(report.user)").font(.system(size: 11, weight: .medium)).foregroundStyle(CirceStyle.secondaryInk)
                                SecureField("Password", text: $flow.sudoPassword).textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel("Linux password")
                                    .onSubmit { flow.continueWithDesktop() }
                                Text("Installing software on this computer needs it. This isn’t your Google password; Circe uses it once and doesn’t save it.")
                                    .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                statusView(flow.installStatus)
                if !report.sessions.filter({ ["chrome-remote-desktop", "xrdp", "sunshine"].contains($0) }).isEmpty {
                    Text(otherServicesNote(report.sessions)).font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
                }
            }
            Toggle("Start this computer automatically when I connect", isOn: $flow.startsWhenConnecting).toggleStyle(.checkbox).font(.system(size: 12))
            Text("Otherwise Circe asks first, because a running computer costs money.").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
        }
    }

    private func otherServicesNote(_ sessions: [String]) -> String {
        var names: [String] = []
        if sessions.contains("chrome-remote-desktop") { names.append("Chrome Remote Desktop") }
        if sessions.contains("xrdp") { names.append("Remote Desktop (RDP)") }
        if sessions.contains("sunshine") { names.append("Moonlight (Sunshine)") }
        return "This computer also has \(names.joined(separator: " and ")). Circe leaves \(names.count == 1 ? "it" : "them") as \(names.count == 1 ? "it is" : "they are")."
    }

    private func choice(_ value: GoogleCloudSetup.DesktopChoice, title: String, detail: String) -> some View {
        radioRow(title: title, detail: detail, selected: flow.desktopChoice == value) { flow.desktopChoice = value }
    }

    /// The email field shows when no account is signed in on this Mac, or "Another Google account" is chosen.
    private var showsOtherAccountField: Bool {
        flow.knownAccounts.isEmpty || usingOtherAccount || flow.knownAccount(flow.email) == nil
    }

    private func radioRow(title: String, detail: String?, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").foregroundStyle(CirceStyle.violet).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
            }.padding(13).background(CirceStyle.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? CirceStyle.violet : CirceStyle.line))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Install / finished

    private var installStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusView(flow.installStatus)
            if !flow.installOutput.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView { Text(flow.installOutput).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 220).padding(8).background(CirceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
                }.font(.system(size: 12)).tint(CirceStyle.primaryFill)
            }
        }
    }

    private var finishedStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let computer = flow.computer {
                Text("\(computer.name) is saved on this Mac.").font(.system(size: 14, weight: .semibold))
                if computer.startsDesktopOnConnect {
                    InlineNotice(title: "Your desktop runs while you’re connected",
                                 message: "This computer doesn’t let \(computer.name)’s desktop keep running on its own, so Circe starts it each time you connect. Save your work before disconnecting: open apps close shortly afterwards.")
                }
                Text("Click it in the launcher to connect. Circe signs in with \(flow.trimmedEmail)\(computer.startsWhenConnecting ? " and starts the computer if it’s stopped" : ", and asks before starting the computer if it’s stopped").")
                    .font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connectFinished() {
        guard let computer = flow.computer else { return }
        let session = model.connect(to: computer); openWindow(value: session.id); dismiss()
    }

    // MARK: Administrator handoff

    private var adminHandoff: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.key").foregroundStyle(CirceStyle.violet).accessibilityHidden(true)
            Text("Someone who manages this Google Cloud project can fix this.").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(copiedRequest ? "Copied" : "Copy a request for them") { flow.copyAdminRequest(); copiedRequest = true }
                .buttonStyle(QuietButtonStyle()).help(flow.adminRequestText)
        }.padding(12).background(CirceStyle.violetWash, in: RoundedRectangle(cornerRadius: 11))
            .onChange(of: flow.adminRequest) { _, _ in copiedRequest = false }
    }

    // MARK: Pieces

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(CirceStyle.secondaryInk)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).controlSize(.large).accessibilityLabel(title)
        }
    }

    private func row(title: String, detail: String?, badge: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if let detail, !detail.isEmpty { Text(detail).font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk).lineLimit(1) }
                }
                Spacer()
                if let badge { Text(badge).font(.system(size: 10, weight: .medium)).padding(.horizontal, 7).padding(.vertical, 3).background(CirceStyle.violetWash, in: Capsule()) }
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(CirceStyle.violet).accessibilityHidden(true)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(CirceStyle.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(CirceStyle.line))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(FocusOutlineButtonStyle(cornerRadius: 11)).accessibilityLabel(title).accessibilityValue(detail ?? "")
    }

    private func card<Actions: View>(title: String, message: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            actions().padding(.top, 3)
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(CirceStyle.violetWash, in: RoundedRectangle(cornerRadius: 13))
    }
}
