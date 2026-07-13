import Foundation

struct ErrorLogEntry: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let message: String
    let category: String

    init(message: String, category: String = "general") {
        self.id = UUID()
        self.timestamp = Date()
        self.message = message
        self.category = category
    }

    var categoryIcon: String {
        switch category {
        case "transcription": return "waveform"
        case "recording": return "mic"
        default: return "exclamationmark.triangle"
        }
    }

    var categoryDisplayName: String {
        switch category {
        case "transcription": return String(localized: "Transcription")
        case "recording": return String(localized: "Recording")
        default: return String(localized: "General")
        }
    }
}
