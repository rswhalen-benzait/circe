import AppKit
import SwiftUI

// Keep the property-wrapper State spelling unambiguous on SDKs that also export a State macro.
public typealias CirceViewState<Value> = State<Value>

public enum CirceStyle {
    public static let ink = Color(red: 0.14, green: 0.12, blue: 0.22)
    public static let secondaryInk = Color(red: 0.43, green: 0.41, blue: 0.49)
    public static let violet = Color(red: 0.43, green: 0.29, blue: 0.77)
    public static let violetWash = Color(red: 0.94, green: 0.92, blue: 0.98)
    public static let paper = Color(red: 0.98, green: 0.97, blue: 0.95)
    public static let line = Color(red: 0.89, green: 0.87, blue: 0.90)
    public static let green = Color(red: 0.20, green: 0.55, blue: 0.40)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white).padding(.horizontal, 16).frame(height: 36)
            .background(CirceStyle.violet.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10)).opacity(enabled ? 1 : 0.45)
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .foregroundStyle(CirceStyle.secondaryInk).padding(.horizontal, 11).frame(height: 32)
            .background(configuration.isPressed ? CirceStyle.line : Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(CirceStyle.line.opacity(0.8)))
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
    }
}

struct InlineNotice: View {
    let title: String
    let message: String
    var symbol = "exclamationmark.circle"
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(CirceStyle.violet)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message).font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(14).background(CirceStyle.violetWash, in: RoundedRectangle(cornerRadius: 12))
    }
}

@MainActor
public enum CirceWindows {
    /// Keep a single launcher even though WindowGroup handles macOS 14's initial launch.
    @discardableResult public static func showLauncherIfOpen() -> Bool {
        CirceStartup.revealLauncher()
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "circe.launcher" }) else { return false }
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        return true
    }
}
