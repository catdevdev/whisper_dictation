import Foundation

public struct SentenceSegment: Equatable, Sendable {
    public let text: String
    /// Range in the source string, measured in UTF-16 code units (the same
    /// coordinate system used by JavaScript strings and AVSpeechSynthesizer).
    public let utf16Offset: Int
    public let utf16Length: Int

    public init(text: String, utf16Offset: Int, utf16Length: Int) {
        self.text = text
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
    }
}

public enum SentenceChunker {
    /// A deterministic sentence splitter used by playback navigation.
    ///
    /// It keeps closing quotation marks with the preceding sentence, supports
    /// Latin/Cyrillic terminators, and preserves exact UTF-16 source offsets.
    /// Newlines are boundaries when no terminal punctuation is present.
    public static func segments(in source: String) -> [SentenceSegment] {
        guard !source.isEmpty else { return [] }

        var rawRanges: [Range<String.Index>] = []
        var sentenceStart = source.startIndex
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            let isTerminal = ".!?…。！？".contains(character)
            let isNewline = character == "\n" || character == "\r"

            if isTerminal {
                var end = next
                while end < source.endIndex, isClosingPunctuation(source[end]) {
                    end = source.index(after: end)
                }
                rawRanges.append(sentenceStart..<end)
                sentenceStart = end
                index = end
                continue
            }

            if isNewline {
                rawRanges.append(sentenceStart..<index)
                sentenceStart = next
            }

            index = next
        }

        if sentenceStart < source.endIndex {
            rawRanges.append(sentenceStart..<source.endIndex)
        }

        return rawRanges.compactMap { trimmedSegment(range: $0, in: source) }
    }

    private static func isClosingPunctuation(_ character: Character) -> Bool {
        "\"'»”’)]}".contains(character)
    }

    private static func trimmedSegment(
        range: Range<String.Index>,
        in source: String
    ) -> SentenceSegment? {
        var lower = range.lowerBound
        var upper = range.upperBound

        while lower < upper, source[lower].isWhitespace {
            lower = source.index(after: lower)
        }
        while lower < upper {
            let beforeUpper = source.index(before: upper)
            guard source[beforeUpper].isWhitespace else { break }
            upper = beforeUpper
        }

        guard lower < upper else { return nil }
        let trimmedRange = lower..<upper
        let nsRange = NSRange(trimmedRange, in: source)
        return SentenceSegment(
            text: String(source[trimmedRange]),
            utf16Offset: nsRange.location,
            utf16Length: nsRange.length
        )
    }
}

private extension Character {
    var isWhitespace: Bool {
        unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains)
    }
}
