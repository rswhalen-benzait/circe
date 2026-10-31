import SwiftUI

struct FileDropAffordance: View {
    let hostName: String
    var body: some View {
        ZStack {
            CirceStyle.violet.opacity(0.10)
            RoundedRectangle(cornerRadius: 15).strokeBorder(CirceStyle.violet.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [8, 5])).padding(16)
            VStack(spacing: 12) {
                Image(systemName: "doc.on.doc").font(.system(size: 29, weight: .light)).foregroundStyle(Color(red: 0.83, green: 0.77, blue: 1))
                VStack(spacing: 6) {
                    Text("Drop to copy").font(.system(size: 26, weight: .regular, design: .serif))
                    Text("to \(hostName)’s Downloads").font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.horizontal, 30).padding(.vertical, 25).frame(maxWidth: 390)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19))
                .overlay(RoundedRectangle(cornerRadius: 19).strokeBorder(.white.opacity(0.12)))
                .shadow(color: .black.opacity(0.2), radius: 24, y: 8).padding(32)
        }.foregroundStyle(.white).environment(\.colorScheme, .dark)
            .accessibilityElement(children: .combine)
            .allowsHitTesting(false)
    }
}
