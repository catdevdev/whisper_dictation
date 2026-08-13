import SwiftUI

struct ReadinessRow: View {
    let title: String
    let detail: String
    let symbol: String
    let state: AccessState
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 26, height: 26)
                .background(iconColor.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Image(systemName: stateSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .accessibilityLabel(detail)
            }
        }
        .frame(minHeight: 32)
    }

    private var iconColor: Color {
        switch state {
        case .checking: .secondary
        case .allowed: WhisperTheme.accent
        case .denied: .orange
        }
    }

    private var stateSymbol: String {
        switch state {
        case .checking: "ellipsis"
        case .allowed: "checkmark"
        case .denied: "exclamationmark"
        }
    }
}

struct DividerInset: View {
    var body: some View {
        Divider()
            .padding(.leading, 37)
    }
}
