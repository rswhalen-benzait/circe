import AppKit
import SwiftUI

// Keep the property-wrapper State spelling unambiguous on SDKs that also export a State macro.
public typealias CirceViewState<Value> = State<Value>

public enum CirceStyle {
    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
    public static let ink = adaptive(0x242038, 0xF5F0FA)
    public static let secondaryInk = adaptive(0x625B70, 0xC3BACE)
    public static let violet = adaptive(0x6541B1, 0xBFA6FF)
    public static let violetWash = adaptive(0xF0EBF9, 0x31263F)
    public static let paper = adaptive(0xFAF8F4, 0x19161F)
    public static let surface = adaptive(0xFFFFFF, 0x28232F)
    public static let line = adaptive(0xD8D1DF, 0x51465E)
    public static let controlBorder = adaptive(0x8D819B, 0x8C7D9D)
    public static let green = adaptive(0x28724F, 0x7AD5A7)
    public static let error = adaptive(0xAF263B, 0xFF9BAA)
    public static let primaryFill = Color(red: 0.40, green: 0.25, blue: 0.69)
    public static let canvas = Color(red: 0.045, green: 0.038, blue: 0.075)
}

struct CirceMark: View {
    var size: CGFloat = 40
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.48, green: 0.34, blue: 0.74), Color(red: 0.18, green: 0.11, blue: 0.34)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Circle().trim(from: 0.13, to: 0.87)
                .stroke(LinearGradient(colors: [Color(red: 1, green: 0.89, blue: 0.64), Color(red: 0.78, green: 0.58, blue: 0.31)], startPoint: .top, endPoint: .bottom), style: StrokeStyle(lineWidth: size * 0.065, lineCap: .round))
                .padding(size * 0.23)
            Image(systemName: "sparkle").font(.system(size: size * 0.25, weight: .medium))
                .foregroundStyle(Color(red: 1, green: 0.89, blue: 0.67)).offset(x: size * 0.15, y: -size * 0.13)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 36)
            .background(CirceStyle.primaryFill.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? CirceStyle.violet : .clear, lineWidth: 2).padding(-3))
            .contentShape(RoundedRectangle(cornerRadius: 10)).opacity(enabled ? 1 : 0.45)
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(CirceStyle.secondaryInk).padding(.horizontal, 11).frame(height: 32)
            .background(configuration.isPressed ? CirceStyle.line : CirceStyle.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(CirceStyle.controlBorder))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(focused ? CirceStyle.violet : .clear, lineWidth: 2).padding(-3))
    }
}

struct FocusOutlineButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 12
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.overlay(RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(focused ? CirceStyle.violet : .clear, lineWidth: 2).padding(-2))
    }
}

struct StatusDot: View {
    var color: Color = CirceStyle.green
    var body: some View { Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true) }
}

struct SectionEyebrow: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(.system(size: 10, weight: .semibold, design: .rounded))
            .tracking(1.6).foregroundStyle(CirceStyle.secondaryInk)
            .accessibilityLabel(title).accessibilityAddTraits(.isHeader)
    }
}

struct InlineNotice: View {
    let title: String
    let message: String
    var symbol = "exclamationmark.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(CirceStyle.violet).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(14).background(CirceStyle.violetWash, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}

@MainActor
public enum CirceWindows {
    /// Keep a single launcher even though WindowGroup handles macOS 14's initial launch.
    @discardableResult public static func showLauncherIfOpen() -> Bool {
        CirceStartup.revealLauncher()
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "circe.launcher" }) else { return false }
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .circeLauncherRevealed, object: window)
        return true
    }
}

public extension Notification.Name {
    static let circeLauncherRevealed = Notification.Name("CirceLauncherRevealed")
}
