import Foundation
import SwiftUI
import LeiseCore

public protocol FillerWordCleanupStore: Sendable {
    func userDefault(forKey: String) -> Any?
    func setUserDefault(_ value: Any?, forKey: String)
}

public struct FillerWordCleanupComponent: @unchecked Sendable {
    public let processor: any TextPostProcessor
    public let settingsView: AnyView
}

public enum FillerWordCleanupFactory {
    @MainActor
    public static func make(store: any FillerWordCleanupStore) -> FillerWordCleanupComponent {
        let implementation = FillerWordCleanup(store: store)
        return FillerWordCleanupComponent(
            processor: implementation,
            settingsView: AnyView(FillerWordsSettingsView(store: implementation.settingsStore))
        )
    }
}

final class FillerWordCleanup: TextPostProcessor, @unchecked Sendable {
    static let componentId = "com.leise.filler-words"

    let displayName = "Filler Words"
    let priority = 250
    var id: String { Self.componentId }

    fileprivate let settingsStore: FillerWordsSettingsStore

    init(store: any FillerWordCleanupStore) {
        settingsStore = FillerWordsSettingsStore(store: store)
    }

    func process(_ text: String, context _: PostProcessingContext) async throws -> String {
        Self.removeFillerWords(from: text, words: settingsStore.words)
    }

    static func removeFillerWords(from text: String) -> String {
        removeFillerWords(from: text, words: defaultFillerWords)
    }

    static func removeFillerWords(from text: String, words: [String]) -> String {
        guard !text.isEmpty else { return text }

        let normalizedWords = normalizedWords(from: words)
        guard !normalizedWords.isEmpty else { return text }

        var result = removeLatinFillerWords(from: text, words: normalizedWords)
        result = removeJapaneseFillerWords(from: result, words: normalizedWords)

        return result
    }

    private static func removeLatinFillerWords(from text: String, words: [String]) -> String {
        let latinWords = words.filter { !$0.containsCJKScript }
        guard !latinWords.isEmpty else { return text }

        let escapedWords = latinWords
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        // Case-insensitivity is scoped to the words themselves: the \p{Ll}
        // lookahead below must distinguish upper from lower case.
        let wordGroup = #"(?i:"# + escapedWords + #")(?![\p{L}\p{N}_])"#
        // Two shapes, tried in order:
        // 1. The filler is its own sentence ("Well. Um. So" / "Um. Hello"):
        //    remove it together with its sentence punctuation.
        // 2. Mid-sentence filler: consume an adjacent comma freely, but only
        //    consume sentence-ending punctuation when a lowercase letter
        //    follows (an ASR artifact) — a real sentence boundary before an
        //    uppercase continuation must survive so sentences don't merge.
        let ownSentence = #"(?:^|(?<=[.!?]))[ \t]*"# + wordGroup + #"[ \t]*[.!?]+[ \t]*"#
        let commaBeforeSentenceEnd = #",[ \t]*"# + wordGroup + #"(?=[ \t]*[.!?])"#
        let midSentence = #"(?<![\p{L}\p{N}_]),?[ \t]*"# + wordGroup + #"[ \t]*(?:,[ \t]*|[.!?](?=[ \t]*\p{Ll})[ \t]*)?"#
        let pattern = "(?:" + ownSentence + "|" + commaBeforeSentenceEnd + "|" + midSentence + ")"

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        guard stripped != text else { return text }

        return normalizeWhitespaceAfterRemoval(stripped, preservingPrefixFrom: text)
    }

    private static func removeJapaneseFillerWords(from text: String, words: [String]) -> String {
        let japaneseWords = words.filter(\.containsCJKScript)
        guard !japaneseWords.isEmpty else { return text }

        let escapedWords = japaneseWords
            .map { word in
                let escaped = NSRegularExpression.escapedPattern(for: word)
                if word == "まあ" || word == "まぁ" {
                    return escaped + #"(?!ま[あぁ])"#
                }
                return escaped
            }
            .joined(separator: "|")
        let boundary = #"(^|[\s、。,.!?！？])"#
        let trailingSeparator = #"(?:[ \t]*[、,][ \t]*|[ \t]+)?"#
        let pattern = boundary + #"[ \t]*(?:"# + escapedWords + #")"# + trailingSeparator

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "$1")
        guard stripped != text else { return text }

        return normalizeWhitespaceAfterRemoval(stripped, preservingPrefixFrom: text)
    }

    static let defaultFillerWords: [String] = [
        "ah",
        "ahh",
        "eh",
        "ehm",
        "hm",
        "hmm",
        "uh",
        "uhh",
        "um",
        "umm",
        "äh",
        "ähm",
        "えっと",
        "えーっと",
        "ええと",
        "えーと",
        "えと",
        "なんか",
        "まぁ",
        "まあ",
        "あのー",
        "あのぉ",
        "そのー",
        "そのぉ",
        "うーん",
        "うーむ"
    ]

    static func normalizedWords(from text: String) -> [String] {
        normalizedWords(from: text.split { separator in
            separator.isNewline || separator == "," || separator == ";"
        }.map(String.init))
    }

    private static func normalizedWords(from words: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []

        for word in words {
            // POSIX locale: user terms must not be subject to locale-specific
            // case mapping (e.g. the Turkish dotless-I rule).
            let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(with: Locale(identifier: "en_US_POSIX"))
            guard !cleaned.isEmpty, seen.insert(cleaned).inserted else { continue }
            normalized.append(cleaned)
        }

        return normalized.sorted { $0.count > $1.count || ($0.count == $1.count && $0 < $1) }
    }

    private static func normalizeWhitespaceAfterRemoval(_ text: String, preservingPrefixFrom original: String) -> String {
        var result = text.replacingOccurrences(
            of: #"(?<=[^\s]) {2,}(?=[^\s])"#,
            with: " ",
            options: .regularExpression
        )

        // A removed filler can leave a space stranded before punctuation
        // ("well . Yes"); reattach the punctuation to the preceding word.
        result = result.replacingOccurrences(
            of: #"(?<=\S) +(?=[,.!?;:])"#,
            with: "",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: #"(?m)^ +"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #" +$"#,
            with: "",
            options: .regularExpression
        )

        // Preserve the original's leading whitespace run (including newlines,
        // e.g. a transcript line that begins with a filler) around the
        // trimmed content.
        let originalPrefix = original.prefix(while: \.isWhitespace)
        let core = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !originalPrefix.isEmpty else { return core }
        guard !core.isEmpty else { return "" }
        return String(originalPrefix) + core
    }
}

@MainActor
private final class FillerWordsSettingsStore: ObservableObject, @unchecked Sendable {
    private static let wordsKey = "words"
    private static let defaultsVersionKey = "wordsDefaultsVersion"
    private static let currentDefaultsVersion = 3
    private static let legacyDefaultFillerWords = [
        "ah",
        "ahh",
        "hm",
        "hmm",
        "uh",
        "uhh",
        "um",
        "umm"
    ]

    private let store: any FillerWordCleanupStore

    @Published var wordsText: String {
        didSet {
            store.setUserDefault(wordsText, forKey: Self.wordsKey)
        }
    }

    init(store: any FillerWordCleanupStore) {
        self.store = store

        if let storedWords = store.userDefault(forKey: Self.wordsKey) as? String {
            wordsText = Self.migratedWordsTextIfNeeded(storedWords, store: store)
        } else {
            wordsText = Self.defaultWordsText
            store.setUserDefault(wordsText, forKey: Self.wordsKey)
            store.setUserDefault(Self.currentDefaultsVersion, forKey: Self.defaultsVersionKey)
        }
    }

    var words: [String] {
        FillerWordCleanup.normalizedWords(from: wordsText)
    }

    var wordCount: Int {
        words.count
    }

    func resetToDefaults() {
        wordsText = Self.defaultWordsText
    }

    private static var defaultWordsText: String {
        FillerWordCleanup.defaultFillerWords.joined(separator: "\n")
    }

    private static var legacyDefaultWordsText: String {
        legacyDefaultFillerWords.joined(separator: "\n")
    }

    private static func migratedWordsTextIfNeeded(_ storedWords: String, store: any FillerWordCleanupStore) -> String {
        let storedVersion = store.userDefault(forKey: defaultsVersionKey) as? Int ?? 1
        guard storedVersion < currentDefaultsVersion else { return storedWords }

        let storedNormalized = Set(FillerWordCleanup.normalizedWords(from: storedWords))
        let legacyNormalized = Set(FillerWordCleanup.normalizedWords(from: legacyDefaultWordsText))
        guard storedNormalized.isSuperset(of: legacyNormalized) else {
            store.setUserDefault(currentDefaultsVersion, forKey: defaultsVersionKey)
            return storedWords
        }

        let migratedWords: String
        if storedNormalized == legacyNormalized {
            migratedWords = defaultWordsText
        } else {
            let missingDefaults = FillerWordCleanup.defaultFillerWords.filter { word in
                !storedNormalized.contains(word.lowercased())
            }
            migratedWords = storedWords + "\n" + missingDefaults.joined(separator: "\n")
        }

        store.setUserDefault(migratedWords, forKey: wordsKey)
        store.setUserDefault(currentDefaultsVersion, forKey: defaultsVersionKey)
        return migratedWords
    }
}

private extension String {
    /// Kana or CJK ideographs. Terms containing these are matched with the
    /// boundary-based (spaceless-script) strategy, which is appropriate for
    /// Japanese and Chinese alike — Latin word boundaries don't exist there.
    var containsCJKScript: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF:
                return true
            default:
                return false
            }
        }
    }
}

private struct FillerWordsSettingsView: View {
    @ObservedObject var store: FillerWordsSettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Filler words", bundle: .module))
                .font(.headline)

            Text(String(localized: "One word per line. Commas and semicolons are also accepted.", bundle: .module))
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $store.wordsText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 150)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                )

            HStack {
                Text(String(localized: "\(store.wordCount) words", bundle: .module))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(String(localized: "Reset Defaults", bundle: .module)) {
                    store.resetToDefaults()
                }
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 260)
    }
}
