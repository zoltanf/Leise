import XCTest
@testable import Leise

final class TextDiffServiceTests: XCTestCase {
    func testComputeWordDiffMarksReplacementAsRemovedThenAdded() {
        let service = TextDiffService()

        let segments = service.computeWordDiff(
            original: "the quick brown fox",
            processed: "the quick red fox"
        )

        XCTAssertEqual(segments, [
            .unchanged("the"),
            .unchanged("quick"),
            .removed("brown"),
            .added("red"),
            .unchanged("fox"),
        ])
    }

    func testComputeWordDiffHandlesPureInsertionsAndDeletions() {
        let service = TextDiffService()

        XCTAssertEqual(
            service.computeWordDiff(original: "a b", processed: "x a b"),
            [.added("x"), .unchanged("a"), .unchanged("b")]
        )
        XCTAssertEqual(
            service.computeWordDiff(original: "a b", processed: "b"),
            [.removed("a"), .unchanged("b")]
        )
        XCTAssertEqual(service.computeWordDiff(original: "", processed: ""), [])
        XCTAssertEqual(
            service.computeWordDiff(original: "", processed: "a"),
            [.added("a")]
        )
        XCTAssertEqual(
            service.computeWordDiff(original: "a", processed: ""),
            [.removed("a")]
        )
    }

    func testComputeWordDiffHandlesLongInputsWithoutQuadraticMemory() {
        let service = TextDiffService()
        let original = (0..<5_000).map { "word\($0)" }.joined(separator: " ")
        let processed = (0..<5_000).map { $0 == 2_500 ? "changed" : "word\($0)" }.joined(separator: " ")

        let segments = service.computeWordDiff(original: original, processed: processed)

        XCTAssertEqual(segments.filter { if case .removed = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(segments.filter { if case .added = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(segments.count, 5_001)
    }

    func testExtractCorrectionsFindsLocalizedWordReplacement() {
        let service = TextDiffService()

        let suggestions = service.extractCorrections(
            original: "teh quick brown fox",
            edited: "the quick brown fox"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "teh")
        XCTAssertEqual(suggestions.first?.replacement, "the")
    }

    func testExtractCorrectionsSkipsLargeRewrites() {
        let service = TextDiffService()

        let suggestions = service.extractCorrections(
            original: "one two three",
            edited: "completely different rewrite here"
        )

        XCTAssertTrue(suggestions.isEmpty)
    }

    func testHighConfidenceExtractionFindsSingleLocalTokenReplacement() {
        let service = TextDiffService()

        let suggestions = service.extractHighConfidenceCorrections(
            original: "please use teh word",
            edited: "please use the word"
        )

        XCTAssertEqual(suggestions.count, 1)
        XCTAssertEqual(suggestions.first?.original, "teh")
        XCTAssertEqual(suggestions.first?.replacement, "the")
    }

    func testHighConfidenceExtractionSkipsAmbiguousAndLowSignalEdits() {
        let service = TextDiffService()

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "teh langauge",
            edited: "the language"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "remove this sentence",
            edited: "write new copy"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "remove this sentence",
            edited: ""
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "teh quick fox",
            edited: "the very quick fox"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "Leise",
            edited: "leise"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "hello.",
            edited: "hello!"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "teh teh",
            edited: "the them"
        ).isEmpty)

        XCTAssertTrue(service.extractHighConfidenceCorrections(
            original: "one two three four",
            edited: "1 2 3 4"
        ).isEmpty)
    }
}
