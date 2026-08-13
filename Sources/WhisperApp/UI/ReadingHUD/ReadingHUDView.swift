import Foundation
import SwiftUI

enum ReadingHUDPresentation: Equatable {
    case gesture(progress: Double)
    case reading(
        phase: ReadingPhase,
        progress: Double,
        voiceName: String?,
        rate: Float
    )
    case error(message: String)
}

struct ReadingHUDActions {
    let togglePause: () -> Void
    let previousSentence: () -> Void
    let nextSentence: () -> Void
    let seek: (Double) -> Void
    let stop: () -> Void
    let setRate: (Float) -> Void
}

@MainActor
final class ReadingHUDViewModel: ObservableObject {
    @Published var presentation: ReadingHUDPresentation = .gesture(progress: 0)
}

struct ReadingHUDView: View {
    @ObservedObject var model: ReadingHUDViewModel
    let actions: ReadingHUDActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    var body: some View {
        switch model.presentation {
        case let .reading(phase, progress, voiceName, rate):
            playbackCard(
                phase: phase,
                progress: progress,
                voiceName: voiceName,
                rate: rate
            )
        case .gesture, .error:
            statusCard
        }
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            phaseVisual
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)

                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(detailLineLimit)
            }

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 14)
        .frame(
            width: ReadingHUDLayout.statusCardSize.width,
            height: ReadingHUDLayout.statusCardSize.height
        )
        .readingHUDCard()
        .padding(ReadingHUDLayout.outerPadding)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.24),
            value: model.presentation
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func playbackCard(
        phase: ReadingPhase,
        progress: Double,
        voiceName: String?,
        rate: Float
    ) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                phaseVisual
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(headline)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                    Text(readingDetail(voiceName))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
                speedMenu(rate: rate)
                transportButton(
                    symbol: "stop.fill",
                    label: "Остановить чтение",
                    role: .stop,
                    action: actions.stop
                )
            }

            ReadingHUDPositionSlider(
                progress: progress,
                onCommit: actions.seek
            )

            HStack(spacing: 10) {
                Spacer(minLength: 0)
                transportButton(
                    symbol: "backward.end.fill",
                    label: "Предыдущее предложение",
                    action: actions.previousSentence
                )
                transportButton(
                    symbol: phase == .paused ? "play.fill" : "pause.fill",
                    label: phase == .paused ? "Продолжить" : "Пауза",
                    role: .primary,
                    action: actions.togglePause
                )
                transportButton(
                    symbol: "forward.end.fill",
                    label: "Следующее предложение",
                    action: actions.nextSentence
                )
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(
            width: ReadingHUDLayout.playbackCardSize.width,
            height: ReadingHUDLayout.playbackCardSize.height
        )
        .readingHUDCard()
        .padding(ReadingHUDLayout.outerPadding)
        .animation(
            reduceMotion ? nil : .snappy(duration: 0.2),
            value: phase
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var phaseVisual: some View {
        switch model.presentation {
        case let .gesture(progress):
            ZStack {
                Circle()
                    .stroke(WhisperTheme.accent.opacity(0.14), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: max(0.025, progress))
                    .stroke(
                        WhisperTheme.accent,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Image(systemName: "option")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(WhisperTheme.accent)
            }

        case let .reading(phase, _, _, _):
            ZStack {
                Circle()
                    .fill(phaseTint(phase).opacity(0.12))

                switch phase {
                case .idle:
                    Image(systemName: "speaker")
                case .preparing:
                    ProgressView()
                        .controlSize(.small)
                        .tint(phaseTint(phase))
                case .speaking:
                    Image(systemName: "waveform")
                        .symbolRenderingMode(.hierarchical)
                case .paused:
                    Image(systemName: "pause.fill")
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(phaseTint(phase))

        case .error:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.12))
                Image(systemName: "exclamationmark")
            }
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.red)
        }
    }

    private var headline: String {
        switch model.presentation {
        case .gesture:
            "Правая Option"
        case let .reading(phase, _, _, _):
            switch phase {
            case .idle: "Готово к чтению"
            case .preparing: "Генерация речи"
            case .speaking: "Чтение"
            case .paused: "Чтение на паузе"
            }
        case .error:
            "Не удалось прочитать"
        }
    }

    private var detail: String {
        switch model.presentation {
        case let .gesture(progress):
            return progress > 0
                ? "Удерживайте 1,5 с"
                : "Коротко нажмите, затем удерживайте"
        case let .reading(_, _, voiceName, _):
            return readingDetail(voiceName)
        case let .error(message):
            return message
        }
    }

    private var detailLineLimit: Int {
        if case .error = model.presentation {
            return 2
        }
        return 1
    }

    private var accessibilityLabel: String {
        switch model.presentation {
        case let .gesture(progress):
            return "Жест правой Option, \(Int((progress * 100).rounded())) процентов"
        case let .reading(_, progress, voiceName, rate):
            let voice = voiceName ?? "Qwen3-TTS 1.7B"
            return "\(headline), \(voice), скорость \(multiplierText(rate)), \(Int((progress * 100).rounded())) процентов"
        case let .error(message):
            return "\(headline). \(message)"
        }
    }

    private func phaseTint(_ phase: ReadingPhase) -> Color {
        switch phase {
        case .idle, .speaking:
            WhisperTheme.accent
        case .preparing:
            .orange
        case .paused:
            .secondary
        }
    }

    private func readingDetail(_ voiceName: String?) -> String {
        guard let voiceName,
              !voiceName.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return "Qwen3-TTS 1.7B"
        }
        return voiceName
    }

    private func speedMenu(rate: Float) -> some View {
        Menu {
            ForEach(Self.speedOptions, id: \.self) { option in
                Button {
                    actions.setRate(option)
                } label: {
                    if abs(option - rate) < 0.001 {
                        Label(multiplierText(option), systemImage: "checkmark")
                    } else {
                        Text(multiplierText(option))
                    }
                }
            }
        } label: {
            Text(multiplierText(rate))
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(minWidth: 34)
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(
                    Color.primary.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Скорость чтения")
        .accessibilityLabel("Скорость чтения")
        .accessibilityValue(multiplierText(rate))
    }

    private func transportButton(
        symbol: String,
        label: String,
        role: ReadingHUDButtonRole = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(ReadingHUDButtonStyle(role: role))
        .help(label)
        .accessibilityLabel(label)
    }

    private func multiplierText(_ value: Float) -> String {
        let formatted = String(format: "%.2f", value)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        return "\(formatted)×"
    }

    private static let speedOptions: [Float] = [
        0.5, 0.75, 1, 1.25, 1.5, 1.75, 2,
    ]
}

private struct ReadingHUDPositionSlider: View {
    let progress: Double
    let onCommit: (Double) -> Void

    @State private var draft = 0.0
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: $draft,
                in: 0...1,
                onEditingChanged: { editing in
                    isEditing = editing
                    if !editing {
                        onCommit(draft)
                    }
                }
            )
            .controlSize(.mini)
            .tint(WhisperTheme.accent)

            Text("\(Int((draft * 100).rounded()))%")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
        .onAppear {
            draft = min(max(progress, 0), 1)
        }
        .onChange(of: progress) {
            if !isEditing {
                draft = min(max(progress, 0), 1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Позиция чтения")
    }
}

private enum ReadingHUDButtonRole {
    case secondary
    case primary
    case stop
}

private struct ReadingHUDButtonStyle: ButtonStyle {
    let role: ReadingHUDButtonRole

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(background, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }

    private var foreground: Color {
        switch role {
        case .secondary:
            .primary
        case .primary:
            .white
        case .stop:
            .red
        }
    }

    private var background: Color {
        switch role {
        case .secondary:
            Color.primary.opacity(0.07)
        case .primary:
            WhisperTheme.accent
        case .stop:
            Color.red.opacity(0.1)
        }
    }
}

private extension View {
    func readingHUDCard() -> some View {
        background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 19, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(Color.primary.opacity(0.11), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }
}
