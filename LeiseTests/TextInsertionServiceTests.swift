import AppKit
import XCTest
@testable import Leise

@MainActor
final class TextInsertionServiceTests: XCTestCase {
    func testCancelAfterPasteStillWaitsForClipboardRestoreDelay() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboard.setString("previous clipboard", forType: .string)

        let restoreDelay: Duration = .milliseconds(500)
        let service = TextInsertionService()
        service.accessibilityGrantedOverride = true
        service.pasteboardProvider = { pasteboard }
        // A terminal exposes no focused text state, so the paste stays
        // unverified and the restore waits the full terminal fallback delay.
        service.captureActiveAppOverride = { ("Terminal", "com.apple.Terminal", nil) }
        service.focusedTextElementOverride = { nil }
        service.terminalPasteFallbackRestoreDelay = restoreDelay

        let clock = ContinuousClock()
        var pastedAt: ContinuousClock.Instant?
        var insertion: Task<TextInsertionService.InsertionResult, Error>?
        service.pasteSimulatorOverride = {
            pastedAt = clock.now
            // The user's double Esc lands right after the synthesized Cmd+V.
            insertion?.cancel()
        }

        insertion = Task {
            try await service.insertText("dictated text", preserveClipboard: true)
        }

        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNotNil(pastedAt)
        XCTAssertEqual(insertion?.isCancelled, true)
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "dictated text",
            "the clipboard must not be restored while the target app may still be reading the paste"
        )

        let result = try await insertion?.value
        let elapsed = pastedAt.map { clock.now - $0 }
        XCTAssertEqual(result, .pasted(verification: .unverified(.focusedTextStateUnavailable)))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(elapsed), restoreDelay)
        XCTAssertEqual(pasteboard.string(forType: .string), "previous clipboard")
    }
}
