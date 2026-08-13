import SwiftUI

enum HUDPresentation: Equatable {
    case armed
    case holding(progress: Double)
    case recording(level: Double)
    case transcribing
    case success
    case failure(message: String)
}

@MainActor
final class HUDViewModel: ObservableObject {
    @Published var presentation: HUDPresentation = .armed
}

struct HUDView: View {
    @ObservedObject var model: HUDViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        visual
            .frame(width: 36, height: 36)
            .frame(width: HUDLayout.cardSize.width, height: HUDLayout.cardSize.height)
            .background(
                .regularMaterial,
                in: Circle()
            )
            .overlay {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.16), radius: 6, y: 2)
            .padding(HUDLayout.outerPadding)
            .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: model.presentation)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var visual: some View {
        switch model.presentation {
        case .armed:
            Image(systemName: "option")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(WhisperTheme.accent)
                .frame(width: 34, height: 34)
                .background(WhisperTheme.accent.opacity(0.12), in: Circle())

        case let .holding(progress):
            ZStack {
                Circle()
                    .stroke(WhisperTheme.accent.opacity(0.16), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.03, min(1, progress)))
                    .stroke(
                        WhisperTheme.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: "option")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WhisperTheme.accent)
            }
            .padding(2)

        case let .recording(level):
            LevelMeter(level: level)

        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .tint(WhisperTheme.accent)
                .frame(width: 34, height: 34)
                .background(WhisperTheme.accent.opacity(0.1), in: Circle())

        case .success:
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(WhisperTheme.accent, in: Circle())

        case .failure:
            Image(systemName: "exclamationmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.orange)
                .frame(width: 34, height: 34)
                .background(Color.orange.opacity(0.12), in: Circle())
        }
    }

    private var accessibilityLabel: String {
        switch model.presentation {
        case .armed: "Whisper готов"
        case let .holding(progress):
            "Подготовка записи, \(Int(max(0, min(1, progress)) * 100)) процентов"
        case .recording: "Идёт запись"
        case .transcribing: "Распознавание речи"
        case .success: "Текст вставлен"
        case let .failure(message): "Ошибка: \(message)"
        }
    }
}

private struct LevelMeter: View {
    let level: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let weights = [0.46, 0.72, 1.0, 0.68, 0.42]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(weights.enumerated()), id: \.offset) { _, weight in
                Capsule()
                    .fill(WhisperTheme.accent)
                    .frame(width: 3.5, height: barHeight(weight: weight))
            }
        }
        .frame(width: 34, height: 34)
        .background(WhisperTheme.accent.opacity(0.11), in: Circle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: level)
        .accessibilityLabel("Уровень микрофона")
        .accessibilityValue(Int(max(0, min(1, level)) * 100).formatted())
    }

    private func barHeight(weight: Double) -> CGFloat {
        let normalized = max(0, min(1, level))
        return 6 + CGFloat(normalized * 20 * weight)
    }
}
