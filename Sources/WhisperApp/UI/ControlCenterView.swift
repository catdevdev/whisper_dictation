import AppKit
import SwiftUI

struct ControlCenterView: View {
    @ObservedObject var controller: AppController
    let openSettings: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirmingTranscriptDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(14)

            Divider()

            ScrollView {
                mainContent
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 440)

            Divider()
            footer
                .padding(12)
        }
        .frame(width: 366)
        .background(.regularMaterial)
        .tint(WhisperTheme.accent)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: controller.phase)
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: controller.readingPhase)
        .onAppear {
            controller.refreshReadiness()
            controller.refreshLoginItemState()
        }
        .confirmationDialog(
            "Удалить резервную копию текста?",
            isPresented: $isConfirmingTranscriptDiscard,
            titleVisibility: .visible
        ) {
            Button("Удалить", role: .destructive) {
                controller.discardLastTranscript()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("После удаления этот текст нельзя будет восстановить из Whisper.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: controller.menuBarSymbol)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(WhisperTheme.accent, in: RoundedRectangle(cornerRadius: 10))
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text("Whisper")
                    .font(.headline)
                Text(headerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            StatusDot(
                color: controller.isMonitoring ? WhisperTheme.accent : .orange,
                pulse: controller.phase.isRecording || controller.readingPhase == .speaking
            )
            .accessibilityLabel(controller.isMonitoring ? "Горячие клавиши активны" : "Нужна настройка")
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if controller.phase.isBusy || controller.phase == .armed {
            dictationActivity
        } else if controller.readingPhase.isActive {
            readingActivity
        } else if case let .failure(message) = controller.phase {
            IssueCard(
                title: "Диктовка не завершена",
                message: message,
                symbol: "exclamationmark.triangle.fill",
                dismiss: controller.clearError
            )
        } else if let message = controller.readingError {
            IssueCard(
                title: "Чтение не запустилось",
                message: message,
                symbol: "speaker.slash.fill",
                dismiss: controller.clearReadingError
            )
        } else if controller.hasRecoverableTranscript {
            recoveryCard
        } else {
            VStack(spacing: 10) {
                if !controller.isDictationOperational {
                    setupCard
                }
                idleActions
            }
        }
    }

    private var idleActions: some View {
        VStack(spacing: 10) {
            if let notice = controller.notice {
                NoticeBanner(notice: notice, onDismiss: controller.clearNotice)
                    .padding(.bottom, 2)
            }

            FeatureActionRow(
                symbol: "mic.fill",
                title: "Диктовка",
                detail: dictationActionDetail,
                actionTitle: "Начать",
                isEnabled: controller.readiness.canDictate,
                action: controller.performManualDictationAction
            )

            FeatureActionRow(
                symbol: "text.bubble.fill",
                title: "Прочитать выделение",
                detail: readingActionDetail,
                actionTitle: "Прочитать",
                isEnabled: controller.readiness.accessibility == .allowed,
                action: controller.readSelectionFromMenu
            )

            HStack(spacing: 6) {
                Image(systemName: controller.chromeConnected
                      ? "checkmark.circle.fill"
                      : "puzzlepiece.extension")
                Text(controller.chromeConnected
                     ? "Chrome подключён — подсветка активна"
                     : "В других приложениях работает локальное чтение")
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 2)
        }
    }

    private var dictationActivity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: controller.phase.symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(controller.phase.tint)
                    .frame(width: 42, height: 42)
                    .background(controller.phase.tint.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.phase.headline)
                        .font(.headline)
                    Text(controller.phase.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if case let .recording(level) = controller.phase {
                ProgressView(value: max(0.04, level))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Уровень микрофона")
            }

            HStack {
                Text(controller.phase == .transcribing
                     ? "Можно отменить ожидание распознавания."
                     : "Повторное нажатие завершит запись.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Отменить", role: .destructive) {
                    controller.cancelCurrentDictation()
                }
                .controlSize(.small)
            }
        }
        .whisperCard(padding: 16)
    }

    private var readingActivity: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: readingSymbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(readingColor)
                    .frame(width: 42, height: 42)
                    .background(readingColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text(controller.readingStatusHeadline)
                        .font(.headline)
                    Text(readingDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ReadingPositionSlider(
                progress: controller.readingProgress,
                onCommit: controller.seekReading(to:)
            )

            HStack(spacing: 8) {
                transportButton(
                    symbol: "backward.end.fill",
                    label: "Предыдущее предложение",
                    action: controller.previousReadingSentence
                )
                transportButton(
                    symbol: controller.readingPhase == .paused ? "play.fill" : "pause.fill",
                    label: controller.readingPhase == .paused ? "Продолжить" : "Пауза",
                    action: controller.toggleReadingPause
                )
                transportButton(
                    symbol: "forward.end.fill",
                    label: "Следующее предложение",
                    action: controller.nextReadingSentence
                )
                Spacer()
                Button("Стоп", role: .destructive) {
                    controller.stopReading()
                }
                .controlSize(.small)
            }
        }
        .whisperCard(padding: 16)
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Завершите настройку", systemImage: "wrench.and.screwdriver.fill")
                .font(.headline)

            Text(setupDetail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if case let .unavailable(message) = controller.hotkeyStatus {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button("Открыть настройки", action: openSettings)
                .buttonStyle(.borderedProminent)
        }
        .whisperCard(padding: 16)
    }

    private var recoveryCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label("Резервная копия диктовки", systemImage: "doc.text.fill")
                .font(.headline)
            Text("Whisper не может подтвердить вставку клавиатурными событиями, поэтому сохранил текст в памяти.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Повторить вставку") {
                    controller.retryLastInsertion()
                }
                .buttonStyle(.borderedProminent)

                Button("Скопировать") {
                    controller.copyLastTranscript()
                }

                Spacer()

                Button("Удалить", role: .destructive) {
                    isConfirmingTranscriptDiscard = true
                }
                .buttonStyle(.plain)
            }
            .controlSize(.small)
        }
        .whisperCard(padding: 16)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: openSettings) {
                Label("Настройки", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                controller.quit()
            } label: {
                Image(systemName: "power")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.bordered)
            .help("Завершить Whisper")
            .accessibilityLabel("Завершить Whisper")
        }
    }

    private var headerDetail: String {
        if controller.readingPhase.isActive {
            return controller.readingStatusHeadline
        }
        if controller.phase.isBusy || controller.phase == .armed {
            return controller.phase.headline
        }
        if controller.isMonitoring {
            return "Левый Shift и правая Option активны"
        }
        return "Нужно завершить настройку"
    }

    private var setupDetail: String {
        if !controller.readiness.hasAPIKey {
            return "Добавьте ключ OpenAI для диктовки."
        }
        if controller.readiness.microphone != .allowed {
            return "Разрешите Whisper доступ к микрофону."
        }
        if controller.readiness.accessibility != .allowed {
            return "Разрешите Универсальный доступ для горячих клавиш, вставки и чтения."
        }
        return "Whisper не смог запустить глобальные горячие клавиши."
    }

    private var dictationActionDetail: String {
        if !controller.readiness.hasAPIKey {
            return "Добавьте ключ OpenAI в настройках"
        }
        if controller.readiness.microphone != .allowed {
            return "Нужен доступ к микрофону"
        }
        if controller.readiness.accessibility != .allowed {
            return "Нужен Универсальный доступ"
        }
        if controller.isMonitoring {
            return "Левый Shift · нажать, затем удерживать"
        }
        return "Кнопка работает без глобального жеста"
    }

    private var readingActionDetail: String {
        guard controller.readiness.accessibility == .allowed else {
            return "Нужен Универсальный доступ"
        }
        return controller.isMonitoring
            ? "Правая Option · нажать, затем удерживать"
            : "Кнопка работает без глобального жеста"
    }

    private var readingDetail: String {
        if controller.readingPhase == .preparing {
            return "Подготавливаю Qwen · \(runtimeStage)"
        }
        return "\(controller.activeVoiceName ?? controller.selectedVoiceName) · \(controller.speechRateMultiplierText)"
    }

    private var runtimeStage: String {
        guard let status = controller.qwenRuntimeStatus else { return "первый запуск" }
        switch status {
        case .checkingRuntime: return "проверка среды"
        case .runtimeAvailable: return "среда готова"
        case .locatingUV: return "поиск uv"
        case .creatingEnvironment: return "создание среды"
        case .installingDependencies: return "установка компонентов"
        case .startingWorker: return "запуск движка"
        case .ready: return "генерация речи"
        }
    }

    private var readingSymbol: String {
        switch controller.readingPhase {
        case .idle: return "text.bubble"
        case .preparing: return "speaker.wave.1"
        case .speaking: return "speaker.wave.2.fill"
        case .paused: return "pause.circle.fill"
        }
    }

    private var readingColor: Color {
        switch controller.readingPhase {
        case .preparing: return .orange
        case .paused: return .secondary
        case .idle, .speaking: return WhisperTheme.accent
        }
    }

    private func transportButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var controller: AppController

    var body: some View {
        Image(systemName: controller.menuBarSymbol)
            .symbolRenderingMode(.hierarchical)
            .accessibilityLabel("Whisper: \(controller.menuBarHeadline)")
    }
}

private struct FeatureActionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(WhisperTheme.accent)
                .frame(width: 38, height: 38)
                .background(WhisperTheme.accent.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)
            Button(actionTitle, action: action)
                .controlSize(.small)
                .disabled(!isEnabled)
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .opacity(isEnabled ? 1 : 0.7)
    }
}

private struct IssueCard: View {
    let title: String
    let message: String
    let symbol: String
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }

            Button("Закрыть", action: dismiss)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .whisperCard(padding: 16)
    }
}

private struct ReadingPositionSlider: View {
    let progress: Double
    let onCommit: (Double) -> Void

    @State private var draft = 0.0
    @State private var isEditing = false

    var body: some View {
        HStack(spacing: 10) {
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
            Text("\(Int((draft * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .onAppear {
            draft = progress
        }
        .onChange(of: progress) {
            if !isEditing {
                draft = progress
            }
        }
        .accessibilityLabel("Позиция чтения")
    }
}
