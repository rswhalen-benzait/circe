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
        print("UI model checks passed: one-time welcome, sharing persistence, quit semantics, login status, display matching, recent connections, and quiet launch policy.")
    }
}
