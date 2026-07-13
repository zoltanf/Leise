import Accessibility
import AppKit

@MainActor
class AccessibilityAnnouncementService {

    func announce(_ message: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    func announceRecordingStarted() {
        announce(String(localized: "Recording started"))
    }

    func announceTranscriptionComplete(wordCount: Int) {
        announce(String(localized: "Transcription complete, \(wordCount) words"))
    }

    func announceError(_ reason: String) {
        announce(String(localized: "Error: \(reason)"))
    }

}
