import AppKit
import Carbon
import ServiceManagement

public enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, unavailable
    public var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
public protocol LoginItemServicing {
    var status: LoginItemStatus { get }
    func setEnabled(_ enabled: Bool) throws
    func openSettings()
}

@MainActor
public final class SystemLoginItemService: LoginItemServicing {
    public init() {}
    public var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }
    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if !status.isRegistered { try SMAppService.mainApp.register() }
        } else if status.isRegistered { try SMAppService.mainApp.unregister() }
    }
    public func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
public enum CirceStartup {
    public private(set) static var isQuietLaunch = false

    /// Apple documents the login-item marker in the open-application event's property data.
    public static func isLoginLaunch(event: NSAppleEventDescriptor?, arguments: [String]) -> Bool {
        if arguments.contains("--background") { return true }
        guard event?.eventID == AEEventID(kAEOpenApplication) else { return false }
        let reason = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        return reason == keyAELaunchedAsLogInItem || reason == keyAELaunchedAsServiceItem
    }

    public static func configure(sharingEnabled: Bool, event: NSAppleEventDescriptor? = NSAppleEventManager.shared().currentAppleEvent,
                                 arguments: [String] = ProcessInfo.processInfo.arguments) {
        // Keep this latched: currentAppleEvent may already be nil later in launch.
        if sharingEnabled && isLoginLaunch(event: event, arguments: arguments) { isQuietLaunch = true }
    }
    public static func revealLauncher() {
        isQuietLaunch = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
