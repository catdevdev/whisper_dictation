import SwiftUI

extension DictationPhase {
    var headline: String {
        switch self {
        case .idle: "Готово к диктовке"
        case .armed: "Жду удержание Option"
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
            "Быстро нажмите Option, затем нажмите и удерживайте её"
        case .armed:
            "Нажмите Option и держите 1,5 секунды"
        case let .holding(progress):
            progress < 0.55 ? "Ещё немного" : "Почти готово"
        case .recording:
            "Нажмите Option ещё раз, чтобы завершить"
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
        case .armed: "option"
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
