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
        print("UI model checks passed: sharing persistence, quit semantics, login status, and quiet launch policy.")
    }
}
