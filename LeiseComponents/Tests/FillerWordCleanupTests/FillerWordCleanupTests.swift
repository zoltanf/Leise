import Foundation
import LeiseCore
import XCTest
@testable import FillerWordCleanup

@MainActor
final class FillerWordCleanupTests: XCTestCase {
    private final class TestStore: FillerWordCleanupStore, @unchecked Sendable {
        private struct Box: @unchecked Sendable { let value: Any }
        private let lock = NSLock()
        private var defaults: [String: Box]

        init(defaults: [String: Any] = [:]) throws {
            self.defaults = defaults.mapValues(Box.init(value:))
        }

        func userDefault(forKey key: String) -> Any? {
            lock.withLock { defaults[key]?.value }
        }

        func setUserDefault(_ value: Any?, forKey key: String) {
            lock.withLock { defaults[key] = value.map(Box.init(value:)) }
        }
    }

    private func makeCleanup(store: TestStore? = nil) -> FillerWordCleanup {
        FillerWordCleanup(store: store ?? (try! TestStore()))
    }

    func testMetadataPlacesProcessorBeforePromptProcessing() {
        let cleanup = makeCleanup()

        XCTAssertEqual(cleanup.id, "com.leise.filler-words")
        XCTAssertEqual(cleanup.displayName, "Filler Words")
        XCTAssertLessThan(cleanup.priority, 300)
    }

    func testRemovesBuiltInFillerWordsCaseInsensitively() async throws {
        let cleanup = makeCleanup()

        let result = try await cleanup.process(
            "Ähm, um uh hello?",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "hello?")
    }

    func testRemovesBuiltInJapaneseFillerWordsAtPhraseBoundaries() async throws {
        let cleanup = makeCleanup()

        let result = try await cleanup.process(
            "えっと友達追加されたのは2月9日で、なんか様子を見たいです。まあ今日から開始してください。",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "友達追加されたのは2月9日で、様子を見たいです。今日から開始してください。")
    }

    func testPreservesMeaningfulJapaneseConnectorsAndDemonstratives() {
        XCTAssertEqual(
            FillerWordCleanup.removeFillerWords(from: "あと最後に送信確認してください。"),
            "あと最後に送信確認してください。"
        )
        XCTAssertEqual(
            FillerWordCleanup.removeFillerWords(from: "そのまま送信してください。"),
            "そのまま送信してください。"
        )
        XCTAssertEqual(
            FillerWordCleanup.removeFillerWords(from: "あの人に確認してください。"),
            "あの人に確認してください。"
        )
        XCTAssertEqual(
            FillerWordCleanup.removeFillerWords(from: "まあまあです。今日は、まあまあです。"),
            "まあまあです。今日は、まあまあです。"
        )
        XCTAssertEqual(
            FillerWordCleanup.removeFillerWords(from: "まあまず確認してください。まあまた明日です。"),
            "まず確認してください。また明日です。"
        )
    }

    func testInitializationSeedsComponentScopedDefaultWords() throws {
        let host = try TestStore()
        let component = FillerWordCleanupFactory.make(store: host)

        _ = component.settingsView
        XCTAssertEqual(
            host.userDefault(forKey: "words") as? String,
            FillerWordCleanup.defaultFillerWords.joined(separator: "\n")
        )
    }

    func testInitializationMigratesLegacyDefaultsWithoutDroppingCustomWords() throws {
        let host = try TestStore(defaults: [
            "words": [
                "ah",
                "ahh",
                "hm",
                "hmm",
                "uh",
                "uhh",
                "um",
                "umm",
                "basically",
            ].joined(separator: "\n")
        ])
        _ = makeCleanup(store: host)

        let storedWords = host.userDefault(forKey: "words") as? String
        XCTAssertTrue(storedWords?.contains("basically") == true)
        XCTAssertTrue(storedWords?.contains("ähm") == true)
        XCTAssertTrue(storedWords?.contains("えっと") == true)
        XCTAssertEqual(host.userDefault(forKey: "wordsDefaultsVersion") as? Int, 3)
    }

    func testProcessUsesComponentScopedCustomWords() async throws {
        let host = try TestStore(defaults: ["words": "basically\nlike"])
        let cleanup = makeCleanup(store: host)

        let result = try await cleanup.process(
            "basically hello um",
            context: PostProcessingContext()
        )

        XCTAssertEqual(result, "hello um")
    }

    func testPreservesWordBoundariesAndExistingSpacing() {
        XCTAssertEqual(FillerWordCleanup.removeFillerWords(from: "umbrella"), "umbrella")
        XCTAssertEqual(FillerWordCleanup.removeFillerWords(from: "summer humor"), "summer humor")
        XCTAssertEqual(FillerWordCleanup.removeFillerWords(from: "hello  world"), "hello  world")
        XCTAssertEqual(FillerWordCleanup.removeFillerWords(from: "\n\num hello"), "\n\nhello")
    }

    func testPreservesSentenceBoundariesAroundRemovedFillers() {
        // A sentence boundary after the filler must survive removal.
        XCTAssertEqual(FillerWordCleanup.removeFillerWords(from: "well, um. Yes"), "well. Yes")
        // A filler that forms its own sentence disappears with its punctuation.
        XCTAssertEqual(FillerWordCleanup.removeFillerWords(from: "Well. Um. So it goes"), "Well. So it goes")
        XCTAssertEqual(FillerWordCleanup.removeFillerWords(from: "Um. Hello"), "Hello")
        // The filler's own trailing comma is consumed; the clause comma stays.
        XCTAssertEqual(FillerWordCleanup.removeFillerWords(from: "I think, um, that works"), "I think, that works")
        // A spurious period before a lowercase continuation is an ASR artifact.
        XCTAssertEqual(FillerWordCleanup.removeFillerWords(from: "so um. we can"), "so we can")
    }
}
