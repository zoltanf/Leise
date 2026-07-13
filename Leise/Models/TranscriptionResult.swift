import Foundation

struct TranscriptionSegment {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let speakerLabel: String?
    let speakerConfidence: Double?

    init(
        text: String,
        start: TimeInterval,
        end: TimeInterval,
        speakerLabel: String? = nil,
        speakerConfidence: Double? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
        self.speakerLabel = speakerLabel
        self.speakerConfidence = speakerConfidence
    }
}

struct TranscriptionResult {
    let text: String
    let detectedLanguage: String?
    let duration: TimeInterval
    let processingTime: TimeInterval
    let engineUsed: String
    let segments: [TranscriptionSegment]

}

enum TranscriptionTask: String, CaseIterable, Identifiable {
    case transcribe

    var id: String { rawValue }
    var displayName: String { String(localized: "Transcribe") }
}
