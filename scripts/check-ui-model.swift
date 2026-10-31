import AppKit
import Carbon
import Foundation

@main struct UIModelChecks {
    @MainActor static func main() throws {
        let suite = "com.circe.ui-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = CircePreferences(defaults: defaults)
        let model = CirceModel(preferences: preferences)
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
        print("UI model checks passed: sharing persistence, quit semantics, login status, display matching, recent connections, and quiet launch policy.")
    }
}
