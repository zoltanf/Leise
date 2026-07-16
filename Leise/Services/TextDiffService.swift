import Foundation

struct CorrectionSuggestion: Identifiable {
    let id = UUID()
    let original: String
    let replacement: String
}

enum DiffSegment: Equatable {
    case unchanged(String)
    case removed(String)
    case added(String)
}

final class TextDiffService {

    func computeWordDiff(original: String, processed: String) -> [DiffSegment] {
        let origWords = original.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)
        let procWords = processed.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)

        if origWords.isEmpty && procWords.isEmpty { return [] }
        if origWords.isEmpty { return procWords.map { .added($0) } }
        if procWords.isEmpty { return origWords.map { .removed($0) } }

        // CollectionDifference avoids the dense O(m×n) LCS matrix, which for a
        // long dictation (thousands of words per side) allocated hundreds of
        // megabytes and stalled the calling thread.
        let difference = procWords.difference(from: origWords)
        var removedOffsets = Set<Int>()
        var insertedByOffset: [Int: String] = [:]
        for change in difference {
            switch change {
            case .remove(let offset, _, _):
                removedOffsets.insert(offset)
            case .insert(let offset, let element, _):
                insertedByOffset[offset] = element
            }
        }

        var segments: [DiffSegment] = []
        segments.reserveCapacity(max(origWords.count, procWords.count))
        var i = 0
        var j = 0
        while i < origWords.count || j < procWords.count {
            if i < origWords.count, removedOffsets.contains(i) {
                segments.append(.removed(origWords[i]))
                i += 1
            } else if let inserted = insertedByOffset[j] {
                segments.append(.added(inserted))
                j += 1
            } else if i < origWords.count, j < procWords.count {
                segments.append(.unchanged(origWords[i]))
                i += 1
                j += 1
            } else {
                break
            }
        }
        return segments
    }

    func extractCorrections(original: String, edited: String) -> [CorrectionSuggestion] {
        let originalWords = original.split(separator: " ").map(String.init)
        let editedWords = edited.split(separator: " ").map(String.init)

        // Skip if too different (massive rewrite)
        let maxLen = max(originalWords.count, editedWords.count)
        guard maxLen > 0 else { return [] }

        let diff = editedWords.difference(from: originalWords)

        let removals = diff.compactMap { change -> (offset: Int, element: String)? in
            if case .remove(let offset, let element, _) = change {
                return (offset, element)
            }
            return nil
        }
        let insertions = diff.compactMap { change -> (offset: Int, element: String)? in
            if case .insert(let offset, let element, _) = change {
                return (offset, element)
            }
            return nil
        }

        // If more than 50% changed, treat as rewrite
        let changeCount = removals.count + insertions.count
        if changeCount > maxLen { return [] }

        var suggestions: [CorrectionSuggestion] = []
        var usedInsertions = Set<Int>()

        for removal in removals {
            // Find nearest insertion within 3 positions
            var bestMatch: (index: Int, distance: Int)?
            for (i, insertion) in insertions.enumerated() {
                guard !usedInsertions.contains(i) else { continue }
                let distance = abs(removal.offset - insertion.offset)
                if distance <= 3 {
                    if bestMatch == nil || distance < bestMatch!.distance {
                        bestMatch = (i, distance)
                    }
                }
            }

            if let match = bestMatch {
                let insertion = insertions[match.index]
                usedInsertions.insert(match.index)

                // Strip surrounding punctuation from words
                let origStripped = removal.element.trimmingCharacters(in: .punctuationCharacters)
                let replStripped = insertion.element.trimmingCharacters(in: .punctuationCharacters)

                // Skip empty or punctuation-only tokens
                guard !origStripped.isEmpty, !replStripped.isEmpty else { continue }

                // Skip if only punctuation or case changed
                if origStripped.lowercased() == replStripped.lowercased() { continue }

                suggestions.append(CorrectionSuggestion(
                    original: origStripped,
                    replacement: replStripped
                ))
            }
        }

        return suggestions
    }

    func extractHighConfidenceCorrections(
        original: String,
        edited: String,
        maxSuggestions: Int = 3
    ) -> [CorrectionSuggestion] {
        let originalTokens = Self.wordTokens(in: original)
        let editedTokens = Self.wordTokens(in: edited)

        guard maxSuggestions > 0,
              !originalTokens.isEmpty,
              originalTokens.count == editedTokens.count else {
            return []
        }

        var suggestion: CorrectionSuggestion?

        for (originalToken, editedToken) in zip(originalTokens, editedTokens) where originalToken != editedToken {
            guard suggestion == nil else {
                return []
            }

            let originalStripped = Self.strippedWordToken(originalToken)
            let editedStripped = Self.strippedWordToken(editedToken)

            guard !originalStripped.isEmpty, !editedStripped.isEmpty else {
                return []
            }

            guard originalStripped.lowercased() != editedStripped.lowercased() else {
                return []
            }

            guard !Self.isPunctuationOnly(originalToken),
                  !Self.isPunctuationOnly(editedToken) else {
                return []
            }

            suggestion = CorrectionSuggestion(
                original: originalStripped,
                replacement: editedStripped
            )
        }

        guard let suggestion else { return [] }
        return [suggestion]
    }

    private static func wordTokens(in text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func strippedWordToken(_ token: String) -> String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    private static func isPunctuationOnly(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }
}
