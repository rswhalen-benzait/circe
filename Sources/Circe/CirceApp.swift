import AppKit
import CirceUI
import SwiftUI

@main
struct CirceApp: App {
    @NSApplicationDelegateAdaptor(CirceAppDelegate.self) private var appDelegate
    @StateObject private var runtime = CirceRuntime()

    init() { NSApplication.shared.setActivationPolicy(.regular) }

    var body: some Scene {
        WindowGroup("Circe", id: "launcher") {
            LauncherView(model: runtime.model)
                .onAppear { appDelegate.onQuit = { runtime.model.shutdown() } }
        }
        .defaultSize(width: 640, height: 650)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { ShowLauncherButton() }
            CommandGroup(after: .windowSize) {
                Button("Enter Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    .keyboardShortcut("f", modifiers: [.control, .command])
            }
            CommandMenu("Session") {
                Button("Disconnect") { NotificationCenter.default.post(name: .circeDisconnectSession, object: nil) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }

        WindowGroup(for: UUID.self) { $sessionID in
            if let id = sessionID, let session = runtime.model.sessions[id] {
                SessionView(session: session).onDisappear { runtime.model.closeSession(id) }
            } else {
                ContentUnavailableView("Session closed", systemImage: "rectangle.slash", description: Text("Open Circe to connect to a Mac."))
                    .frame(minWidth: 600, minHeight: 420)
            }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Circe", systemImage: runtime.model.isHosting ? "sparkles" : "moon") {
            HostMenuView(model: runtime.model)
        }.menuBarExtraStyle(.window)

        Settings { CirceSettingsView(model: runtime.model) }
    }
}

private struct ShowLauncherButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Show Circe") { if !CirceWindows.showLauncherIfOpen() { openWindow(id: "launcher") }; NSApp.activate(ignoringOtherApps: true) }
            .keyboardShortcut("n", modifiers: .command)
    }
}

@MainActor
final class CirceAppDelegate: NSObject, NSApplicationDelegate {
    var onQuit: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { onQuit?() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { _ = CirceWindows.showLauncherIfOpen() }
        return true
    }
}
