import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject private var preferences: PreferencesStore

    @State private var selection: SettingsPane = .setup
    @State private var apiKey = ""
    @State private var isConfirmingKeyDeletion = false
    @FocusState private var keyFieldFocused: Bool

    init(controller: AppController) {
        self.controller = controller
        _preferences = ObservedObject(wrappedValue: controller.preferences)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 720, minHeight: 580)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(WhisperTheme.accent)
        .onAppear(perform: refresh)
        .confirmationDialog(
            "Удалить ключ OpenAI?",
            isPresented: $isConfirmingKeyDeletion,
            titleVisibility: .visible
        ) {
            Button("Удалить ключ", role: .destructive) {
                apiKey = ""
                controller.deleteAPIKey()
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Ключ будет удалён из Связки ключей macOS.")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(WhisperTheme.accent, in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 1) {
                    Text("Whisper")
                        .font(.headline)
                    Text("Диктовка и чтение")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 12)

            ForEach(SettingsPane.allCases) { pane in
                SidebarButton(
                    pane: pane,
                    isSelected: selection == pane
                ) {
                    selection = pane
                }
            }

            Spacer()

            Label("Текст озвучивается локально", systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
        .padding(16)
        .frame(width: 186)
        .background(Color.primary.opacity(0.025))
    }

    private var detail: some View {
        VStack(spacing: 0) {
            if let notice = controller.notice {
                NoticeBanner(notice: notice, onDismiss: controller.clearNotice)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeader
                    selectedPage
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(selection.title)
                .font(.title2.weight(.semibold))
            Text(selection.subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var selectedPage: some View {
        switch selection {
        case .setup:
            setupPage
        case .dictation:
            dictationPage
        case .reading:
            readingPage
        }
    }

    private var setupPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Состояние", symbol: setupSymbol) {
                VStack(spacing: 10) {
                    StatusSummaryRow(
                        title: controller.isDictationOperational
                            ? "Whisper готов"
                            : "Нужно завершить настройку",
                        detail: setupDetail,
                        color: controller.isDictationOperational ? WhisperTheme.accent : .orange
                    )

                    Divider()

                    ReadinessRow(
                        title: "Микрофон",
                        detail: permissionDetail(controller.readiness.microphone),
                        symbol: "mic.fill",
                        state: controller.readiness.microphone,
                        actionTitle: controller.readiness.microphone == .allowed ? nil : "Разрешить",
                        action: controller.requestMicrophoneAccess
                    )
                    DividerInset()
                    ReadinessRow(
                        title: "Универсальный доступ",
                        detail: accessibilityDetail,
                        symbol: "cursorarrow.motionlines",
                        state: controller.readiness.accessibility,
                        actionTitle: controller.readiness.accessibility == .allowed ? nil : "Разрешить",
                        action: controller.requestAccessibilityAccess
                    )

                    if let recoveryState = controller.inputMonitoringRecoveryState {
                        DividerInset()
                        ReadinessRow(
                            title: "Мониторинг ввода (резерв)",
                            detail: recoveryState == .allowed
                                ? "Доступ есть — повторяю запуск горячих клавиш"
                                : "macOS запросила отдельный доступ для клавиш Shift/Option",
                            symbol: "keyboard.badge.ellipsis",
                            state: recoveryState,
                            actionTitle: recoveryState == .allowed ? "Повторить" : "Разрешить",
                            action: controller.requestInputMonitoringRecovery
                        )
                    }
                }
            }

            SettingsCard(title: "Ключ OpenAI", symbol: "key.fill") {
                VStack(alignment: .leading, spacing: 11) {
                    Text("Нужен только для расшифровки диктовки. Хранится в Связке ключей macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                            .focused($keyFieldFocused)
                            .onSubmit(saveKey)

                        Button("Сохранить", action: saveKey)
                            .buttonStyle(.borderedProminent)
                            .disabled(trimmedAPIKey.isEmpty)
                    }

                    HStack {
                        Label(
                            controller.readiness.hasAPIKey
                                ? "Ключ сохранён"
                                : "Ключ не добавлен",
                            systemImage: controller.readiness.hasAPIKey
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.caption)
                        .foregroundStyle(controller.readiness.hasAPIKey ? WhisperTheme.accent : .secondary)

                        Spacer()

                        if controller.readiness.hasAPIKey {
                            Button("Удалить", role: .destructive) {
                                isConfirmingKeyDeletion = true
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                        }
                    }
                }
            }

            SettingsCard(title: "Запуск", symbol: "power") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle(
                        "Запускать Whisper при входе",
                        isOn: Binding(
                            get: { controller.launchAtLoginEnabled },
                            set: { controller.setLaunchAtLogin($0) }
                        )
                    )
                    .toggleStyle(.switch)

                    if controller.loginItemRequiresApproval {
                        HStack {
                            Text("macOS ждёт подтверждения в Объектах входа.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Открыть настройки") {
                                controller.openLoginItemSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private var dictationPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Распознавание", symbol: "waveform.badge.mic") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Язык речи")
                            .font(.body.weight(.medium))
                        Text("Автоопределение удобно для нескольких языков.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Язык речи", selection: $preferences.transcriptionLanguage) {
                        ForEach(TranscriptionLanguage.allCases) { language in
                            Text(language.title).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            SettingsCard(title: "Левый Shift", symbol: "keyboard") {
                ShortcutGuide(
                    steps: [
                        ("1", "Коротко нажмите левый Shift"),
                        ("2", "Снова нажмите и удерживайте 1,5 секунды"),
                        ("3", "Нажмите ещё раз, чтобы завершить запись"),
                    ]
                )
            }

            SettingsCard(title: "Альтернативное управление", symbol: "hand.tap") {
                Text("Запись можно запустить и остановить кнопкой в меню Whisper. Это удобно, если жест Shift недоступен.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readingPage: some View {
        VStack(spacing: 16) {
            SettingsCard(title: "Qwen", symbol: "speaker.wave.2.fill") {
                VStack(alignment: .leading, spacing: 12) {
                    StatusSummaryRow(
                        title: qwenHeadline,
                        detail: qwenDetail,
                        color: qwenColor
                    )

                    if let error = controller.readingError {
                        InlineMessage(text: error, tone: .failure) {
                            controller.clearReadingError()
                        }
                    }

                    Divider()

                    HStack {
                        Text("Голос")
                            .font(.body.weight(.medium))
                        Spacer()
                        Picker("Голос", selection: $preferences.voiceIdentifier) {
                            ForEach(controller.availableSpeechVoices) { voice in
                                Text(voice.title).tag(voice.identifier)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 250)
                    }

                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Скорость")
                                .font(.body.weight(.medium))
                            Text(controller.speechRateMultiplierText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $preferences.speechRate, in: 0.5...2, step: 0.05)

                        Button(previewButtonTitle) {
                            if controller.readingPhase.isActive {
                                controller.stopReading()
                            } else {
                                controller.previewSelectedVoice()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.phase.isBusy)
                    }
                }
            }

            SettingsCard(title: "Google Chrome", symbol: "puzzlepiece.extension") {
                VStack(alignment: .leading, spacing: 11) {
                    StatusSummaryRow(
                        title: controller.chromeConnected
                            ? "Расширение подключено"
                            : "Расширение не подключено",
                        detail: controller.chromeConnected
                            ? "Подсветка следует за озвучиваемым текстом."
                            : "Покажите папку, загрузите её в chrome://extensions и вставьте код.",
                        color: controller.chromeConnected ? WhisperTheme.accent : .orange
                    )

                    HStack(spacing: 8) {
                        Button("Показать папку") {
                            controller.revealChromeExtension()
                        }
                        Button("Скопировать код") {
                            controller.copyChromePairingCode()
                        }
                        Spacer()
                    }
                    .controlSize(.small)
                }
            }

            SettingsCard(title: "Правая Option", symbol: "keyboard") {
                ShortcutGuide(
                    steps: [
                        ("1", "Выделите текст"),
                        ("2", "Коротко нажмите правую Option"),
                        ("3", "Снова нажмите и удерживайте 1,5 секунды"),
                    ]
                )
            }
        }
    }

    private var setupSymbol: String {
        controller.isDictationOperational ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill"
    }

    private var setupDetail: String {
        if !controller.readiness.hasAPIKey {
            return "Добавьте ключ OpenAI для диктовки."
        }
        if controller.readiness.microphone != .allowed {
            return "Разрешите доступ к микрофону."
        }
        if controller.readiness.accessibility != .allowed {
            return "Разрешите Универсальный доступ."
        }
        switch controller.hotkeyStatus {
        case .active:
            return "Левый Shift и правая Option активны."
        case .checking:
            return "Запускаю горячие клавиши…"
        case .needsAccessibility:
            return "Универсальный доступ ещё не подтверждён."
        case let .unavailable(message):
            return message
        }
    }

    private var accessibilityDetail: String {
        if controller.readiness.accessibility != .allowed {
            return "Нужно для горячих клавиш, вставки и чтения выделения"
        }
        return controller.isMonitoring
            ? "Горячие клавиши работают"
            : "Доступ есть, горячие клавиши ещё запускаются"
    }

    private var qwenHeadline: String {
        if controller.readingPhase == .speaking {
            return "Qwen читает голосом \(controller.activeVoiceName ?? controller.selectedVoiceName)"
        }
        guard let status = controller.qwenRuntimeStatus else {
            return "Готов к первому запуску"
        }
        switch status {
        case .checkingRuntime: return "Проверяю локальную среду"
        case .runtimeAvailable: return "Среда Qwen готова"
        case .locatingUV: return "Ищу менеджер uv"
        case .creatingEnvironment: return "Создаю среду Qwen"
        case .installingDependencies: return "Устанавливаю компоненты Qwen"
        case .startingWorker: return "Запускаю голосовой движок"
        case .ready: return "Qwen готов"
        }
    }

    private var qwenDetail: String {
        if controller.readingPhase == .preparing {
            return "Первая генерация может занять больше времени; текущий этап показан здесь."
        }
        if controller.qwenRuntimeStatus == nil {
            return "Нажмите «Проверить голос», чтобы подготовить локальную модель."
        }
        return "Qwen3-TTS создаёт речь локально; текст не отправляется в облако."
    }

    private var qwenColor: Color {
        if controller.readingError != nil { return .red }
        if controller.qwenRuntimeStatus == .ready || controller.readingPhase == .speaking {
            return WhisperTheme.accent
        }
        return .orange
    }

    private var previewButtonTitle: String {
        controller.readingPhase.isActive ? "Остановить" : "Проверить голос"
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveKey() {
        if controller.saveAPIKey(apiKey) {
            apiKey = ""
            keyFieldFocused = false
        }
    }

    private func refresh() {
        controller.refreshReadiness()
        controller.refreshLoginItemState()
    }

    private func permissionDetail(_ state: AccessState) -> String {
        switch state {
        case .checking: return "Проверяю…"
        case .allowed: return "Разрешено"
        case .denied: return "Требуется доступ"
        }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case setup
    case dictation
    case reading

    var id: String { rawValue }

    var title: String {
        switch self {
        case .setup: return "Основные"
        case .dictation: return "Диктовка"
        case .reading: return "Чтение"
        }
    }

    var subtitle: String {
        switch self {
        case .setup: return "Доступы, ключ OpenAI и запуск приложения"
        case .dictation: return "Распознавание речи и левый Shift"
        case .reading: return "Локальный голос Qwen и Google Chrome"
        }
    }

    var symbol: String {
        switch self {
        case .setup: return "gearshape"
        case .dictation: return "mic.fill"
        case .reading: return "speaker.wave.2.fill"
        }
    }
}

private struct SidebarButton: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(pane.title, systemImage: pane.symbol)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    isSelected ? WhisperTheme.accent.opacity(0.14) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .whisperCard(padding: 16)
    }
}

private struct StatusSummaryRow: View {
    let title: String
    let detail: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StatusDot(color: color)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ShortcutGuide: View {
    let steps: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 10) {
                    Text(step.0)
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(WhisperTheme.actionFill, in: Circle())
                    Text(step.1)
                        .font(.subheadline)
                    Spacer()
                }
            }
        }
    }
}

struct NoticeBanner: View {
    let notice: AppNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(notice.message)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть сообщение")
        }
        .padding(12)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(0.2), lineWidth: 0.5)
        }
    }

    private var symbol: String {
        switch notice.tone {
        case .success: return "checkmark.circle.fill"
        case .information: return "info.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch notice.tone {
        case .success: return WhisperTheme.accent
        case .information: return .blue
        case .failure: return .red
        }
    }
}

private struct InlineMessage: View {
    let text: String
    let tone: AppNotice.Tone
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .failure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(tone == .failure ? .red : .blue)
            Text(text)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Закрыть сообщение")
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}
