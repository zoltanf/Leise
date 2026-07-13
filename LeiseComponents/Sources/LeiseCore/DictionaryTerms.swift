import Foundation

public enum DictionaryTerms {
    public static func normalizedHints(from hints: [DictionaryTermHint]) -> [DictionaryTermHint] {
        var seen = Set<String>()
        var result: [DictionaryTermHint] = []
        for hint in hints {
            let text = hint.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !text.isEmpty, seen.insert(key).inserted else { continue }
            let similarity = hint.ctcMinSimilarity.flatMap { value in
                value.isFinite ? min(max(value, 0), 1) : nil
            }
            result.append(DictionaryTermHint(text: text, ctcMinSimilarity: similarity))
        }
        return result
    }

    public static func normalizedTerms(from terms: [String]) -> [String] {
        normalizedHints(from: terms.map { DictionaryTermHint(text: $0) }).map(\.text)
    }

    public static func hints(fromPrompt prompt: String?) -> [DictionaryTermHint] {
        guard let prompt else { return [] }
        return normalizedHints(from: prompt.split(separator: ",").map {
            DictionaryTermHint(text: String($0))
        })
    }

    public static func clippedHints(
        _ hints: [DictionaryTermHint],
        maxTotalCharacters: Int = 600
    ) -> [DictionaryTermHint] {
        guard maxTotalCharacters > 0 else { return [] }
        var used = 0
        return normalizedHints(from: hints).prefix { hint in
            let added = hint.text.count + (used == 0 ? 0 : 2)
            guard used + added <= maxTotalCharacters else { return false }
            used += added
            return true
        }.map { $0 }
    }

    public static func prompt(from terms: [String], maxTotalCharacters: Int = 600) -> String? {
        let result = clippedHints(
            terms.map { DictionaryTermHint(text: $0) },
            maxTotalCharacters: maxTotalCharacters
        ).map(\.text).joined(separator: ", ")
        return result.isEmpty ? nil : result
    }
}
