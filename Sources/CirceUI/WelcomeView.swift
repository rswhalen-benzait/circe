import SwiftUI

public enum WelcomeDestination: Hashable { case connect, share, skip }

public struct WelcomeView: View {
    private let choose: (WelcomeDestination) -> Void
    @FocusState private var focused: WelcomeDestination?
    @AccessibilityFocusState private var introductionFocused: Bool
    public init(choose: @escaping (WelcomeDestination) -> Void) { self.choose = choose }

    public var body: some View {
        VStack(spacing: 23) {
            CirceMark(size: 58)
            VStack(spacing: 10) {
                Text("Welcome to Circe.")
                    .font(.system(size: 31, weight: .regular, design: .serif)).tracking(-0.8)
                    .accessibilityAddTraits(.isHeader).accessibilityFocused($introductionFocused)
                Text("Your Macs, a little closer.")
                    .font(.system(size: 13)).foregroundStyle(CirceStyle.secondaryInk)
            }
            VStack(spacing: 12) {
                role(.connect, title: "Connect to a computer", detail: "Find a nearby Mac or add a Linux computer.\nYour remote desktop opens right here.", symbol: "laptopcomputer")
                    .keyboardShortcut(.defaultAction)
                role(.share, title: "Share this Mac", detail: "Make this desktop available to your\nother computers. You choose who can connect.", symbol: "desktopcomputer")
            }.focusSection()
            Text("You can do both. Sharing is always your choice.")
                .font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
            Button("Skip for now") { choose(.skip) }
                .buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                .accessibilityHint("Closes this welcome screen. It will not appear again.")
        }.padding(32).frame(width: 490)
            .background(CirceStyle.paper).foregroundStyle(CirceStyle.ink)
            .onAppear { focused = .connect; introductionFocused = true }
    }

    private func role(_ destination: WelcomeDestination, title: String, detail: String, symbol: String) -> some View {
        Button { choose(destination) } label: {
            HStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 29, weight: .ultraLight))
                    .foregroundStyle(CirceStyle.violet).frame(width: 43)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk)
                        .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(CirceStyle.violet)
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(CirceStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CirceStyle.controlBorder))
                .contentShape(RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(FocusOutlineButtonStyle(cornerRadius: 14)).focused($focused, equals: destination)
            .accessibilityElement(children: .ignore).accessibilityLabel(title)
            .accessibilityHint(detail.replacingOccurrences(of: "\n", with: " "))
    }
}
