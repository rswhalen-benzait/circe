import SwiftUI

struct PairingView: View {
    @ObservedObject var session: RemoteSession
    @CirceViewState<String> private var pin = ""
    @CirceViewState<String> private var username = ""
    @CirceViewState<String> private var password = ""
    @CirceViewState<Bool> private var usePassword = false
    @CirceViewState<Bool> private var submitted = false
    private enum Field: Hashable { case pin, username, password }
    @FocusState private var focused: Field?
    @AccessibilityFocusState private var accessibleField: Field?
    var body: some View {
        VStack(spacing: 23) {
            ZStack {
                Circle().fill(CirceStyle.violetWash).frame(width: 76, height: 76)
                Image(systemName: "key.horizontal").accessibilityHidden(true).font(.system(size: 28, weight: .light)).foregroundStyle(CirceStyle.violet)
            }
            VStack(spacing: 9) {
                Text("A little introduction.").font(.system(size: 29, weight: .regular, design: .serif)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                Text(usePassword ? (session.requiresUsername ? "Sign in with a Mac account on\n\(session.name)." : "Enter the VNC password for\n\(session.name).") : "Enter the six-digit code shown in Circe on\n\(session.name).")
                    .font(.system(size: 13)).foregroundStyle(CirceStyle.secondaryInk).multilineTextAlignment(.center).lineSpacing(4)
            }
            if usePassword { accountFields } else { pinFields }
            if let error = session.pinError {
                Text(error).font(.system(size: 12)).foregroundStyle(CirceStyle.error).accessibilityLabel("Connection error: \(error)").multilineTextAlignment(.center).frame(maxWidth: 340)
            }
            Button(action: submit) {
                HStack(spacing: 8) {
                    if submitted { ProgressView().controlSize(.small).tint(.white) }
                    Text(submitted ? "Connecting…" : usePassword ? "Sign in & connect" : "Pair & connect")
                }.frame(width: 270)
            }.buttonStyle(PrimaryButtonStyle()).disabled(!valid || submitted).keyboardShortcut(.defaultAction)
            if session.allowsPIN && session.allowsPassword {
                Button(usePassword ? "Use a pairing code instead" : "Use a Mac account instead") {
                    usePassword.toggle(); password = ""; pin = ""; submitted = false; focusInput()
                }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(CirceStyle.violet)
            } else {
                Text("You’ll only need to do this once.").font(.system(size: 11)).foregroundStyle(CirceStyle.secondaryInk)
            }
            Button("Cancel") { password = ""; session.disconnect() }.buttonStyle(.plain).keyboardShortcut(.cancelAction).font(.system(size: 12)).foregroundStyle(CirceStyle.secondaryInk)
        }.padding(42).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CirceStyle.paper).foregroundStyle(CirceStyle.ink)
            .focusSection()
            .onAppear { usePassword = !session.allowsPIN && session.allowsPassword; focusInput() }
            .onDisappear { password = "" }
            .onChange(of: session.pinError) { _, value in if value != nil { submitted = false; focusInput() } }
    }
    private var pinFields: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<6) { index in
                    Text(index < pin.count ? String(Array(pin)[index]) : "–")
                        .font(.system(size: 29, weight: .medium, design: .rounded))
                        .foregroundStyle(index < pin.count ? CirceStyle.ink : CirceStyle.line)
                        .frame(width: 43, height: 57).background(CirceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused == .pin && index == min(pin.count, 5) ? CirceStyle.violet : CirceStyle.controlBorder))
                }
            }.accessibilityHidden(true)
            TextField("Pairing code", text: $pin).textFieldStyle(.plain)
                .font(.system(size: 1)).foregroundStyle(.clear).tint(.clear)
                .frame(width: 300, height: 57).focused($focused, equals: .pin).accessibilityFocused($accessibleField, equals: .pin)
                .accessibilityLabel("Six-digit pairing code").accessibilityValue(pin.isEmpty ? "Empty" : pin.map(String.init).joined(separator: " "))
                .accessibilityHint("Enter or paste the code shown on \(session.name). Press Return to pair.")
                .onChange(of: pin) { _, value in pin = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6)); submitted = false }
                .onSubmit(submit)
        }
    }
    private var accountFields: some View {
        VStack(spacing: 10) {
            if session.requiresUsername { TextField("Account name", text: $username).focused($focused, equals: .username).accessibilityFocused($accessibleField, equals: .username).accessibilityLabel("Account name on \(session.name)").textContentType(.username) }
            SecureField("Password", text: $password).focused($focused, equals: .password).accessibilityFocused($accessibleField, equals: .password).accessibilityLabel("Password for \(session.name)").textContentType(.password).onSubmit(submit)
        }.textFieldStyle(.roundedBorder).controlSize(.large).frame(width: 300)
    }
    private var valid: Bool { usePassword ? (!session.requiresUsername || !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && !password.isEmpty : pin.count == 6 }
    private func focusInput() { focused = usePassword ? (session.requiresUsername ? .username : .password) : .pin; accessibleField = focused }
    private func submit() {
        guard valid, !submitted else { return }
        submitted = true
        if usePassword {
            let supplied = password; password = ""
            session.submitPassword(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: supplied)
        } else { session.submitPIN(pin) }
    }
}
