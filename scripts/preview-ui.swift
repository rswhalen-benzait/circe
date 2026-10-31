import AppKit
import SwiftUI

@main
struct PreviewExporter {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "build/previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "com.circe.preview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = CirceModel(preferences: CircePreferences(defaults: defaults))
        func save<V: View>(_ name: String, _ view: V) throws {
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: 80, y: 80))
            window.makeKeyAndOrderFront(nil)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
            window.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                throw NSError(domain: "CircePreview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render \(name)"])
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
            window.orderOut(nil)
            try png.write(to: output.appendingPathComponent("\(name).png"))
        }
        try save("launcher-empty", LauncherView(model: model).frame(width: 640, height: 650))
        model.hosts = [NearbyMac(id: "studio", name: "Studio Mac", model: "Mac Studio", address: "studio.local"), NearbyMac(id: "laptop", name: "Ralph’s MacBook Pro", model: "MacBookPro", address: "macbook.local")]
        try save("launcher", LauncherView(model: model).frame(width: 640, height: 650))
        model.onConnect = { _, address in
            let session = RemoteSession(name: address.contains("studio") ? "Studio Mac" : "Office Mac", address: address)
            session.phase = .streaming
            return session
        }
        for address in ["circe://studio.local:47800", "vnc://office.local:5900"] {
            let recent = model.connect(address: address)
            model.closeSession(recent.id)
        }
        try save("launcher-recents", LauncherView(model: model).frame(width: 640, height: 760))
        try save("hosting", HostingSetupView(model: model))
        model.screenRecordingGranted = true; model.accessibilityGranted = true; model.isHosting = true; model.pairingPIN = "731942"
        try save("hosting-active", HostingSetupView(model: model))
        let session = RemoteSession(name: "Studio Mac", address: "studio.local")
        session.phase = .pairing
        try save("pairing", PairingView(session: session).frame(width: 680, height: 520))
        session.phase = .disconnected("The remote Mac stopped responding. Check that it is awake and connected to the network.")
        try save("disconnected", SessionView(session: session).frame(width: 800, height: 520))
        print("Rendered UI previews in \(output.path)")
    }
}
