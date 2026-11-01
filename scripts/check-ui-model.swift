import AppKit
import Carbon
import Foundation
import SwiftUI

@main struct UIModelChecks {
    @MainActor static func main() throws {
        func rgb(_ color: Color, _ appearance: NSAppearance) -> [Double] {
            var channels: [Double] = []
            appearance.performAsCurrentDrawingAppearance {
                let resolved = NSColor(color).usingColorSpace(.sRGB)!
                channels = [Double(resolved.redComponent), Double(resolved.greenComponent), Double(resolved.blueComponent)]
            }
            return channels
        }
        func luminance(_ channels: [Double]) -> Double {
            let c = channels.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return c[0] * 0.2126 + c[1] * 0.7152 + c[2] * 0.0722
        }
        var lowest = Double.infinity
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = NSAppearance(named: name)!
            let pairs: [(String, Color, Color, Double)] = [
                ("primary text", CirceStyle.ink, CirceStyle.paper, 4.5),
                ("secondary text", CirceStyle.secondaryInk, CirceStyle.paper, 4.5),
                ("secondary on surface", CirceStyle.secondaryInk, CirceStyle.surface, 4.5),
                ("accent", CirceStyle.violet, CirceStyle.paper, 4.5),
                ("notice text", CirceStyle.secondaryInk, CirceStyle.violetWash, 4.5),
                ("errors", CirceStyle.error, CirceStyle.paper, 4.5),
                ("primary button", .white, CirceStyle.primaryFill, 4.5),
                ("control boundary", CirceStyle.controlBorder, CirceStyle.surface, 3)
            ]
            for (label, foreground, background, minimum) in pairs {
                let f = luminance(rgb(foreground, appearance)), b = luminance(rgb(background, appearance))
                let ratio = (max(f, b) + 0.05) / (min(f, b) + 0.05)
                precondition(ratio >= minimum, "\(name): \(label) contrast is \(ratio)")
                if minimum == 4.5 { lowest = min(lowest, ratio) }
            }
        }
        print(String(format: "Light/dark contrast checks passed; lowest text ratio %.2f:1", lowest))
        let suite = "com.circe.ui-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CircePreferences(defaults: defaults)
        let model = CirceModel(preferences: preferences)
        let clutteredReport = CloudHostReport(user: "u", osName: "Ubuntu", packageManager: "apt", sudo: "none", adminGroup: false,
            systemd: true, circeInstalled: true, circeDisplay: 1, circeRunning: true,
            desktops: [.init(display: 3, process: "Xvnc"), .init(display: 1, process: "Xtigervnc"),
                       .init(display: 3, process: "Xvnc"), .init(display: 0, process: "wayvnc")], sessions: [])
        precondition(clutteredReport.availableDesktops.map(\.display) == [0, 3], "One option per desktop, never duplicate Circe's own display")

        var cloud = ComputerDraft()
        cloud.instance = "linux-workstation"; cloud.zone = "us-central1-a"
        let cloudComputer = try cloud.computer()
        precondition(cloudComputer.commandActsAsControl && cloudComputer.audioEnabled && cloudComputer.videoEnabled && cloudComputer.fitsDesktopToWindow)
        precondition(cloudComputer.vncPort == 5901)
        if case .googleCloud(_, _, let project, let iap, let account, let user, let alias, _) = cloudComputer.connection { precondition(project == nil && iap && account == nil && user == nil && alias == nil) } else { preconditionFailure() }
        try model.saveComputer(cloudComputer)
        precondition(CirceModel(preferences: CircePreferences(defaults: defaults)).computers == [cloudComputer])
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode([cloudComputer])) as! [[String: Any]]
        legacy[0].removeValue(forKey: "videoEnabled")
        defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "savedComputers.v1")
        let migrated = CirceModel(preferences: CircePreferences(defaults: defaults))
        precondition(migrated.computers.count == 1 && migrated.computers[0].videoEnabled, "Existing computer profiles must survive adding the video preference")
        var ssh = ComputerDraft(); ssh.kind = .ssh; ssh.destination = "Dev@my-vm"; ssh.sshPort = "2222"; ssh.display = ":2"
        let sshComputer = try ssh.computer()
        precondition(sshComputer.vncPort == 5902)
        for invalid in ["-oProxyCommand=bad", "user@host command", "ssh://host", "user@host;command", "user@"] {
            var bad = ssh; bad.destination = invalid; precondition((try? bad.computer()) == nil)
        }
        let command = LinuxHostSetup.command(for: sshComputer, scriptURL: URL(fileURLWithPath: "/Applications/Circe's Mac.app/Contents/Resources/Linux/setup-circe-host.sh"))
        precondition(command.contains("'2222'") && command.contains("'Dev@my-vm'") && command.contains("--display 2") && command.contains("'\"'\"'"))
        // Profiles saved before per-computer Google accounts existed must still load (byte-for-byte shape).
        let beforeAccounts = #"[{"commandActsAsControl":true,"audioEnabled":true,"connection":{"googleCloud":{"zone":"us-east4-a","project":"p-1","useIAP":true,"instance":"vm-1"}},"fitsDesktopToWindow":true,"name":"VM","id":"4904FE34-B4AC-4ED5-8AD7-7E9EF5E378E1","videoEnabled":true,"display":1}]"#
        let accountSuite = "com.circe.ui-checks.\(UUID().uuidString)"
        let accountDefaults = UserDefaults(suiteName: accountSuite)!
        defer { accountDefaults.removePersistentDomain(forName: accountSuite) }
        accountDefaults.set(Data(beforeAccounts.utf8), forKey: "savedComputers.v1")
        let olderModel = CirceModel(preferences: CircePreferences(defaults: accountDefaults))
        precondition(olderModel.computers.count == 1, "Profiles without a Google account must survive the upgrade")
        if case let .googleCloud(i, _, p, _, a, u, alias, _) = olderModel.computers[0].connection { precondition(i == "vm-1" && p == "p-1" && a == nil && u == nil && alias == nil) } else { preconditionFailure() }
        precondition(!olderModel.computers[0].startsWhenConnecting, "Older profiles must not start VMs automatically")
        precondition(olderModel.activeGoogleAccount() == nil, "Without the engine there is no gcloud account to report")
        var pinned = ComputerDraft(computer: olderModel.computers[0])
        precondition(pinned.account.isEmpty && pinned.linuxUser.isEmpty)
        pinned.account = " me@example.org "; pinned.linuxUser = "developer"
        let pinnedComputer = try pinned.computer()
        if case let .googleCloud(_, _, _, _, a, u, _, _) = pinnedComputer.connection { precondition(a == "me@example.org" && u == "developer") } else { preconditionFailure() }
        precondition(pinnedComputer.detail == "developer@vm-1 · us-east4-a · IAP · me@example.org")
        let reloaded = ComputerDraft(computer: pinnedComputer)
        precondition(reloaded.account == pinned.withTrimmedIdentity.account && reloaded.linuxUser == "developer", "Editing must show the saved account and user")
        guard case let .googleCloud(_, _, _, _, _, _, derivedAlias, _) = pinnedComputer.connection else { preconditionFailure() }
        precondition(derivedAlias == "circe-gce-p-1-us-east4-a-vm-1", "Account + project + user: ssh over IAP with its own host-key pin")
        try olderModel.saveComputer(pinnedComputer)
        precondition(CirceModel(preferences: CircePreferences(defaults: accountDefaults)).computers == [pinnedComputer])
        for invalid in ["-me@example.org", "me", "me@", "me@example.org --flag", "me@exam\nple.org"] {
            var bad = pinned; bad.account = invalid; precondition((try? bad.computer()) == nil, "Rejected account \(invalid)")
        }
        for invalid in ["-oProxy", "developer@host", "developer smith", "1developer", String(repeating: "a", count: 33)] {
            var bad = pinned; bad.linuxUser = invalid; precondition((try? bad.computer()) == nil, "Rejected user \(invalid)")
        }
        let pinnedCommand = LinuxHostSetup.command(for: pinnedComputer, scriptURL: URL(fileURLWithPath: "/tmp/setup.sh"))
        precondition(pinnedCommand.contains("'developer@vm-1'") && pinnedCommand.contains("'--account=me@example.org'") && pinnedCommand.contains("'--project' 'p-1'"))
        precondition(!LinuxHostSetup.command(for: cloudComputer, scriptURL: URL(fileURLWithPath: "/tmp/setup.sh")).contains("--account"))
        var updatedComputer = cloudComputer; updatedComputer.commandActsAsControl = false; updatedComputer.videoEnabled = false
        try model.saveComputer(updatedComputer)
        precondition(model.computers.count == 1 && !model.computers[0].commandActsAsControl)
        precondition(!CirceModel(preferences: CircePreferences(defaults: defaults)).computers[0].videoEnabled)
        var setupCalls = 0, setupConnections = 0
        var setupCompletion: ((Result<SavedComputer, Error>) -> Void)?
        model.onSetupComputer = { computer, completion in
            setupCalls += 1; setupCompletion = completion
            model.appendSetupOutput("Installing desktop", for: computer.id)
            model.appendSetupOutput("New VNC password (shown only this time): SECRET12", for: computer.id)
            model.appendSetupOutput("CIRCE_SETUP_RESULT {\"password\":\"SECRET12\"}", for: computer.id)
        }
        model.onConnectComputer = { computer in let session = RemoteSession(name: computer.name, address: computer.detail); session.phase = .streaming; return session }
        model.setUpComputer(updatedComputer) { _ in setupConnections += 1 }
        model.setUpComputer(updatedComputer) { _ in preconditionFailure("Duplicate setup must be ignored") }
        precondition(setupCalls == 1 && model.isSettingUp(updatedComputer.id))
        precondition(!(model.computerSetups[updatedComputer.id]?.output.contains("SECRET12") ?? true))
        setupCompletion?(.success(updatedComputer))
        precondition(setupConnections == 1 && model.computerSetups[updatedComputer.id]?.phase == .complete)
        precondition(model.computers[0].lastConnected != nil)
        for id in Array(model.sessions.keys) { model.closeSession(id) }
        model.removeComputer(updatedComputer.id)
        precondition(CirceModel(preferences: CircePreferences(defaults: defaults)).computers.isEmpty)
        // Repeated clicks, wizard re-adds and reconnects all reuse one window/transport per desktop.
        var connectionsCreated = 0, connectionsRetried = 0, connectionsClosed = 0
        model.onConnectComputer = { computer in
            connectionsCreated += 1
            let session = RemoteSession(name: computer.name, address: computer.detail)
            session.onReconnect = { connectionsRetried += 1 }
            return session
        }
        model.onCloseSession = { _ in connectionsClosed += 1 }
        let firstDesktop = model.connect(to: pinnedComputer)
        precondition(model.connect(to: pinnedComputer) === firstDesktop && connectionsCreated == 1,
                     "A rapid second click must not create a second connection")
        firstDesktop.phase = .pairing
        precondition(model.connect(to: pinnedComputer) === firstDesktop, "A waiting password prompt belongs to the existing session")
        var renamedDesktop = pinnedComputer
        renamedDesktop.id = UUID(); renamedDesktop.name = "Renamed desktop"
        renamedDesktop.audioEnabled.toggle(); renamedDesktop.microphoneEnabled.toggle()
        renamedDesktop.commandActsAsControl.toggle(); renamedDesktop.startsWhenConnecting.toggle()
        firstDesktop.phase = .streaming
        precondition(model.connect(to: renamedDesktop) === firstDesktop && connectionsCreated == 1,
                     "A wizard re-add or preference change must focus the existing desktop")
        firstDesktop.phase = .reconnecting(1)
        precondition(model.connect(to: renamedDesktop) === firstDesktop && connectionsRetried == 0,
                     "Automatic reconnect must not be duplicated by another Connect click")
        firstDesktop.phase = .disconnected("Network dropped")
        precondition(model.connect(to: renamedDesktop) === firstDesktop && connectionsRetried == 1 && firstDesktop.phase == .connecting,
                     "Reconnect must reuse the window and its engine")
        firstDesktop.reconnect()
        precondition(connectionsRetried == 1, "A second Reconnect while connecting must be ignored")
        var anotherDisplay = pinnedComputer; anotherDisplay.display += 1
        precondition(model.connect(to: anotherDisplay) !== firstDesktop, "Another display is a different desktop")
        var anotherUser = pinnedComputer
        anotherUser.connection = .googleCloud(instance: "vm-1", zone: "us-east4-a", project: "p-1", useIAP: true,
                                             account: "me@example.org", user: "someone_else", hostKeyAlias: derivedAlias)
        precondition(model.connect(to: anotherUser) !== firstDesktop, "Another Linux user must get its own session")
        var replacement = pinnedComputer
        replacement.connection = .googleCloud(instance: "vm-1", zone: "us-east4-a", project: "p-1", useIAP: true,
                                             account: "me@example.org", user: "developer", hostKeyAlias: "circe-gce-9999")
        precondition(model.connect(to: replacement) !== firstDesktop, "A replaced machine must not reuse the old pinned connection")
        var editedMachine = pinnedComputer
        editedMachine.connection = .googleCloud(instance: "different-vm", zone: "us-east4-a", project: "p-1", useIAP: true,
                                               account: "me@example.org", user: "developer", hostKeyAlias: derivedAlias)
        precondition(model.connect(to: editedMachine) !== firstDesktop, "Editing a saved row to another VM must not focus its old session")
        model.closeSession(firstDesktop.id)
        let reopenedDesktop = model.connect(to: pinnedComputer)
        precondition(reopenedDesktop !== firstDesktop && connectionsClosed == 1, "Closing the window releases its desktop for a fresh connection")
        // An omitted SSH port can come from ~/.ssh/config and differs from an explicit port.
        let sshDefault = SavedComputer(name: "SSH", connection: .ssh(destination: "me@host", port: nil))
        let sshExplicit = SavedComputer(name: "SSH again", connection: .ssh(destination: "me@host", port: 22))
        let sshSession = model.connect(to: sshDefault)
        precondition(model.connect(to: sshDefault) === sshSession)
        precondition(model.connect(to: sshExplicit) !== sshSession, "An SSH-config port and an explicit port must not be conflated")
        for id in Array(model.sessions.keys) { model.closeSession(id) }
        print("Saved desktop connection reuse checks passed")
        preferences.accessibilityHintShown = false
        precondition(!model.claimWelcomePresentation(quietLaunch: true), "Quiet login must not present onboarding")
        precondition(!preferences.hasSeenWelcome, "Quiet login must preserve the first deliberate welcome")
        precondition(model.claimWelcomePresentation(quietLaunch: false))
        precondition(!model.claimWelcomePresentation(quietLaunch: false), "Only one launcher can claim the welcome")
        let nextLaunch = CirceModel(preferences: CircePreferences(defaults: defaults))
        precondition(!nextLaunch.claimWelcomePresentation(quietLaunch: false), "Welcome must stay dismissed across relaunch")
        precondition(!preferences.shareThisMac, "Presenting or skipping welcome must not enable sharing")
        var sharingRequests: [Bool] = []
        var shutdowns = 0
        model.onHostToggle = { sharingRequests.append($0) }
        model.onShutdown = { shutdowns += 1 }
        model.setHosting(true)
        precondition(CircePreferences(defaults: defaults).shareThisMac)
        model.shutdown()
        precondition(CircePreferences(defaults: defaults).shareThisMac, "Quitting must preserve sharing")
        precondition(sharingRequests == [true] && shutdowns == 1)
        model.setHosting(false)
        precondition(!CircePreferences(defaults: defaults).shareThisMac)
        precondition(sharingRequests == [true, false])
        precondition(LoginItemStatus.enabled.isRegistered && LoginItemStatus.requiresApproval.isRegistered)
        precondition(!LoginItemStatus.notRegistered.isRegistered && !LoginItemStatus.unavailable.isRegistered)
        preferences.matchesWindowResolution = true
        precondition(CircePreferences(defaults: defaults).matchesWindowResolution)
        let session = RemoteSession(name: "Display check", address: "localhost")
        session.videoMode = .h264(encoder: "nvenc"); session.fps = 28.4
        precondition(session.videoStatus == "Video: H.264 (NVENC) · 28 fps", "Show measured FPS, not the helper's requested FPS")
        session.videoMode = .vnc
        precondition(session.videoStatus == "Video: VNC")
        session.setScale(.actual)
        session.setMatchesWindowResolution(true)
        precondition(session.scale == .fit && session.matchesWindowResolution)
        session.setScale(.actual)
        precondition(!session.matchesWindowResolution)
        var releases = 0
        session.onReleaseKeyboard = { releases += 1 }
        session.phase = .connecting
        session.releaseKeyboard()
        precondition(releases == 0, "Local Accessibility actions must not send input before authentication")
        session.phase = .streaming
        session.releaseKeyboard()
        precondition(releases == 1)
        session.isDraggingFiles = true
        session.phase = .reconnecting(1)
        precondition(!session.isDraggingFiles, "A lost connection must clear the drop affordance")
        let history = RecentConnectionsStore(defaults: defaults)
        history.record(host: nil, address: "vnc://user:secret@host", name: "Invalid")
        precondition(history.connections.isEmpty, "History must never store credential-bearing input")
        history.record(host: nil, address: "studio.local:5900", name: "Studio")
        history.record(host: nil, address: "vnc://STUDIO.local:5900", name: "Studio updated")
        precondition(history.connections.count == 1 && history.connections[0].transport == .vnc)
        let service = BonjourServiceAddress(name: "Studio Mac", type: "_circe._tcp", domain: "local.")
        let nearby = NearbyMac(id: "device-key", name: "Studio Mac", address: service.displayAddress, service: service)
        history.record(host: nearby, address: nearby.address, name: nearby.name)
        let restored = RecentConnectionsStore(defaults: defaults)
        precondition(restored.connections[0].nearbyHost?.service == service, "Bonjour routes must survive relaunch")
        for index in 0..<10 { history.record(host: nil, address: "mac\(index).local", name: "Mac \(index)") }
        precondition(history.connections.count == RecentConnectionsStore.limit && history.connections[0].name == "Mac 9")
        let historyModel = CirceModel(preferences: preferences)
        historyModel.onConnect = { _, address in
            let failed = RemoteSession(name: "Failed", address: address)
            failed.phase = .disconnected("Unavailable")
            return failed
        }
        let failed = historyModel.connect(address: "failed.local")
        precondition(historyModel.recentConnections[0].name == "Mac 9", "Failed attempts must not replace recents")
        historyModel.closeSession(failed.id)
        historyModel.onConnect = { _, address in
            let connected = RemoteSession(name: "Connected Mac", address: address)
            connected.phase = .streaming
            return connected
        }
        let connected = historyModel.connect(address: "connected.local")
        precondition(historyModel.recentConnections[0].name == "Connected Mac")
        precondition(connected.showAccessibilityHint && preferences.accessibilityHintShown)
        connected.dismissAccessibilityHint()
        precondition(!connected.showAccessibilityHint)
        let secondConnection = historyModel.connect(address: "second.local")
        precondition(!secondConnection.showAccessibilityHint, "Accessibility hint must only appear once")
        historyModel.closeSession(secondConnection.id)
        historyModel.closeSession(connected.id)
        historyModel.clearRecents()
        precondition(RecentConnectionsStore(defaults: defaults).connections.isEmpty)
        let login = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        login.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: AEKeyword(keyAEPropData))
        precondition(CirceStartup.isLoginLaunch(event: login, arguments: []))
        precondition(!CirceStartup.isLoginLaunch(event: nil, arguments: []))
        precondition(CirceStartup.isLoginLaunch(event: nil, arguments: ["Circe", "--background"]))
        CirceStartup.configure(sharingEnabled: false, event: login, arguments: [])
        precondition(!CirceStartup.isQuietLaunch)
        CirceStartup.configure(sharingEnabled: true, event: login, arguments: [])
        precondition(CirceStartup.isQuietLaunch)
        try CloudSetupChecks.run()
        print("UI model checks passed: one-time welcome, sharing persistence, quit semantics, login status, display matching, recent connections, quiet launch policy, and Google Cloud setup.")
    }
}

extension ComputerDraft {
    var withTrimmedIdentity: ComputerDraft {
        var copy = self
        copy.account = account.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.linuxUser = linuxUser.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }
}

/// The Google Cloud setup flow against scripted engine answers, recording every operation so cloud writes and
/// secrets can be audited.
@MainActor
enum CloudSetupChecks {
    @MainActor final class Fake {
        var ledger: [String] = []
        var account = "me@example.org"
        lazy var credential: [String: CloudCredential] = [account: .valid]
        var signInReturns = "me@example.org"
        var instances: [CloudInstance] = []
        var tunnelAnswers: [CloudReachability] = [.reachable]
        var osLogin: String?
        var logins: [String: CloudLogin] = [:]
        var authorizeReturns: Result<String, CloudError> = .success("developer")
        var report = CloudHostReport(user: "developer", osName: "Omarchy", packageManager: "pacman", sudo: "password", adminGroup: true, systemd: true,
                                     circeInstalled: false, circeDisplay: nil, circeRunning: false, desktops: [CloudDesktop(display: 0, process: "wayvnc")],
                                     sessions: ["Hyprland", "wayvnc", "sunshine"])
        var setupAnswers: [Result<SavedComputer, CloudSetupError>] = []
        var describeAnswers: [CloudInstance] = []
        var keysSeen: [String?] = []
        var passwordsSeen: [String?] = []

        func services() -> CloudServices {
            CloudServices(
                isInstalled: { true },
                install: { _, done in self.ledger.append("install"); done(.success(())); return CloudCancel {} },
                accounts: { done in done(.success([CloudAccount(email: "other@example.org", isActive: true), CloudAccount(email: "me@example.org", isActive: false)])) },
                credential: { account, done in self.ledger.append("credential \(account)"); done(.success(self.credential[account] ?? .notSignedIn)) },
                signIn: { account, _, _, done in self.ledger.append("signIn \(account)"); self.credential[self.signInReturns] = .valid; done(.success(self.signInReturns)); return CloudCancel {} },
                projects: { account, done in self.ledger.append("projects \(account)"); done(.success([CloudProject(id: "demo-workstations", name: "Demo Workstations"), CloudProject(id: "other-1", name: "other-1")])) },
                instances: { account, project, done in self.ledger.append("instances \(account) \(project)"); done(.success(self.instances)) },
                instance: { _, _, zone, name, done in
                    self.ledger.append("describe \(name)")
                    if !self.describeAnswers.isEmpty { done(.success(self.describeAnswers.removeFirst())) }
                    else { done(.failure(CloudError(.permissionDenied("compute.instances.get"), "denied"))) } },
                start: { account, project, instance, progress, done in
                    self.ledger.append("START \(account) \(project) \(instance.name)"); progress("STAGING"); done(.success(())); return CloudCancel {} },
                checkTunnel: { account, _, _, done in self.ledger.append("tunnel \(account)"); done(.success(self.tunnelAnswers.count > 1 ? self.tunnelAnswers.removeFirst() : self.tunnelAnswers[0])) },
                osLoginUser: { _, _, done in done(self.osLogin) },
                pinHostKeys: { _, _, _, done in done(true) },
                verifyLogin: { computer, done in
                    guard case let .googleCloud(_, _, _, _, account, user?, alias, _) = computer.connection else { preconditionFailure() }
                    precondition(account == self.account && alias != nil, "Every check is account-pinned and host-key-pinned")
                    if case let .googleCloud(_, _, _, _, _, _, _, key) = computer.connection { self.keysSeen.append(key) }
                    self.ledger.append("verify \(user)"); done(self.logins[user] ?? .keyRefused) },
                authorizeKey: { account, _, _, user, done in self.ledger.append("AUTHORIZE \(account) \(user ?? "-")"); done(self.authorizeReturns) },
                probe: { computer, done in self.ledger.append("probe"); done(.success(self.report)); return CloudCancel {} },
                setUp: { computer, password, withoutAdmin, output, done in
                    if withoutAdmin { self.ledger.append("SETUP-NOADMIN") }
                    self.ledger.append("SETUP \(computer.display)"); self.passwordsSeen.append(password); output("Installing desktop")
                    precondition(computer.isVerifiedGoogleCloud, "Setup runs over the verified, pinned route")
                    done(self.setupAnswers.isEmpty ? .success(computer) : self.setupAnswers.removeFirst()); return CloudCancel {} },
                localUserName: { "macuser" })
        }
    }

    static func spin(_ what: String, until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !done() && Date() < deadline { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        precondition(done(), "Timed out waiting for: \(what)")
    }

    static func run() throws {
        let suite = "com.circe.ui-checks.cloud.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CirceModel(preferences: CircePreferences(defaults: defaults))

        // Omarchy-like: stopped GPU VM, custom Linux user from metadata, existing wayvnc desktop.
        let fake = Fake()
        fake.account = "developer@example.org"
        fake.instances = [
            CloudInstance(instanceID: "1", name: "build-box", zone: "us-east1-b", status: "RUNNING", machineType: "e2-small", gpu: nil, suggestedUsers: [], hostKeyAlias: "circe-gce-1"),
            CloudInstance(instanceID: "123456789", name: "developer-omarchy", zone: "us-central1-a", status: "TERMINATED", machineType: "g2-standard-8",
                          gpu: "NVIDIA L4", suggestedUsers: ["developer"], hostKeyAlias: "circe-gce-123456789")]
        fake.tunnelAnswers = [.backendUnreachable, .reachable] // still booting, then SSH answers
        fake.logins = ["developer": .ok(user: "developer", uid: 1000)]
        let flow = GoogleCloudSetup(services: fake.services(), model: model, suggestedEmail: nil)
        flow.delayScale = 0.001
        precondition(flow.email == "other@example.org", "Prefills gcloud's active account")
        flow.email = "developer@example.org"
        flow.continueWithAccount()
        precondition(flow.step == .project && flow.projects.count == 2, "A valid sign-in goes straight to projects")
        flow.choose(project: "demo-workstations")
        precondition(flow.step == .computer && flow.instances.first?.name == "developer-omarchy", "Computers named after the account come first, even stopped")
        flow.choose(flow.instances[0])
        precondition(flow.step == .power && flow.startWarning.contains("NVIDIA L4") && flow.startWarning.contains("charges"), "Stopped GPU VM asks first, with cost")
        precondition(!fake.ledger.contains { $0.hasPrefix("START") }, "Nothing starts without the user")
        flow.startComputer()
        spin("desktop step") { flow.step == .desktop }
        precondition(fake.ledger.filter { $0.hasPrefix("tunnel") }.count == 2, "Waits for SSH after a start")
        precondition(fake.ledger.contains("verify developer") && !fake.ledger.contains("verify macuser"), "Metadata user is tried before the Mac's user name")
        precondition(flow.desktopChoice == .existing(CloudDesktop(display: 0, process: "wayvnc")), "An existing desktop is preferred over installing")
        flow.continueWithDesktop()
        precondition(flow.step == .finished, "Using an existing desktop needs no setup or password")
        precondition(!fake.ledger.contains { $0.hasPrefix("SETUP") || $0.hasPrefix("AUTHORIZE") }, "No install or key changes for an existing desktop")
        guard let saved = flow.computer, case let .googleCloud(name, zone, project, iap, account, user, alias, _) = saved.connection else { preconditionFailure() }
        precondition(name == "developer-omarchy" && zone == "us-central1-a" && project == "demo-workstations" && iap && account == "developer@example.org" && user == "developer"
                     && alias == "circe-gce-123456789" && saved.display == 0 && !saved.videoEnabled && saved.isVerifiedGoogleCloud)
        precondition(model.computers.contains(saved), "Finished computers are saved")
        precondition(!saved.commandActsAsControl, "Existing wayvnc desktops keep Command as Super for compositor shortcuts")

        // Managed-workstation-like: wrong account in the browser, OS Login user, Ubuntu with CRD, sudo needs a password.
        let fake2 = Fake()
        fake2.credential = [:]
        fake2.signInReturns = "personal@example.com"
        fake2.instances = [CloudInstance(instanceID: "694", name: "work-vm", zone: "us-east4-a", status: "RUNNING", machineType: "e2-standard-8", gpu: nil, suggestedUsers: [], hostKeyAlias: "circe-gce-694")]
        fake2.osLogin = "me_example_org"
        fake2.logins = ["me_example_org": .ok(user: "me_example_org", uid: 1504780708)]
        fake2.report = CloudHostReport(user: "me_example_org", osName: "Ubuntu 24.04.5 LTS", packageManager: "apt", sudo: "password", adminGroup: true, systemd: true,
                                       circeInstalled: false, circeDisplay: nil, circeRunning: false, desktops: [], sessions: ["gnome-shell", "xrdp", "chrome-remote-desktop"])
        fake2.setupAnswers = [.failure(CloudSetupError(code: "sudo_password_incorrect", message: "no"))]
        let flow2 = GoogleCloudSetup(services: fake2.services(), model: model, suggestedEmail: "me@example.org")
        flow2.delayScale = 0.001
        flow2.continueWithAccount()
        precondition(flow2.accountState == .needsSignIn(expired: false))
        flow2.signIn()
        precondition(flow2.accountState == .wrongAccount(actual: "personal@example.com"), "A different browser account is caught, not silently used")
        fake2.signInReturns = "me@example.org"
        flow2.signIn()
        precondition(flow2.step == .project)
        flow2.choose(project: "work-project")
        flow2.choose(flow2.instances[0])
        spin("work desktop step") { flow2.step == .desktop }
        precondition(fake2.ledger.first(where: { $0.hasPrefix("verify") }) == "verify me_example_org", "OS Login's user name is tried first")
        precondition(flow2.desktopChoice == .install && flow2.installBlocker == nil && flow2.needsSudoPassword)
        precondition(flow2.installPlan.contains { $0.contains("apt") } && flow2.installPlan.contains { $0.contains("as it is") })
        precondition(!flow2.installWithoutAdmin, "Without the capability, the password path is the only one")
        flow2.continueWithDesktop()
        precondition(flow2.step == .desktop && !fake2.ledger.contains { $0.hasPrefix("SETUP") }, "No setup without the needed password")
        flow2.sudoPassword = "wrong"
        flow2.continueWithDesktop()
        precondition(flow2.step == .desktop && flow2.installStatus == .failed("That Linux password wasn’t accepted. Try again.") && flow2.sudoPassword.isEmpty,
                     "A rejected password is cleared and explained")
        flow2.sudoPassword = "right"
        flow2.continueWithDesktop()
        precondition(flow2.step == .finished && fake2.passwordsSeen == ["wrong", "right"] && flow2.sudoPassword.isEmpty)
        precondition(flow2.computer?.commandActsAsControl == true, "New Circe XFCE desktops retain Command as Control")
        let savedText = String(decoding: try JSONEncoder().encode(model.computers), as: UTF8.self)
        precondition(!savedText.contains("right") && !savedText.contains("wrong"), "The Linux password is never saved")

        // Key not yet authorized: ask, then publish once and verify.
        let fake3 = Fake()
        fake3.instances = [CloudInstance(instanceID: "7", name: "plain", zone: "us-west1-a", status: "RUNNING", machineType: "e2-micro", gpu: nil, suggestedUsers: [], hostKeyAlias: "circe-gce-7")]
        let flow3 = GoogleCloudSetup(services: fake3.services(), model: model, suggestedEmail: "me@example.org")
        flow3.delayScale = 0.001
        flow3.continueWithAccount(); flow3.choose(project: "p"); flow3.choose(flow3.instances[0])
        spin("key consent") { flow3.needsKeyConsent }
        precondition(!fake3.ledger.contains { $0.hasPrefix("AUTHORIZE") }, "Keys are only published after the user agrees")
        precondition(fake3.ledger.filter { $0.hasPrefix("verify") }.count == 1, "Only evidence-based user names are tried")
        fake3.logins["developer"] = .ok(user: "developer", uid: 1001)
        flow3.authorizeKey()
        spin("desktop after key") { flow3.step == .desktop }
        precondition(fake3.ledger.filter { $0.hasPrefix("AUTHORIZE") }.count == 1)

        // Wrong account for IAP: a precise request for the administrator.
        let fake4 = Fake()
        fake4.instances = [fake3.instances[0]]
        fake4.tunnelAnswers = [.notAuthorized]
        let flow4 = GoogleCloudSetup(services: fake4.services(), model: model, suggestedEmail: "me@example.org")
        flow4.continueWithAccount(); flow4.choose(project: "p"); flow4.choose(flow4.instances[0])
        precondition(flow4.adminRequest == .tunnel && flow4.adminRequestText.contains("roles/iap.tunnelResourceAccessor") && flow4.adminRequestText.contains("me@example.org"))
        precondition(!fake4.ledger.contains { $0.hasPrefix("verify") }, "No sign-in attempts after IAP refuses")

        // Codex review: a typed sudo password never follows the user to another computer.
        let fake5 = Fake()
        fake5.instances = [CloudInstance(instanceID: "10", name: "vm-a", zone: "z-a", status: "RUNNING", machineType: "", gpu: nil, suggestedUsers: ["u"], hostKeyAlias: "circe-gce-10"),
                           CloudInstance(instanceID: "11", name: "vm-b", zone: "z-b", status: "RUNNING", machineType: "", gpu: nil, suggestedUsers: ["u"], hostKeyAlias: "circe-gce-11")]
        fake5.logins = ["u": .ok(user: "u", uid: 1000)]
        fake5.report = CloudHostReport(user: "u", osName: "Ubuntu", packageManager: "apt", sudo: "password", adminGroup: true, systemd: true,
                                       circeInstalled: false, circeDisplay: nil, circeRunning: false, desktops: [], sessions: [])
        let flow5 = GoogleCloudSetup(services: fake5.services(), model: model, suggestedEmail: "me@example.org")
        flow5.delayScale = 0.001
        flow5.continueWithAccount(); flow5.choose(project: "p"); flow5.choose(flow5.instances.first { $0.name == "vm-a" }!)
        spin("vm-a desktop") { flow5.step == .desktop }
        flow5.sudoPassword = "A_ONLY"
        flow5.back()
        precondition(flow5.sudoPassword.isEmpty, "Back clears the password")
        flow5.sudoPassword = "A_ONLY"
        flow5.choose(flow5.instances.first { $0.name == "vm-b" }!)
        spin("vm-b desktop") { flow5.step == .desktop }
        precondition(flow5.sudoPassword.isEmpty, "Choosing another computer clears the password")
        flow5.continueWithDesktop()
        precondition(!fake5.passwordsSeen.contains("A_ONLY"), "VM A's password is never sent to VM B")

        // Codex review: a computer that is shutting down is watched, never started without consent.
        let fake6 = Fake()
        let stopping = CloudInstance(instanceID: "12", name: "busy", zone: "z", status: "STOPPING", machineType: "", gpu: "NVIDIA L4", suggestedUsers: [], hostKeyAlias: "circe-gce-12")
        var stopped = stopping; stopped.status = "TERMINATED"
        fake6.instances = [stopping]
        fake6.describeAnswers = [stopping, stopped]
        let flow6 = GoogleCloudSetup(services: fake6.services(), model: model, suggestedEmail: "me@example.org")
        flow6.delayScale = 0.001
        flow6.continueWithAccount(); flow6.choose(project: "p"); flow6.choose(flow6.instances[0])
        precondition(flow6.step == .power)
        spin("settled to stopped") { flow6.instance?.status == "TERMINATED" && flow6.powerStatus == .idle }
        precondition(!fake6.ledger.contains { $0.hasPrefix("START") }, "A computer that just stopped isn't restarted on its own")

        // Codex review: another Google account starts from a clean slate.
        let fake7 = Fake()
        fake7.credential["other@example.org"] = .valid
        let flow7 = GoogleCloudSetup(services: fake7.services(), model: model, suggestedEmail: "me@example.org")
        flow7.continueWithAccount()
        precondition(flow7.projects.count == 2)
        flow7.back(); flow7.email = "other@example.org"; flow7.continueWithAccount()
        precondition(fake7.ledger.contains("projects other@example.org"), "Projects are reloaded for the new account")

        // Codex review: half-installed Circe desktop is repaired, on a free display; ssh-config logins carry their key.
        let fake8 = Fake()
        var keyed = CloudInstance(instanceID: "13", name: "agent", zone: "us-west1-a", status: "RUNNING", machineType: "", gpu: nil, suggestedUsers: [], hostKeyAlias: "circe-gce-13")
        keyed.sshConfigLogins = [CloudSSHLogin(user: "developer", keyFile: "~/.ssh/agent_key")]
        fake8.instances = [keyed]
        fake8.logins = ["developer": .ok(user: "developer", uid: 1000)]
        fake8.report = CloudHostReport(user: "developer", osName: "Omarchy", packageManager: "pacman", sudo: "passwordless", adminGroup: true, systemd: true,
                                       circeInstalled: true, circeDisplay: nil, circeRunning: false, desktops: [], sessions: [])
        fake8.report.usedDisplays = [0, 1, 20]
        let flow8 = GoogleCloudSetup(services: fake8.services(), model: model, suggestedEmail: "me@example.org")
        flow8.delayScale = 0.001
        flow8.continueWithAccount(); flow8.choose(project: "p"); flow8.choose(flow8.instances[0])
        spin("agent desktop") { flow8.step == .desktop }
        precondition(fake8.ledger.first { $0.hasPrefix("verify") } == "verify developer" && fake8.keysSeen.first == "~/.ssh/agent_key", "The Mac's existing login and key are tried first")
        precondition(flow8.desktopChoice == .install && flow8.installPlan.first?.contains("Repairs") == true, "Not running is not ready")
        flow8.continueWithDesktop()
        precondition(fake8.ledger.contains("SETUP 2"), "A separate desktop goes on a free display")
        guard case let .googleCloud(_, _, _, _, _, _, _, savedKey) = flow8.computer?.connection else { preconditionFailure() }
        precondition(savedKey == "~/.ssh/agent_key")

        // No sudo: set up into the user's own folder, no password asked or sent.
        let fake9 = Fake()
        fake9.instances = [CloudInstance(instanceID: "14", name: "locked", zone: "us-east1-c", status: "RUNNING", machineType: "", gpu: nil, suggestedUsers: ["u"], hostKeyAlias: "circe-gce-14")]
        fake9.logins = ["u": .ok(user: "u", uid: 1000)]
        fake9.report = CloudHostReport(user: "u", osName: "Ubuntu", packageManager: "apt", sudo: "none", adminGroup: false, systemd: true,
                                       circeInstalled: false, circeDisplay: nil, circeRunning: false, desktops: [], sessions: [])
        fake9.report.withoutAdmin = true
        let flow9 = GoogleCloudSetup(services: fake9.services(), model: model, suggestedEmail: "me@example.org")
        flow9.delayScale = 0.001
        flow9.continueWithAccount(); flow9.choose(project: "p"); flow9.choose(flow9.instances[0])
        spin("locked desktop") { flow9.step == .desktop }
        precondition(flow9.installWithoutAdmin && flow9.installBlocker == nil && flow9.installPlan.contains { $0.contains("No administrator password") })
        flow9.continueWithDesktop()
        precondition(flow9.step == .finished && fake9.passwordsSeen == [nil] && fake9.ledger.contains("SETUP-NOADMIN"), "No sudo: installs without a password")
        fake9.report.withoutAdmin = false
        let flow10 = GoogleCloudSetup(services: fake9.services(), model: model, suggestedEmail: "me@example.org")
        flow10.delayScale = 0.001
        flow10.continueWithAccount(); flow10.choose(project: "p"); flow10.choose(flow10.instances[0])
        spin("locked desktop 2") { flow10.step == .desktop }
        precondition(flow10.installBlocker != nil, "Neither path possible: say so plainly")
        precondition(flow10.adminRequest == .sudo, "…and the request for an administrator is offered without pressing a disabled button")
        flow10.continueWithDesktop()
        precondition(flow10.adminRequest == .sudo && flow10.adminRequestText.contains("sudo apt-get install") && flow10.adminRequestText.contains("sudo loginctl enable-linger u")
                     && !flow10.adminRequestText.contains("github"), "The administrator gets exact commands for this computer")

        // sudo refused although the account could install privately: carry on without asking again.
        let fake11 = Fake()
        fake11.instances = [CloudInstance(instanceID: "15", name: "shared", zone: "us-east1-c", status: "RUNNING", machineType: "", gpu: nil, suggestedUsers: ["u"], hostKeyAlias: "circe-gce-15")]
        fake11.logins = ["u": .ok(user: "u", uid: 1000)]
        fake11.report = CloudHostReport(user: "u", osName: "Ubuntu", packageManager: "apt", sudo: "passwordless", adminGroup: false, systemd: true,
                                        circeInstalled: false, circeDisplay: nil, circeRunning: false, desktops: [], sessions: [])
        fake11.report.withoutAdmin = true
        fake11.setupAnswers = [.failure(CloudSetupError(code: "sudo_not_allowed", message: "no"))]
        let flow11 = GoogleCloudSetup(services: fake11.services(), model: model, suggestedEmail: "me@example.org")
        flow11.delayScale = 0.001
        flow11.continueWithAccount(); flow11.choose(project: "p"); flow11.choose(flow11.instances[0])
        spin("shared desktop") { flow11.step == .desktop }
        flow11.installWithoutAdmin = false
        flow11.continueWithDesktop()
        spin("private fallback") { flow11.step == .finished }
        precondition(fake11.ledger.filter { $0.hasPrefix("SETUP ") }.count == 2 && fake11.ledger.contains("SETUP-NOADMIN") && flow11.adminRequest == nil,
                     "A refused sudo falls straight through to the private install")

        // A computer with its own desktop (GNOME…): Circe shows it rather than installing XFCE.
        let fake18 = Fake()
        fake18.instances = [CloudInstance(instanceID: "18", name: "gnome-vm", zone: "us-east4-a", status: "RUNNING", machineType: "", gpu: nil, suggestedUsers: ["u"], hostKeyAlias: "circe-gce-18")]
        fake18.logins = ["u": .ok(user: "u", uid: 1000)]
        fake18.report = CloudHostReport(user: "u", osName: "Ubuntu 24.04.5 LTS", packageManager: "apt", sudo: "password", adminGroup: true, systemd: true,
                                        circeInstalled: false, circeDisplay: nil, circeRunning: false, desktops: [], sessions: ["chrome-remote-desktop"])
        fake18.report.systemDesktop = "Ubuntu"; fake18.report.withoutAdmin = true
        let flow18 = GoogleCloudSetup(services: fake18.services(), model: model, suggestedEmail: "me@example.org")
        flow18.delayScale = 0.001
        flow18.continueWithAccount(); flow18.choose(project: "p"); flow18.choose(flow18.instances[0])
        spin("own desktop") { flow18.step == .desktop }
        precondition(flow18.installPlan.first == "This computer’s own Ubuntu desktop, with all its apps" && !flow18.installPlan.joined().contains("XFCE"), "\(flow18.installPlan)")
        flow18.installWithoutAdmin = false
        precondition(flow18.installPlan.contains("Installs TigerVNC with apt") && !flow18.installPlan.joined().contains("XFCE"), "Only TigerVNC is installed")
        // Set up by an older Circe (its light desktop): an update is offered first, keeping the password.
        let fake19 = Fake()
        fake19.instances = fake18.instances; fake19.logins = fake18.logins
        fake19.report = fake18.report; fake19.report.circeInstalled = true; fake19.report.circeDisplay = 1; fake19.report.circeRunning = true
        fake19.report.circeCurrent = false
        let flow19 = GoogleCloudSetup(services: fake19.services(), model: model, suggestedEmail: "me@example.org")
        flow19.delayScale = 0.001
        flow19.continueWithAccount(); flow19.choose(project: "p"); flow19.choose(flow19.instances[0])
        spin("older desktop") { flow19.step == .desktop }
        precondition(flow19.desktopChoice == .install && flow19.installPlan.first?.contains("Updates Circe’s desktop") == true, "\(flow19.installPlan)")
        // Showing an open Chrome Remote Desktop session: ⌘ arrives as Super, like Chrome Remote Desktop sends it.
        fake19.report.circeCurrent = true; fake19.report.circeShared = "chrome-remote-desktop"
        let flow20 = GoogleCloudSetup(services: fake19.services(), model: model, suggestedEmail: "me@example.org")
        flow20.delayScale = 0.001
        flow20.continueWithAccount(); flow20.choose(project: "p"); flow20.choose(flow20.instances[0])
        spin("shared session") { flow20.step == .desktop }
        precondition(flow20.desktopChoice == .circe(display: 1))
        flow20.continueWithDesktop()
        spin("shared session saved") { flow20.computer != nil }
        precondition(flow20.computer?.commandActsAsControl == false, "Command is Super in a shared Chrome Remote Desktop session")

        // A computer that needs a newer C library: an exact "please update" request for the administrator.
        let fake15 = Fake()
        fake15.instances = [fake11.instances[0]]
        fake15.logins = ["u": .ok(user: "u", uid: 1000)]
        fake15.report = fake11.report; fake15.report.sudo = "none"
        fake15.setupAnswers = [.failure(CloudSetupError(code: "system_outdated", message: "updates needed"))]
        let flow15 = GoogleCloudSetup(services: fake15.services(), model: model, suggestedEmail: "me@example.org")
        flow15.delayScale = 0.001
        flow15.continueWithAccount(); flow15.choose(project: "p"); flow15.choose(flow15.instances[0])
        spin("outdated desktop") { flow15.step == .desktop }
        flow15.continueWithDesktop()
        spin("outdated result") { flow15.adminRequest != nil }
        precondition(flow15.adminRequest == .updates && flow15.adminRequestText.contains("sudo apt-get update && sudo apt-get upgrade"))

        // Opening the wizard with an account already signed in on this Mac waits on the account step with it
        // chosen: the person picks the account (nothing is checked, nothing opens) and presses Continue.
        let fake12 = Fake()
        let flow12 = GoogleCloudSetup(services: fake12.services(), model: model, suggestedEmail: "me@example.org")
        precondition(flow12.step == .account && flow12.email == "me@example.org" && flow12.accountState == .unknown && fake12.ledger.isEmpty,
                     "Add a computer never skips choosing the account")
        precondition(flow12.knownAccounts.count == 2 && flow12.knownAccount("ME@example.org ")?.email == "me@example.org" && flow12.knownAccount("x@example.org") == nil)
        flow12.email = "other@example.org"
        precondition(flow12.step == .account && fake12.ledger.isEmpty)
        flow12.continueWithAccount(signInIfNeeded: true)
        precondition(fake12.ledger == ["credential other@example.org", "signIn other@example.org"], "Continue checks (and signs in) the chosen account")
        // With no suggestion, gcloud's active account is chosen — still waiting for Continue.
        let fake12b = Fake()
        let flow12b = GoogleCloudSetup(services: fake12b.services(), model: model, suggestedEmail: nil)
        precondition(flow12b.step == .account && flow12b.email == "other@example.org" && fake12b.ledger.isEmpty)
        // Changing the account after a check drops that check's result.
        let fake13 = Fake(); fake13.credential = ["me@example.org": .expired]
        let flow13 = GoogleCloudSetup(services: fake13.services(), model: model, suggestedEmail: "me@example.org")
        precondition(flow13.step == .account && !fake13.ledger.contains { $0.hasPrefix("signIn") }, "No unasked browser")
        flow13.continueWithAccount()
        precondition(flow13.accountState == .needsSignIn(expired: true) && !fake13.ledger.contains { $0.hasPrefix("signIn") })
        flow13.email = "other@example.org"; precondition(flow13.accountState == .unknown)
        flow13.email = "me@example.org"; flow13.continueWithAccount()
        precondition(flow13.accountState == .needsSignIn(expired: true))
        // Pressing Continue is asking: it goes straight to Google's sign-in.
        flow13.continueWithAccount(signInIfNeeded: true)
        precondition(fake13.ledger.contains("signIn me@example.org") && flow13.step == .project, "Continue signs in when needed (one click, not two)")
        // A Linux user typed for one computer doesn't stick to the next one.
        let fake14 = Fake()
        fake14.instances = [CloudInstance(instanceID: "21", name: "a", zone: "us-east1-b", status: "RUNNING", machineType: "", gpu: nil, suggestedUsers: [], hostKeyAlias: "circe-gce-21"),
                            CloudInstance(instanceID: "22", name: "b", zone: "us-east1-b", status: "RUNNING", machineType: "", gpu: nil, suggestedUsers: ["osl_user"], hostKeyAlias: "circe-gce-22")]
        fake14.logins = ["osl_user": .ok(user: "osl_user", uid: 1000)]
        let flow14 = GoogleCloudSetup(services: fake14.services(), model: model, suggestedEmail: "me@example.org")
        flow14.delayScale = 0.001
        flow14.continueWithAccount(); flow14.choose(project: "p"); flow14.choose(flow14.instances[0])
        spin("key consent a") { flow14.needsKeyConsent }
        flow14.manualLinuxUser = "developer"
        flow14.back(); flow14.choose(flow14.instances[1])
        spin("b signs in") { flow14.linuxUser == "osl_user" }
        precondition(flow14.manualLinuxUser.isEmpty && !fake14.ledger.contains("verify developer"), "Automatic detection works on the next computer")
        // Setting up the same machine again keeps its own choices; a machine with a new identity starts fresh.
        var kept = SavedComputer(name: "b", connection: .googleCloud(instance: "b", zone: "us-east1-b", project: "p", useIAP: true, account: "me@example.org", user: "osl_user",
                                                                      hostKeyAlias: "circe-gce-22", keyFile: nil))
        kept.microphoneEnabled = false; kept.startsDesktopOnConnect = true
        try model.saveComputer(kept)
        let redo = flow14.draftComputer(user: "osl_user", display: 1)
        precondition(redo.id == kept.id && redo.microphoneEnabled == false && redo.startsDesktopOnConnect, "Same machine: choices kept")
        var replaced = kept; replaced.connection = .googleCloud(instance: "b", zone: "us-east1-b", project: "p", useIAP: true, account: "me@example.org", user: "osl_user", hostKeyAlias: "circe-gce-99", keyFile: nil)
        try model.saveComputer(replaced)
        precondition(!flow14.draftComputer(user: "osl_user", display: 1).startsDesktopOnConnect, "Replaced machine: lifetime is learned again")
        model.removeComputer(kept.id)
        // Re-running setup for the same machine keeps the person's choices; a replaced machine forgets the old password first.
        var mine = SavedComputer(name: "My VM", connection: .googleCloud(instance: "b", zone: "us-east1-b", project: "p", useIAP: true, account: "me@example.org",
                                 user: "osl_user", hostKeyAlias: "circe-gce-22", keyFile: nil), display: 0, commandActsAsControl: false, audioEnabled: false,
                                 videoEnabled: false, fitsDesktopToWindow: false, startsWhenConnecting: true)
        mine.microphoneEnabled = true
        try model.saveComputer(mine)
        var replacedIDs: [UUID] = []
        model.onComputerReplaced = { replacedIDs.append($0.id) }
        let fake16 = Fake()
        fake16.instances = [fake14.instances[1]]
        fake16.logins = ["osl_user": .ok(user: "osl_user", uid: 1000)]
        fake16.report.desktops = [CloudDesktop(display: 0, process: "wayvnc")]
        let flow16 = GoogleCloudSetup(services: fake16.services(), model: model, suggestedEmail: "me@example.org")
        flow16.delayScale = 0.001
        flow16.continueWithAccount(); flow16.choose(project: "p"); flow16.choose(flow16.instances[0])
        precondition(flow16.startsWhenConnecting, "Same machine: its auto-start approval is shown as given")
        spin("same desktop step") { flow16.step == .desktop }
        flow16.continueWithDesktop()
        let again = model.computers.first { $0.id == mine.id }!
        precondition(again.name == "My VM" && !again.commandActsAsControl && !again.audioEnabled && !again.videoEnabled && !again.fitsDesktopToWindow
                     && again.microphoneEnabled && again.startsWhenConnecting && replacedIDs.isEmpty, "Same machine: every choice kept, nothing forgotten")
        var otherVM = fake14.instances[1]; otherVM.instanceID = "77"; otherVM.hostKeyAlias = "circe-gce-77"
        fake16.instances = [otherVM]
        let flow17 = GoogleCloudSetup(services: fake16.services(), model: model, suggestedEmail: "me@example.org")
        flow17.delayScale = 0.001
        flow17.continueWithAccount(); flow17.choose(project: "p"); flow17.choose(flow17.instances[0])
        precondition(!flow17.startsWhenConnecting, "A replaced machine needs its own approval to start")
        spin("replaced desktop step") { flow17.step == .desktop }
        flow17.continueWithDesktop()
        let replacedSaved = model.computers.first { $0.id == mine.id }!
        precondition(replacedIDs == [mine.id] && !replacedSaved.microphoneEnabled && replacedSaved.commandActsAsControl == false, "Replaced: old password forgotten, consent reset")
        model.onComputerReplaced = nil
        model.removeComputer(mine.id)

        // Editing a saved computer to point at another machine drops what belonged to the old one.
        var moved = ComputerDraft(computer: kept); moved.instance = "c"
        let movedComputer = try moved.computer()
        precondition(!movedComputer.startsDesktopOnConnect && !movedComputer.microphoneEnabled, "Another machine: lifetime and mic consent reset")
        var renamed = ComputerDraft(computer: kept); renamed.name = "Work"
        let renamedComputer = try renamed.computer(); precondition(renamedComputer.startsDesktopOnConnect, "Same machine: kept")
        var sshComputer = SavedComputer(name: "box", connection: .ssh(destination: "me@127.0.0.1", port: 2231))
        sshComputer.microphoneEnabled = true; sshComputer.startsDesktopOnConnect = true
        var portMoved = ComputerDraft(computer: sshComputer); portMoved.sshPort = "2232"
        let portMovedComputer = try portMoved.computer()
        precondition(!portMovedComputer.microphoneEnabled && !portMovedComputer.startsDesktopOnConnect, "Another port can be another machine")
        var portSame = ComputerDraft(computer: sshComputer); portSame.name = "Box"
        let portSameComputer = try portSame.computer()
        precondition(portSameComputer.microphoneEnabled && portSameComputer.startsDesktopOnConnect, "Same endpoint: kept")

        // Codex review: editing a verified computer keeps the read-only IAP route and resets auto-start for another machine.
        var verified = SavedComputer(name: "vm", connection: .googleCloud(instance: "vm", zone: "us-east1-b", project: "p", useIAP: true, account: "alex@example.org", user: "developer",
                                                                          hostKeyAlias: "circe-gce-9", keyFile: "~/.ssh/k"), startsWhenConnecting: true)
        var editDraft = ComputerDraft(computer: verified)
        editDraft.linuxUser = "alice"
        guard case let .googleCloud(_, _, _, _, _, _, alias1, key1) = try editDraft.computer().connection else { preconditionFailure() }
        precondition(alias1 == "circe-gce-9" && key1 == nil, "Same machine, new login: host trust kept, key not reused")
        var cleared = ComputerDraft(computer: verified); cleared.linuxUser = ""
        precondition((try? cleared.computer()) == nil, "A Circe-verified computer can't drop to gcloud compute ssh")
        let sameMachine = try editDraft.computer()
        precondition(sameMachine.startsWhenConnecting, "Same machine keeps its auto-start choice")
        editDraft = ComputerDraft(computer: verified); editDraft.instance = "other-vm"
        let otherMachine = try editDraft.computer()
        precondition(!otherMachine.startsWhenConnecting, "Auto-start doesn't follow the name to another machine")
        let manual = SavedComputer(name: "m", connection: .googleCloud(instance: "vm", zone: "us-east1-b", project: "p", useIAP: true, account: nil, user: nil), startsWhenConnecting: true)
        var manualEdit = ComputerDraft(computer: manual); manualEdit.instance = "another"
        let manualResult = try manualEdit.computer()
        precondition(!manualResult.startsWhenConnecting, "Auto-start never follows an edit to another machine, verified or not")
        flow6.startsWhenConnecting = true; flow6.back(); flow6.choose(flow6.instances[0])
        precondition(!flow6.startsWhenConnecting, "Wizard auto-start approval is per machine")
        verified.name = "vm"; editDraft = ComputerDraft(computer: verified)
        guard case let .googleCloud(_, _, _, _, _, _, alias2, key2) = try editDraft.computer().connection else { preconditionFailure() }
        precondition(alias2 == "circe-gce-9" && key2 == "~/.ssh/k", "Unchanged edits keep the verified pin and key")
    }
}
