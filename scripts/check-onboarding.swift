import AppKit
import Foundation
import SwiftUI

/// Exercise real AppKit sheets and reveal notifications with isolated preferences.
@main struct OnboardingChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        Task { @MainActor in await verifyPresentation(); exit(0) }
        NSApp.run()
    }
    @MainActor private static func verifyPresentation() async {
        let suite = "com.circe.onboarding-check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func spin(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
        @MainActor func wait(_ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(3)
            while !condition() && Date() < deadline { await spin(0.03) }
            return condition()
        }
        @MainActor func launcher(_ preferences: CircePreferences) -> NSWindow {
            let model = CirceModel(preferences: preferences)
            let host = NSHostingView(rootView: LauncherView(model: model).frame(width: 640, height: 650))
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 650), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            return window
        }
        let first = CircePreferences(defaults: defaults)
        var normal: NSWindow? = launcher(first)
        let appeared = await wait { normal!.attachedSheet != nil && first.hasSeenWelcome }
        precondition(appeared, "First visible launcher must present the welcome sheet")
        print("First visible launcher presented the welcome sheet and persisted its claim.")
        normal!.close(); normal!.contentView = nil; normal = nil; await spin(0.2)
        var again: NSWindow? = launcher(CircePreferences(defaults: defaults))
        await spin(0.4)
        precondition(again!.attachedSheet == nil, "Relaunch must not repeat welcome")
        again!.close(); again!.contentView = nil; again = nil; await spin(0.2)
        defaults.removeObject(forKey: "hasSeenWelcome")
        CirceStartup.configure(sharingEnabled: true, event: nil, arguments: ["Circe", "--background"])
        let quietPreferences = CircePreferences(defaults: defaults)
        let quiet = launcher(quietPreferences)
        await spin(0.4)
        precondition(!quiet.isVisible && quiet.attachedSheet == nil && !quietPreferences.hasSeenWelcome, "Quiet launch must stay hidden and preserve onboarding")
        precondition(CirceWindows.showLauncherIfOpen())
        let reopened = await wait { quiet.attachedSheet != nil && quietPreferences.hasSeenWelcome }
        precondition(reopened, "Deliberately reopening a quiet launcher must present the deferred welcome")
        print("Relaunch stayed welcome-free; quiet launch stayed hidden; deliberate reopen presented the deferred welcome.")
        quiet.close(); await spin(0.1)
    }
}
