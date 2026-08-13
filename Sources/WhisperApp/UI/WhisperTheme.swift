import SwiftUI

enum WhisperTheme {
    // Dark enough for caption-sized text on a light window background while
    // retaining the original teal identity in both appearances.
    static let accent = Color(red: 0.02, green: 0.49, blue: 0.48)
    static let actionFill = Color(red: 0.01, green: 0.38, blue: 0.37)
    static let cardRadius: CGFloat = 14
    static let compactRadius: CGFloat = 11
    static let panelRadius: CGFloat = 22
    static let sectionSpacing: CGFloat = 14

    static let cardFill = Color.primary.opacity(0.055)
    static let subtleBorder = Color.primary.opacity(0.09)
}

struct WhisperCardModifier: ViewModifier {
    var padding: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                WhisperTheme.cardFill,
                in: RoundedRectangle(
                    cornerRadius: WhisperTheme.cardRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: WhisperTheme.cardRadius,
                    style: .continuous
                )
                .stroke(WhisperTheme.subtleBorder, lineWidth: 0.5)
            }
    }
}

extension View {
    func whisperCard(padding: CGFloat = 14) -> some View {
        modifier(WhisperCardModifier(padding: padding))
    }
}

struct TealButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(minHeight: 32)
            .background(
                WhisperTheme.actionFill.opacity(
                    isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.38
                ),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct KeyCap: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.system(size: 17, weight: .semibold, design: .rounded))
            .frame(width: 34, height: 30)
            .background(
                Color.primary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.primary.opacity(0.14), lineWidth: 0.5)
            }
            .accessibilityLabel("Option")
    }
}

struct StatusDot: View {
    let color: Color
    var pulse = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .background {
                if pulse && !reduceMotion {
                    Circle()
                        .fill(color.opacity(0.18))
                        .frame(width: expanded ? 20 : 10, height: expanded ? 20 : 10)
                }
            }
            .onAppear {
                updatePulse()
            }
            .onChange(of: pulse) {
                updatePulse()
            }
            .onChange(of: reduceMotion) {
                updatePulse()
            }
    }

    private func updatePulse() {
        guard pulse, !reduceMotion else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                expanded = false
            }
            return
        }

        expanded = false
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
            expanded = true
        }
    }
}
