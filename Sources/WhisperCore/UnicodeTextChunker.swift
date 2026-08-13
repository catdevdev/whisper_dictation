import Foundation

/// Splits text into event-sized strings without breaking an extended grapheme cluster.
public enum UnicodeTextChunker {
    /// Keeps Core Graphics keyboard events small while avoiding one event per character.
    public static let defaultMaximumUTF16Units = 20

    /// The limit is soft for a single extended grapheme cluster: an oversized cluster is
    /// emitted whole so every returned string remains valid, semantically intact Unicode.
    public static func chunks(
        of text: String,
        maximumUTF16Units: Int = defaultMaximumUTF16Units
    ) -> [String] {
        guard !text.isEmpty else { return [] }

        let limit = max(1, maximumUTF16Units)
        var result: [String] = []
        result.reserveCapacity(max(1, text.utf16.count / limit))

        var current = ""
        var currentUTF16Count = 0

        for character in text {
            let characterUTF16Count = String(character).utf16.count
            if currentUTF16Count > 0,
               characterUTF16Count > limit - currentUTF16Count {
                result.append(current)
                current.removeAll(keepingCapacity: true)
                currentUTF16Count = 0
            }

            current.append(character)
            currentUTF16Count += characterUTF16Count

            if currentUTF16Count >= limit {
                result.append(current)
                current.removeAll(keepingCapacity: true)
                currentUTF16Count = 0
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
