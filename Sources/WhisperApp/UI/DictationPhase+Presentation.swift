import SwiftUI

extension DictationPhase {
    var headline: String {
        switch self {
        case .idle: "Готово к диктовке"
        case .armed: "Жду удержание Shift"
        case .holding: "Продолжайте удерживать"
        case .recording: "Слушаю"
        case .transcribing: "Распознаю речь"
        case .success: "Текст вставлен"
        case .failure: "Не удалось завершить"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "Быстро нажмите левый Shift, затем нажмите и удерживайте его"
        case .armed:
            "Нажмите левый Shift и держите 1 секунду"
        case let .holding(progress):
            progress < 0.55 ? "Ещё немного" : "Почти готово"
        case .recording:
            "Нажмите левый Shift ещё раз, чтобы завершить"
        case .transcribing:
            "Аудио отправляется на распознавание"
        case .success:
            "Можно продолжать работу"
        case let .failure(message):
            message
        }
    }

    var symbol: String {
        switch self {
        case .idle: "waveform"
        case .armed: "shift"
        case .holding: "circle.dotted"
        case .recording: "waveform.circle.fill"
        case .transcribing: "text.bubble"
        case .success: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .failure: .orange
        default: WhisperTheme.accent
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.bubble.fill"
        case .failure: "exclamationmark.circle.fill"
        default: "waveform"
        }
    }
}
