import Darwin
import Foundation

@main
private enum SpeechLanguageResolverVerification {
    static func main() {
        var verifier = Verifier()
        verifier.verifyTextOverridesPageLocale()
        verifier.verifyDistinctiveScripts()
        verifier.verifyMixedAndUnsupportedText()
        verifier.verifyLocaleFallbacks()

        if verifier.failureCount == 0 {
            print(
                "Speech language resolver verification passed "
                    + "(\(verifier.checkCount) checks)"
            )
        } else {
            fputs(
                "Speech language resolver verification failed: "
                    + "\(verifier.failureCount) of \(verifier.checkCount) checks failed\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
    }
}

private struct Verifier {
    private(set) var checkCount = 0
    private(set) var failureCount = 0

    mutating func verifyTextOverridesPageLocale() {
        expectEqual(
            SpeechLanguageResolver.resolve(
                explicitLanguage: "en-US",
                text: "Привет! Это русский текст на англоязычной странице."
            ),
            .russian,
            "Cyrillic selection overrides an English page locale"
        )
        expectEqual(
            SpeechLanguageResolver.resolve(
                explicitLanguage: "en",
                text: "Ответ ChatGPT: сегодня мы проверяем естественное произношение."
            ),
            .russian,
            "ChatGPT Russian selection resolves as Russian"
        )
        expectEqual(
            SpeechLanguageResolver.resolve(
                explicitLanguage: "ru",
                text: "This is a sufficiently long English sentence for reliable detection."
            ),
            .english,
            "actual English text overrides a stale Russian locale"
        )
    }

    mutating func verifyDistinctiveScripts() {
        expectEqual(
            SpeechLanguageResolver.resolve(
                explicitLanguage: "en",
                text: "これは日本語です。"
            ),
            .japanese,
            "Kana resolves as Japanese"
        )
        expectEqual(
            SpeechLanguageResolver.resolve(
                explicitLanguage: "en",
                text: "안녕하세요"
            ),
            .korean,
            "Hangul resolves as Korean"
        )
        expectEqual(
            SpeechLanguageResolver.resolve(
                explicitLanguage: "en",
                text: "你好，世界"
            ),
            .chinese,
            "Han text without Kana resolves as Chinese"
        )
    }

    mutating func verifyLocaleFallbacks() {
        expectEqual(
            SpeechLanguageResolver.resolve(explicitLanguage: "pt-BR", text: "OK"),
            .portuguese,
            "short ambiguous text uses the page locale"
        )
        expectEqual(
            SpeechLanguageResolver.resolve(explicitLanguage: "uk-UA", text: "123"),
            .russian,
            "supported Cyrillic fallback covers Ukrainian locale"
        )
        expectEqual(
            SpeechLanguageResolver.resolve(explicitLanguage: nil, text: "123"),
            .automatic,
            "language remains automatic without textual or locale evidence"
        )
    }

    mutating func verifyMixedAndUnsupportedText() {
        expectEqual(
            SpeechLanguageResolver.resolve(
                explicitLanguage: nil,
                text: "This long English sentence contains one Ж character only."
            ),
            .english,
            "one Cyrillic character does not override dominant English text"
        )
        expectEqual(
            SpeechLanguageResolver.resolve(
                explicitLanguage: nil,
                text: "Привет ChatGPT, пожалуйста, прочитай этот ответ естественно."
            ),
            .russian,
            "Russian remains dominant around a Latin product name"
        )
        expectEqual(
            SpeechLanguageResolver.resolve(
                explicitLanguage: nil,
                text: "Dit is een voldoende lange Nederlandse zin voor taalherkenning."
            ),
            .automatic,
            "unsupported Dutch does not become low-confidence German"
        )
    }

    private mutating func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) {
        checkCount += 1
        guard actual != expected else { return }
        failureCount += 1
        fputs("FAIL: \(label): expected \(expected), got \(actual)\n", stderr)
    }
}
