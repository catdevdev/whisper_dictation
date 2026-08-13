import Foundation
import NaturalLanguage

/// Resolves the language of the text being spoken.
///
/// Browser and document locales are only hints: a Russian selection on an
/// English-language page must still be synthesized as Russian. Distinctive
/// Unicode scripts are deterministic; NaturalLanguage handles Latin-script
/// languages, and the caller-provided locale is used only for short or
/// ambiguous text.
enum SpeechLanguageResolver {
    static func resolve(
        explicitLanguage: String?,
        text: String
    ) -> QwenTTSLanguage {
        let sample = String(text.prefix(4_000))
        if let scriptLanguage = distinctiveScriptLanguage(in: sample) {
            return scriptLanguage
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let detected = hypotheses
            .compactMap { language, confidence -> (QwenTTSLanguage, Double)? in
                guard let mapped = map(language.rawValue) else { return nil }
                return (mapped, confidence)
            }
            .max { $0.1 < $1.1 }

        let letterCount = sample.unicodeScalars.reduce(into: 0) {
            if CharacterSet.letters.contains($1) {
                $0 += 1
            }
        }
        if let detected,
           (detected.1 >= 0.55 || (letterCount >= 24 && detected.1 >= 0.35)) {
            return detected.0
        }

        if let explicit = map(explicitLanguage) {
            return explicit
        }
        return .automatic
    }

    static func map(_ language: String?) -> QwenTTSLanguage? {
        guard let base = language?
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first?
            .lowercased() else {
            return nil
        }
        return switch base {
        case "zh": .chinese
        case "en": .english
        case "ja": .japanese
        case "ko": .korean
        case "de": .german
        case "fr": .french
        case "ru", "uk", "be", "bg", "mk", "sr": .russian
        case "pt": .portuguese
        case "es": .spanish
        case "it": .italian
        default: nil
        }
    }

    private static func distinctiveScriptLanguage(
        in text: String
    ) -> QwenTTSLanguage? {
        var cyrillicCount = 0
        var kanaCount = 0
        var hangulCount = 0
        var hanCount = 0
        var letterCount = 0

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if CharacterSet.letters.contains(scalar) {
                letterCount += 1
            }
            if (0x0400...0x052F).contains(value)
                || (0x1C80...0x1C8F).contains(value)
                || (0x2DE0...0x2DFF).contains(value)
                || (0xA640...0xA69F).contains(value) {
                cyrillicCount += 1
            }
            if (0x3040...0x30FF).contains(value)
                || (0x31F0...0x31FF).contains(value) {
                kanaCount += 1
            }
            if (0x1100...0x11FF).contains(value)
                || (0x3130...0x318F).contains(value)
                || (0xAC00...0xD7AF).contains(value) {
                hangulCount += 1
            }
            if (0x3400...0x4DBF).contains(value)
                || (0x4E00...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value) {
                hanCount += 1
            }
        }

        if dominates(cyrillicCount, among: letterCount) {
            return .russian
        }
        if dominates(kanaCount, among: letterCount) {
            return .japanese
        }
        if dominates(hangulCount, among: letterCount) {
            return .korean
        }
        if dominates(hanCount, among: letterCount) {
            return .chinese
        }
        return nil
    }

    private static func dominates(_ count: Int, among total: Int) -> Bool {
        count > 0
            && (count == total || (count >= 2 && count * 2 >= total))
    }
}
