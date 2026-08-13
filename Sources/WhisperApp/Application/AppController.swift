import AppKit
import Combine
import Foundation
import WhisperCore

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var phase: DictationPhase = .idle {
        didSet { hudPanel.update(for: phase) }
    }
    @Published private(set) var readiness = AppReadiness()
    @Published private(set) var hotkeyStatus: HotkeyStatus = .checking
    /// Optional recovery surfaced only when macOS rejects the event tap after
    /// Accessibility has already been granted. This never gates manual actions.
    @Published private(set) var inputMonitoringRecoveryState: AccessState?
    @Published private(set) var loginItemStatus: LoginItemStatus = .disabled
    @Published private(set) var hasRecoverableTranscript = false
    @Published private(set) var readingPhase: ReadingPhase = .idle {
        didSet { updateReadingHUD() }
    }
    @Published private(set) var readingProgress = 0.0 {
        didSet { updateReadingHUD() }
    }
    @Published private(set) var activeVoiceName: String? {
        didSet { updateReadingHUD() }
    }
    @Published private(set) var chromeConnected = false
    @Published private(set) var readingError: String?
    @Published private(set) var qwenRuntimeStatus: QwenRuntimeStatus?
    @Published private(set) var notice: AppNotice?

    let preferences: PreferencesStore

    private struct ActiveSession {
        let id: UUID
        let language: String?
        let insertionTarget: TextInsertionTarget?
    }

    private static let keychainReadFailureMessage =
        "Не удалось прочитать ключ OpenAI из Связки ключей."
    private static let qwenPreviewNoticeMessage = "Qwen готовит пример голоса…"
    private static let inputMonitoringRecoveryNoticeMessage =
        "Разрешите Whisper мониторинг ввода, затем вернитесь в приложение."
    private let audioRecorder: AudioRecorderService
    private let transcriptionClient: OpenAITranscriptionClient
    private let credentialStore: KeychainCredentialStore
    private let textInsertion: TextInsertionService
    private let permissionCenter: PermissionCenter
    private let optionMonitor: GlobalOptionMonitor
    private let loginItemManager: LoginItemManager
    private let hudPanel: HUDPanelController
    private lazy var readingHUDPanel = ReadingHUDPanelController(
        actions: ReadingHUDActions(
            togglePause: { [weak self] in
                self?.toggleReadingPause()
            },
            previousSentence: { [weak self] in
                self?.previousReadingSentence()
            },
            nextSentence: { [weak self] in
                self?.nextReadingSentence()
            },
            seek: { [weak self] progress in
                self?.seekReading(to: progress)
            },
            stop: { [weak self] in
                self?.stopReading()
            },
            setRate: { [weak self] rate in
                self?.setSpeechRate(rate)
            }
        )
    )

    private lazy var playback = SpeechPlaybackController(
        settings: preferences.speechSettings
    )
    private lazy var selectedTextService = SelectedTextService()
    private lazy var pairingCodeResult: Result<String, Error> = Result {
        try PairingCodeStore().pairingCode
    }
    private lazy var chromeBridge = ChromeBridge(
        playback: playback,
        pairingCode: try? pairingCodeResult.get()
    )

    private var optionCommandRouter = OptionCommandRouter()
    private var gestureTickTask: Task<Void, Never>?
    private var recordingLimitTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var feedbackTask: Task<Void, Never>?
    private var noticeDismissTask: Task<Void, Never>?
    private var activeSession: ActiveSession?
    private var pendingCapture: AudioCapture?
    private var recoverableTranscript: String?
    private var cancellables = Set<AnyCancellable>()
    private var hasStarted = false

    convenience init() {
        self.init(
            audioRecorder: AudioRecorderService(),
            transcriptionClient: OpenAITranscriptionClient(),
            credentialStore: KeychainCredentialStore(),
            textInsertion: TextInsertionService(),
            permissionCenter: PermissionCenter(),
            optionMonitor: GlobalOptionMonitor(),
            loginItemManager: LoginItemManager(),
            hudPanel: HUDPanelController(),
            userDefaults: .standard
        )
    }

    init(
        audioRecorder: AudioRecorderService,
        transcriptionClient: OpenAITranscriptionClient,
        credentialStore: KeychainCredentialStore,
        textInsertion: TextInsertionService,
        permissionCenter: PermissionCenter,
        optionMonitor: GlobalOptionMonitor,
        loginItemManager: LoginItemManager,
        hudPanel: HUDPanelController,
        userDefaults: UserDefaults
    ) {
        self.audioRecorder = audioRecorder
        self.transcriptionClient = transcriptionClient
        self.credentialStore = credentialStore
        self.textInsertion = textInsertion
        self.permissionCenter = permissionCenter
        self.optionMonitor = optionMonitor
        self.loginItemManager = loginItemManager
        self.hudPanel = hudPanel
        preferences = PreferencesStore(defaults: userDefaults)

        bindAudioRecorder()
        bindPreferences()
    }

    var isMonitoring: Bool {
        hotkeyStatus.isActive
    }

    var isDictationOperational: Bool {
        readiness.canDictate && hotkeyStatus.isActive
    }

    var launchAtLoginEnabled: Bool {
        loginItemStatus.isEnabled
    }

    var loginItemRequiresApproval: Bool {
        loginItemStatus == .requiresApproval
    }

    var selectedLanguage: TranscriptionLanguage {
        preferences.transcriptionLanguage
    }

    var selectedVoiceIdentifier: String {
        preferences.voiceIdentifier
    }

    var speechRate: Float {
        preferences.speechRate
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        do {
            try audioRecorder.cleanupAllTemporaryCaptures()
        } catch {
            showFailure(
                "Не удалось удалить часть временных аудиофайлов. Проверьте права на временную папку."
            )
        }

        configureReadingServices()
        chromeBridge.start()
        if case let .failure(error) = pairingCodeResult {
            readingError = error.localizedDescription
        }

        refreshReadiness()
        refreshLoginItemState()
        startOptionMonitorIfPossible()
    }

    func shutdown() {
        feedbackTask?.cancel()
        noticeDismissTask?.cancel()
        gestureTickTask?.cancel()
        recordingLimitTask?.cancel()
        pipelineTask?.cancel()
        optionMonitor.stop()
        chromeBridge.stop()
        playback.stop()
        audioRecorder.cancelRecording()

        if let pendingCapture {
            try? audioRecorder.cleanup(pendingCapture)
        }
        pendingCapture = nil
        activeSession = nil
        clearRecoverableTranscript()
        hotkeyStatus = .checking
        chromeConnected = false
        readingPhase = .idle
        readingProgress = 0
        hudPanel.hide()
        readingHUDPanel.hide()
    }

    func refreshReadiness() {
        let hasAPIKey: Bool
        do {
            hasAPIKey = try credentialStore.hasAPIKey()
            let reconciledPhase = phase.clearingFailure(
                matching: Self.keychainReadFailureMessage
            )
            if reconciledPhase != phase {
                phase = reconciledPhase
            }
        } catch {
            hasAPIKey = false
            showFailure(Self.keychainReadFailureMessage)
        }

        readiness = AppReadiness(
            microphone: accessState(permissionCenter.status(for: .microphone)),
            accessibility: accessState(permissionCenter.status(for: .accessibility)),
            hasAPIKey: hasAPIKey
        )

        if inputMonitoringRecoveryState != nil {
            inputMonitoringRecoveryState = accessState(
                permissionCenter.status(for: .inputMonitoring)
            )
        }

        if hasActiveRecordingSession, !readiness.canDictate {
            failCurrentSession(missingSetupMessage)
        }

        startOptionMonitorIfPossible()
    }

    func requestMicrophoneAccess() {
        Task { [weak self] in
            guard let self else { return }
            let state = await permissionCenter.request(.microphone)
            refreshReadiness()
            if state != .granted {
                permissionCenter.openSettings(for: .microphone)
                showNotice(
                    .information,
                    "Разрешите микрофон в Системных настройках, затем вернитесь в Whisper."
                )
            } else {
                showNotice(.success, "Доступ к микрофону разрешён.")
            }
        }
    }

    func requestAccessibilityAccess() {
        Task { [weak self] in
            guard let self else { return }
            let state = await permissionCenter.request(.accessibility)
            refreshReadiness()
            if state != .granted {
                permissionCenter.openSettings(for: .accessibility)
                showNotice(
                    .information,
                    "Включите Whisper в разделе «Универсальный доступ», затем вернитесь в приложение."
                )
            } else {
                showNotice(.success, "Универсальный доступ разрешён.")
            }
        }
    }

    /// Rare fallback for Macs whose TCC database requires ListenEvent in
    /// addition to Accessibility. It is intentionally requested only after the
    /// event tap has failed, so healthy installations never see another gate.
    func requestInputMonitoringRecovery() {
        Task { [weak self] in
            guard let self else { return }
            let state = await permissionCenter.request(.inputMonitoring)
            inputMonitoringRecoveryState = accessState(state)
            if state == .granted {
                showNotice(.success, "Мониторинг ввода разрешён. Перезапускаю горячие клавиши…")
                startOptionMonitorIfPossible()
            } else {
                permissionCenter.openSettings(for: .inputMonitoring)
                showNotice(
                    .information,
                    Self.inputMonitoringRecoveryNoticeMessage
                )
            }
        }
    }

    @discardableResult
    func saveAPIKey(_ rawValue: String) -> Bool {
        do {
            try credentialStore.saveAPIKey(rawValue)
            refreshReadiness()
            showNotice(.success, "Ключ OpenAI сохранён в Связке ключей.")
            return true
        } catch {
            showNotice(
                .failure,
                "Не удалось сохранить ключ. Проверьте значение и попробуйте снова."
            )
            return false
        }
    }

    func deleteAPIKey() {
        if activeSession != nil || pipelineTask != nil {
            cancelCurrentSession()
            phase = .idle
        }
        do {
            try credentialStore.deleteAPIKey()
            refreshReadiness()
            showNotice(.success, "Ключ OpenAI удалён.")
        } catch {
            showNotice(.failure, "Не удалось удалить ключ из Связки ключей.")
        }
    }

    func refreshLoginItemState() {
        loginItemManager.refresh()
        if loginItemManager.requiresApproval {
            loginItemStatus = .requiresApproval
        } else {
            loginItemStatus = loginItemManager.isEnabled ? .enabled : .disabled
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItemManager.setEnabled(enabled)
            refreshLoginItemState()
            if loginItemStatus == .requiresApproval {
                showNotice(
                    .information,
                    "macOS ждёт подтверждения запуска Whisper в Объектах входа."
                )
            } else {
                showNotice(
                    .success,
                    enabled
                        ? "Автозапуск Whisper включён."
                        : "Автозапуск Whisper выключен."
                )
            }
        } catch {
            refreshLoginItemState()
            showNotice(.failure, "Не удалось изменить запуск при входе.")
        }
    }

    func openLoginItemSettings() {
        loginItemManager.openSystemSettings()
    }

    func clearError() {
        guard case .failure = phase else { return }
        feedbackTask?.cancel()
        phase = .idle
    }

    func cancelCurrentDictation() {
        if activeSession != nil || pipelineTask != nil {
            cancelCurrentSession()
        } else if phase == .armed || phase.isHolding {
            resetGestureMachine()
        } else {
            return
        }
        phase = .idle
        showNotice(.information, "Диктовка отменена.")
    }

    func retryLastInsertion() {
        guard pipelineTask == nil,
              activeSession == nil,
              let transcript = recoverableTranscript else {
            return
        }

        guard let target = textInsertion.captureTarget() else {
            showFailure("Поставьте курсор в поле, куда нужно вставить текст.")
            return
        }
        feedbackTask?.cancel()
        phase = .transcribing
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await textInsertion.insert(
                    transcript,
                    into: target
                )
                pipelineTask = nil
                completeInsertion()
            } catch is CancellationError {
                pipelineTask = nil
                phase = .idle
            } catch {
                pipelineTask = nil
                showFailure(userMessage(for: error))
            }
        }
    }

    func copyLastTranscript() {
        guard pipelineTask == nil,
              activeSession == nil,
              let transcript = recoverableTranscript else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(transcript, forType: .string) else {
            showFailure("Не удалось скопировать текст в буфер обмена.")
            return
        }

        clearRecoverableTranscript()
        phase = .success
        scheduleIdleFeedback()
    }

    func discardLastTranscript() {
        guard pipelineTask == nil, activeSession == nil else { return }
        clearRecoverableTranscript()
    }

    var availableSpeechVoices: [SpeechVoiceOption] {
        QwenTTSCatalog.voices.map {
            SpeechVoiceOption(
                identifier: $0.id,
                name: $0.displayName,
                language: "мультиязычный",
                quality: ""
            )
        }
    }

    var selectedVoiceName: String {
        let identifier = selectedVoiceIdentifier.isEmpty
            ? QwenTTSCatalog.defaultVoiceID
            : selectedVoiceIdentifier
        return availableSpeechVoices.first {
            $0.identifier == identifier
        }?.name ?? QwenTTSCatalog.defaultVoiceID
    }

    var speechRateMultiplierText: String {
        let formatted = String(format: "%.2f", speechRate)
            .replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\.$", with: "", options: .regularExpression)
        return "\(formatted)×"
    }

    var readingStatusHeadline: String {
        switch readingPhase {
        case .idle:
            "Готово к чтению"
        case .preparing:
            "Qwen генерирует речь"
        case .speaking:
            "Читаю выделенный текст"
        case .paused:
            "Чтение на паузе"
        }
    }

    var menuBarSymbol: String {
        if phase.isBusy || phase == .armed {
            return phase.menuBarSymbol
        }
        switch readingPhase {
        case .idle:
            return phase.menuBarSymbol
        case .preparing:
            return "speaker.wave.2"
        case .speaking:
            return "speaker.wave.2.fill"
        case .paused:
            return "pause.circle.fill"
        }
    }

    var menuBarHeadline: String {
        readingPhase.isActive && !phase.isBusy
            ? readingStatusHeadline
            : phase.headline
    }

    func toggleReadingPause() {
        playback.togglePause()
    }

    func stopReading() {
        chromeBridge.stopPlayback(reason: "user")
        readingError = nil
    }

    func previousReadingSentence() {
        playback.previousSentence()
    }

    func nextReadingSentence() {
        playback.nextSentence()
    }

    func seekReading(to progress: Double) {
        let clamped = min(max(progress, 0), 1)
        let offset = Int((Double(playback.textUTF16Length) * clamped).rounded())
        playback.seek(toUTF16Offset: offset)
    }

    func setSpeechRate(_ rate: Float) {
        preferences.speechRate = SpeechSettingsStore.validatedSpeechRate(rate)
    }

    func previewSelectedVoice() {
        guard !phase.isBusy else {
            showNotice(
                .information,
                "Сначала завершите текущую диктовку."
            )
            return
        }
        showNotice(.information, Self.qwenPreviewNoticeMessage)
        startLocalReading(
            "Привет! Это локальный голос Qwen в приложении Whisper.",
            language: "ru"
        )
    }

    func performManualDictationAction() {
        switch phase {
        case .recording:
            finishRecording()
        case .holding, .transcribing:
            cancelCurrentSession()
            phase = .idle
            showNotice(.information, "Диктовка отменена.")
        case .idle, .armed, .success, .failure:
            beginRecording()
        }
    }

    func readSelectionFromMenu() {
        readSelectedText()
    }

    func clearReadingError() {
        readingError = nil
    }

    func copyChromePairingCode() {
        do {
            let code = try pairingCodeResult.get()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(code, forType: .string) else {
                throw PairingCodeStoreError.invalidCode
            }
            readingError = nil
            showNotice(.success, "Код подключения Chrome скопирован.")
        } catch {
            readingError = "Не удалось скопировать код подключения Chrome."
            showNotice(.failure, "Не удалось скопировать код подключения Chrome.")
        }
    }

    func revealChromeExtension() {
        guard let extensionURL = Bundle.main.resourceURL?
            .appendingPathComponent("ChromeExtension", isDirectory: true),
            FileManager.default.fileExists(atPath: extensionURL.path)
        else {
            readingError = "Расширение Chrome не найдено внутри Whisper."
            showNotice(.failure, "Расширение Chrome не найдено внутри Whisper.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([extensionURL])
        showNotice(.success, "Папка расширения открыта в Finder.")
    }

    func clearNotice() {
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        notice = nil
    }

    func quit() {
        shutdown()
        NSApplication.shared.terminate(nil)
    }

    private func configureReadingServices() {
        chromeBridge.onConnectionChanged = { [weak self] connected in
            self?.chromeConnected = connected
        }
        chromeBridge.onPlaybackStateChanged = { [weak self] state in
            guard let self else { return }
            readingPhase = switch state {
            case .idle: .idle
            case .buffering: .preparing
            case .speaking: .speaking
            case .paused: .paused
            }
            if state == .idle {
                readingProgress = 0
            } else if state == .speaking {
                clearQwenPreviewNoticeIfNeeded()
            }
        }
        chromeBridge.onPlaybackBoundary = { [weak self] offset, length, total in
            guard let self, total > 0 else { return }
            readingProgress = min(
                max(Double(offset + length) / Double(total), 0),
                1
            )
        }
        chromeBridge.onPlaybackEnded = { [weak self] _ in
            self?.readingProgress = 0
        }
        chromeBridge.onError = { [weak self] error in
            guard let self else { return }
            let message = Self.readingMessage(for: error)
            readingError = message
            readingHUDPanel.showError(message)
            showNotice(.failure, message)
        }
        playback.onVoiceChanged = { [weak self] voiceName in
            self?.activeVoiceName = voiceName
        }
        playback.onRuntimeStatusChanged = { [weak self] status in
            guard let self else { return }
            qwenRuntimeStatus = status
            if status == .ready {
                clearQwenPreviewNoticeIfNeeded()
            }
        }
    }

    private func bindPreferences() {
        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        preferences.$speechRate
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] rate in
                guard let self else { return }
                playback.applySpeechRate(rate)
                if readingPhase.isActive {
                    updateReadingHUD(rate: rate)
                }
            }
            .store(in: &cancellables)
    }

    private func bindAudioRecorder() {
        audioRecorder.onUnexpectedStop = { [weak self] in
            self?.handleUnexpectedAudioStop()
        }

        audioRecorder.$averagePower
            .combineLatest(audioRecorder.$peakPower)
            .receive(on: RunLoop.main)
            .sink { [weak self] averagePower, peakPower in
                guard let self, hasActiveRecordingSession else { return }
                let loudest = max(averagePower, peakPower)
                let normalized = max(0, min(1, Double((loudest + 55) / 55)))
                phase = .recording(level: normalized)
            }
            .store(in: &cancellables)
    }

    private func startOptionMonitorIfPossible() {
        guard hasStarted else { return }
        guard readiness.accessibility == .allowed else {
            optionMonitor.stop()
            resetGestureMachine()
            if activeSession == nil {
                phase = .idle
            }
            inputMonitoringRecoveryState = nil
            hotkeyStatus = .needsAccessibility
            return
        }
        let previousFailureMessage: String?
        if case let .unavailable(message) = hotkeyStatus {
            previousFailureMessage = message
        } else {
            previousFailureMessage = nil
        }
        guard !optionMonitor.isRunning else {
            inputMonitoringRecoveryState = nil
            hotkeyStatus = .active
            reconcileRecoveredHotkey(previousFailureMessage)
            return
        }

        // `isRunning` also checks whether macOS still has the tap enabled. Drop
        // a disabled tap before creating its replacement.
        optionMonitor.stop()

        do {
            try optionMonitor.start(
                handler: { [weak self] observedEvent in
                    MainActor.assumeIsolated {
                        self?.receiveGestureEvent(
                            observedEvent.event,
                            at: observedEvent.timestamp
                        )
                    }
                },
                onFailure: { [weak self] error in
                    MainActor.assumeIsolated {
                        self?.handleOptionMonitorFailure(error)
                    }
                }
            )
            hotkeyStatus = optionMonitor.isRunning
                ? .active
                : .unavailable(
                    message: "Горячие клавиши не запустились. Перезапустите Whisper."
                )
            if optionMonitor.isRunning {
                inputMonitoringRecoveryState = nil
                reconcileRecoveredHotkey(previousFailureMessage)
            }
        } catch {
            resetGestureMachine()
            let message = error.localizedDescription
            if case GlobalOptionMonitorError.inputMonitoringMayBeRequired = error {
                inputMonitoringRecoveryState = accessState(
                    permissionCenter.status(for: .inputMonitoring)
                )
            } else {
                inputMonitoringRecoveryState = nil
            }
            hotkeyStatus = .unavailable(message: message)
            if hasActiveRecordingSession {
                failCurrentSession(message)
            } else {
                showFailure(message)
            }
            showNotice(.failure, message)
        }
    }

    private func handleOptionMonitorFailure(_ error: GlobalOptionMonitorError) {
        resetGestureMachine()
        inputMonitoringRecoveryState = nil
        let message = error.localizedDescription
        hotkeyStatus = .unavailable(message: message)
        if hasActiveRecordingSession {
            failCurrentSession(message)
        } else {
            showFailure(message)
        }
        showNotice(.failure, message)
    }

    private func reconcileRecoveredHotkey(_ previousFailureMessage: String?) {
        guard let previousFailureMessage else { return }
        phase = phase.clearingFailure(matching: previousFailureMessage)
        if notice?.message == previousFailureMessage
            || notice?.message == Self.inputMonitoringRecoveryNoticeMessage {
            clearNotice()
        }
    }

    private func receiveGestureEvent(
        _ event: GestureEvent,
        at timestamp: TimeInterval
    ) {
        if phase == .transcribing {
            perform(optionCommandRouter.handle(.reset, at: timestamp))
            updateGestureTicks()
            return
        }

        if case .reset = event {
            let interruptedRecording = hasActiveRecordingSession
            perform(optionCommandRouter.handle(event, at: timestamp))
            updateGestureTicks()

            if interruptedRecording {
                failCurrentSession(
                    "Запись остановлена из-за перезапуска горячей клавиши. Попробуйте ещё раз."
                )
            } else if activeSession == nil {
                phase = .idle
            }
            return
        }

        let commands = optionCommandRouter.handle(event, at: timestamp)
        perform(commands)
        updateGestureTicks()
    }

    private func perform(_ commands: [OptionCommand]) {
        for command in commands {
            switch command {
            case let .dictation(action):
                performDictation(action)
            case .readingArmed:
                readingHUDPanel.showGesture(progress: 0)
            case let .readingHolding(progress):
                readingHUDPanel.showGesture(progress: progress)
            case .readingCancelled:
                if readingPhase.isActive {
                    updateReadingHUD()
                } else {
                    readingHUDPanel.hideGesture()
                }
            case .readSelection:
                readingHUDPanel.update(
                    phase: .preparing,
                    progress: 0,
                    voiceName: selectedVoiceName,
                    rate: speechRate
                )
                readSelectedText()
            }
        }
    }

    private func performDictation(_ action: GestureAction) {
        switch action {
        case .armed:
            feedbackTask?.cancel()
            phase = .armed

        case let .holding(progress):
            phase = .holding(progress: progress)

        case .cancelled:
            if activeSession == nil {
                phase = .idle
            }

        case .startRecording:
            beginRecording()

        case .stopRecording:
            finishRecording()
        }
    }

    private func updateGestureTicks() {
        if hasPendingGesture {
            guard gestureTickTask == nil else { return }
            gestureTickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 33_000_000)
                    guard !Task.isCancelled, let self else { return }
                    let commands = optionCommandRouter.handle(
                        .tick,
                        at: ProcessInfo.processInfo.systemUptime
                    )
                    perform(commands)

                    if !hasPendingGesture {
                        gestureTickTask = nil
                        return
                    }
                }
            }
        } else {
            gestureTickTask?.cancel()
            gestureTickTask = nil
        }
    }

    private var hasPendingGesture: Bool {
        func isPending(_ phase: OptionGesturePhase) -> Bool {
            switch phase {
            case .armed, .holding:
                true
            case .idle, .firstPress, .recording:
                false
            }
        }
        return isPending(optionCommandRouter.dictationPhase)
            || isPending(optionCommandRouter.readingGesturePhase)
    }

    private func readSelectedText() {
        guard !phase.isBusy, activeSession == nil, pipelineTask == nil else {
            let message = "Дождитесь завершения текущей диктовки."
            readingError = message
            readingHUDPanel.showError(message)
            showNotice(.information, message)
            return
        }

        // A new selection replaces the previous reading. This also makes a
        // later active reading an unambiguous signal that Chrome won the
        // extension-vs-local fallback race.
        chromeBridge.stopPlayback(reason: "replaced")
        readingError = nil
        let target: SelectedTextTarget
        do {
            target = try selectedTextService.captureTarget()
        } catch {
            let message = Self.readingMessage(for: error)
            readingError = message
            readingHUDPanel.showError(message)
            showNotice(.failure, message)
            return
        }

        let normalizedBundleIdentifier = target.bundleIdentifier.lowercased()
        let isChrome = normalizedBundleIdentifier.hasPrefix("com.google.chrome")
            || normalizedBundleIdentifier.hasPrefix("org.chromium.chromium")

        if isChrome, chromeBridge.requestSelection(fallback: { [weak self] in
            self?.readSelectionLocally(from: target)
        }) {
            return
        }
        readSelectionLocally(from: target)
    }

    private func readSelectionLocally(from target: SelectedTextTarget) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let selection = try await selectedTextService.readSelection(
                    from: target
                )
                guard !readingPhase.isActive else {
                    // Chrome answered after its fallback timer fired.
                    return
                }
                guard !phase.isBusy,
                      activeSession == nil,
                      pipelineTask == nil else {
                    let message = "Дождитесь завершения текущей диктовки."
                    readingError = message
                    readingHUDPanel.showError(message)
                    showNotice(.information, message)
                    return
                }
                startLocalReading(selection, language: nil)
            } catch {
                let message = Self.readingMessage(for: error)
                readingError = message
                readingHUDPanel.showError(message)
                showNotice(.failure, message)
            }
        }
    }

    private func startLocalReading(_ text: String, language: String?) {
        chromeBridge.stopPlayback(reason: "replaced")
        readingError = nil
        readingProgress = 0
        playback.speak(
            .init(
                sessionID: UUID().uuidString.lowercased(),
                requestID: nil,
                text: text,
                language: language,
                rate: nil,
                voiceIdentifier: nil
            )
        )
    }

    private func beginRecording() {
        refreshReadiness()
        guard readiness.canDictate else {
            resetGestureMachine()
            showFailure(missingSetupMessage)
            return
        }
        guard DictationAdmissionPolicy.canBegin(
            hasActiveSession: activeSession != nil,
            hasRecoverableTranscript: hasRecoverableTranscript
        ) else {
            resetGestureMachine()
            showFailure("Предыдущая диктовка ещё обрабатывается.")
            return
        }
        chromeBridge.stopPlayback(reason: "dictation")
        let session = ActiveSession(
            id: UUID(),
            language: selectedLanguage.requestValue,
            insertionTarget: textInsertion.captureTarget()
        )
        activeSession = session

        do {
            try audioRecorder.startRecording()
            phase = .recording(level: 0)
            scheduleRecordingLimit()
        } catch {
            activeSession = nil
            resetGestureMachine()
            showFailure("Не удалось начать запись. Проверьте доступ к микрофону.")
        }
    }

    private func finishRecording() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil

        guard let session = activeSession else {
            resetGestureMachine()
            phase = .idle
            return
        }

        do {
            let capture = try audioRecorder.stopRecording()
            resetGestureMachine()
            pendingCapture = capture
            phase = .transcribing
            startTranscription(capture: capture, session: session)
        } catch {
            activeSession = nil
            resetGestureMachine()
            showFailure("Запись получилась пустой. Попробуйте ещё раз.")
        }
    }

    private func startTranscription(capture: AudioCapture, session: ActiveSession) {
        pipelineTask?.cancel()
        pipelineTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? audioRecorder.cleanup(capture)
                if pendingCapture == capture {
                    pendingCapture = nil
                }
            }

            do {
                guard isCurrent(session.id) else { return }
                guard let apiKey = try credentialStore.loadAPIKey(), !apiKey.isEmpty else {
                    throw TranscriptionError.invalidAPIKey
                }

                let transcript = try await transcribeWithRetry(
                    audioURL: capture.url,
                    apiKey: apiKey,
                    language: session.language
                )
                try Task.checkCancellation()
                guard isCurrent(session.id) else { return }

                retainTranscript(transcript)
                guard let insertionTarget = session.insertionTarget
                        ?? textInsertion.captureTarget() else {
                    throw TextInsertionError.targetUnavailable
                }

                try await textInsertion.insert(
                    transcript,
                    into: insertionTarget
                )
                guard activeSession?.id == session.id else {
                    if recoverableTranscript == transcript {
                        clearRecoverableTranscript()
                    }
                    return
                }

                activeSession = nil
                pipelineTask = nil
                completeInsertion()
            } catch is CancellationError {
                if activeSession?.id == session.id {
                    activeSession = nil
                    pipelineTask = nil
                    phase = .idle
                }
            } catch {
                guard isCurrent(session.id) else { return }
                activeSession = nil
                pipelineTask = nil
                showFailure(userMessage(for: error))
            }
        }
    }

    private func scheduleIdleFeedback() {
        feedbackTask?.cancel()
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, let self else { return }
            guard activeSession == nil, case .success = phase else { return }
            phase = .idle
        }
    }

    private func transcribeWithRetry(
        audioURL: URL,
        apiKey: String,
        language: String?
    ) async throws -> String {
        let retryDelays: [UInt64] = [600_000_000, 1_200_000_000]

        for attempt in 0...retryDelays.count {
            do {
                return try await transcriptionClient.transcribe(
                    audioURL: audioURL,
                    apiKey: apiKey,
                    language: language
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < retryDelays.count, isRetryable(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: retryDelays[attempt])
            }
        }

        throw TranscriptionError.invalidResponse
    }

    private func isRetryable(_ error: Error) -> Bool {
        guard let transcriptionError = error as? TranscriptionError else {
            return false
        }
        switch transcriptionError {
        case .transport, .server:
            return true
        case .invalidAPIKey,
             .unreadableAudio,
             .invalidResponse,
             .unauthorized,
             .rateLimited,
             .requestRejected,
             .malformedResponse:
            return false
        }
    }

    private func scheduleRecordingLimit() {
        recordingLimitTask?.cancel()
        recordingLimitTask = Task { [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(self.audioRecorder.maximumDuration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, self.activeSession != nil else { return }
            self.recordingLimitTask = nil
            self.finishRecording()
        }
    }

    private func resetGestureMachine() {
        gestureTickTask?.cancel()
        gestureTickTask = nil
        perform(
            optionCommandRouter.handle(
                .reset,
                at: ProcessInfo.processInfo.systemUptime
            )
        )
    }

    private func updateReadingHUD(rate: Float? = nil) {
        readingHUDPanel.update(
            phase: readingPhase,
            progress: readingProgress,
            voiceName: activeVoiceName ?? selectedVoiceName,
            rate: rate ?? speechRate
        )
    }

    private func isCurrent(_ sessionID: UUID) -> Bool {
        !Task.isCancelled && activeSession?.id == sessionID
    }

    private var hasActiveRecordingSession: Bool {
        activeSession != nil && pendingCapture == nil && pipelineTask == nil
    }

    private func handleUnexpectedAudioStop() {
        guard hasActiveRecordingSession else { return }
        failCurrentSession("Запись неожиданно остановилась и была удалена. Попробуйте ещё раз.")
    }

    private func cancelCurrentSession() {
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        pipelineTask?.cancel()
        pipelineTask = nil
        audioRecorder.cancelRecording()

        if let pendingCapture {
            try? audioRecorder.cleanup(pendingCapture)
        }
        pendingCapture = nil
        activeSession = nil
        resetGestureMachine()
    }

    private func retainTranscript(_ transcript: String) {
        recoverableTranscript = transcript
        hasRecoverableTranscript = true
    }

    private func completeInsertion() {
        clearRecoverableTranscript()
        phase = .success
        scheduleIdleFeedback()
    }

    private func clearRecoverableTranscript() {
        recoverableTranscript = nil
        hasRecoverableTranscript = false
    }

    private func accessState(_ state: PermissionState) -> AccessState {
        switch state {
        case .notDetermined: .checking
        case .granted: .allowed
        case .denied, .restricted: .denied
        }
    }

    private var missingSetupMessage: String {
        if !readiness.hasAPIKey {
            return "Добавьте ключ OpenAI в настройках Whisper."
        }
        if readiness.microphone != .allowed {
            return "Разрешите Whisper использовать микрофон."
        }
        if readiness.accessibility != .allowed {
            return "Разрешите Универсальный доступ для горячих клавиш и вставки текста."
        }
        if case let .unavailable(message) = hotkeyStatus {
            return message
        }
        return "Whisper ещё запускает горячие клавиши. Попробуйте через секунду."
    }

    private func userMessage(for error: Error) -> String {
        if let error = error as? TranscriptionError {
            switch error {
            case .invalidAPIKey, .unauthorized:
                return "OpenAI отклонил ключ. Проверьте ключ в настройках."
            case let .rateLimited(retryAfter):
                if let retryAfter {
                    return "Слишком много запросов. Попробуйте через \(Int(retryAfter.rounded(.up))) сек."
                }
                return "Слишком много запросов. Попробуйте немного позже."
            case .transport:
                return "Нет связи с OpenAI. Проверьте подключение к интернету."
            case .server:
                return "Сервис OpenAI временно недоступен. Попробуйте позже."
            case .unreadableAudio:
                return "Не удалось прочитать запись. Попробуйте ещё раз."
            case .invalidResponse, .requestRejected, .malformedResponse:
                return "OpenAI не смог распознать эту запись. Попробуйте ещё раз."
            }
        }

        if let insertionError = error as? TextInsertionError {
            switch insertionError {
            case .secureTextField:
                return "Текст распознан, но Whisper не вставляет диктовку в защищённые поля."
            case .accessibilityPermissionRequired:
                return "Текст распознан. Разрешите Универсальный доступ и повторите вставку из меню."
            case .focusedFieldInspectionFailed:
                return "Текст распознан, но поле не удалось безопасно проверить. Сфокусируйте его и повторите вставку."
            case .targetUnavailable, .targetIdentityChanged, .targetNotFrontmost:
                return "Текст распознан, но приложение назначения изменилось. Выберите поле и повторите вставку."
            case .unableToWritePasteboard:
                return "Текст распознан, но macOS не записала его в буфер обмена. Повторите попытку."
            case .unableToCreateKeyboardEventSource, .unableToCreateKeyboardEvent:
                return "Текст сохранён в буфере, но macOS не создала Cmd+V. Вставьте его вручную."
            }
        }

        return "Не удалось завершить диктовку. Попробуйте ещё раз."
    }

    private static func readingMessage(for error: Error) -> String {
        if let selectedTextError = error as? SelectedTextError {
            return selectedTextError.localizedDescription
        }
        if let playbackError = error as? PlaybackError {
            switch playbackError {
            case .emptyText:
                return "Сначала выделите текст, затем нажмите правую Option."
            case .textTooLong:
                return "Выделенный текст слишком длинный для одного чтения."
            case .voiceUnavailable:
                return "Выбранный голос Qwen сейчас недоступен."
            case .invalidAudio:
                return "Qwen вернул повреждённый аудиопоток."
            case let .generationFailed(details):
                return "Не удалось создать речь Qwen: \(details)"
            case .cancelled:
                return "Чтение было остановлено."
            }
        }
        if let runtimeError = error as? QwenRuntimeError {
            switch runtimeError {
            case .unsupportedArchitecture:
                return "Локальный Qwen требует Mac с Apple silicon."
            case .uvNotFound:
                return "Для первого запуска Qwen не найден uv. Установите uv и повторите проверку голоса."
            case .invalidEnvironment:
                return "Среда Qwen повреждена или несовместима. Перезапустите Whisper и повторите попытку."
            case .bundledWorkerMissing:
                return "В приложении отсутствует компонент Qwen. Переустановите Whisper."
            case let .bootstrapFailed(step, _, details):
                let suffix: String
                if let details, !details.isEmpty {
                    suffix = ": \(details)"
                } else {
                    suffix = "."
                }
                return "Не удалось подготовить Qwen на этапе «\(step)»\(suffix)"
            default:
                return runtimeError.localizedDescription
            }
        }
        return "Не удалось начать чтение. Попробуйте ещё раз."
    }

    private func showNotice(
        _ tone: AppNotice.Tone,
        _ message: String
    ) {
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        notice = AppNotice(tone: tone, message: message)

        guard tone == .success else { return }
        noticeDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled, let self else { return }
            notice = nil
            noticeDismissTask = nil
        }
    }

    private func clearQwenPreviewNoticeIfNeeded() {
        guard notice?.message == Self.qwenPreviewNoticeMessage else { return }
        clearNotice()
    }

    private func showFailure(_ message: String) {
        feedbackTask?.cancel()
        guard activeSession == nil, pipelineTask == nil else { return }
        phase = .failure(message: message)
    }

    private func failCurrentSession(_ message: String) {
        feedbackTask?.cancel()
        cancelCurrentSession()
        phase = .failure(message: message)
    }
}
