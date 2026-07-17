import AppKit
import os.log
import UniformTypeIdentifiers

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Leise", category: "HistoryExporter")

/// Writes export content and surfaces a failure to the user instead of
/// silently producing no file (e.g. read-only location, full disk).
@MainActor
func writeExportContent(_ content: String, to url: URL) {
    do {
        try content.write(to: url, atomically: true, encoding: .utf8)
    } catch {
        logger.error("Export write failed: \(error.localizedDescription)")
        let alert = NSAlert()
        alert.messageText = String(localized: "Export failed")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

enum HistoryExportFormat: String, CaseIterable {
    case markdown
    case plainText
    case json

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .plainText: "txt"
        case .json: "json"
        }
    }

    var utType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .plainText: .plainText
        case .json: .json
        }
    }

    var displayName: String {
        switch self {
        case .markdown: "Markdown (.md)"
        case .plainText: "Plain Text (.txt)"
        case .json: "JSON (.json)"
        }
    }
}

enum HistoryExporter {

    static func exportMarkdown(_ record: TranscriptionRecord) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines = [
            "# Transcription - \(formatter.string(from: record.timestamp))",
            ""
        ]

        lines.append("- **Duration:** \(formatDuration(record.durationSeconds))")
        lines.append("- **Words:** \(record.wordsCount)")

        if let lang = record.language {
            lines.append("- **Language:** \(lang.uppercased())")
        }

        let engine = record.modelUsed ?? record.engineUsed
        lines.append("- **Engine:** \(engine)")

        if let appName = record.appName {
            var appLine = "- **App:** \(appName)"
            if let domain = record.appDomain {
                appLine += " (\(domain))"
            }
            lines.append(appLine)
        }

        let steps = record.pipelineStepList
        if !steps.isEmpty {
            lines.append("- **Processing:** \(steps.joined(separator: ", "))")
        }

        if record.wasManuallyEdited {
            lines.append("- **Manual edits:** \(record.manualEditCount) (\(record.manualChangedWordCount) words changed)")
        }

        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append(record.finalText)

        if record.wasPostProcessed {
            lines.append("")
            lines.append("### Original")
            lines.append("")
            lines.append(record.rawText)
        }

        return lines.joined(separator: "\n")
    }

    static func exportPlainText(_ record: TranscriptionRecord) -> String {
        record.finalText
    }

    static func exportJSON(_ record: TranscriptionRecord) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var dict: [String: Any] = [
            "timestamp": iso.string(from: record.timestamp),
            "text": record.finalText,
            "rawText": record.rawText,
            "duration": record.durationSeconds,
            "words": record.wordsCount,
            "engine": record.engineUsed
        ]

        if let lang = record.language {
            dict["language"] = lang
        }
        if let model = record.modelUsed {
            dict["model"] = model
        }

        if let appName = record.appName {
            var app: [String: String] = ["name": appName]
            if let bundleId = record.appBundleIdentifier {
                app["bundleId"] = bundleId
            }
            if let url = record.appURL {
                app["url"] = url
            }
            dict["app"] = app
        }

        let steps = record.pipelineStepList
        if !steps.isEmpty {
            dict["pipelineSteps"] = steps
        }

        if let initialFinalText = record.initialFinalText {
            dict["initialProcessedText"] = initialFinalText
        }
        if record.wasManuallyEdited {
            dict["manualEditCount"] = record.manualEditCount
            dict["manualChangedWords"] = record.manualChangedWordCount
            if let editedAt = record.lastManuallyEditedAt {
                dict["lastManuallyEditedAt"] = iso.string(from: editedAt)
            }
        }

        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize history record \(record.id, privacy: .public) for JSON export; exporting empty object")
            return "{}"
        }
        return json
    }

    @MainActor
    static func saveToFile(_ record: TranscriptionRecord, format: HistoryExportFormat) {
        let content: String
        switch format {
        case .markdown: content = exportMarkdown(record)
        case .plainText: content = exportPlainText(record)
        case .json: content = exportJSON(record)
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let suggestedName = "transcription-\(df.string(from: record.timestamp))"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        writeExportContent(content, to: url)
    }

    // MARK: - Multi-Record Export

    @MainActor
    static func saveMultipleToFile(_ records: [TranscriptionRecord], format: HistoryExportFormat) {
        guard !records.isEmpty else { return }

        let sorted = records.sorted { $0.timestamp < $1.timestamp }

        let content: String
        switch format {
        case .markdown:
            content = sorted.map { exportMarkdown($0) }.joined(separator: "\n\n---\n\n")
        case .plainText:
            content = sorted.map { exportPlainText($0) }.joined(separator: "\n\n")
        case .json:
            // Skip records that fail serialization rather than embedding
            // empty objects; exportJSON logs each failure.
            let jsonStrings = sorted.map { exportJSON($0) }.filter { $0 != "{}" }
            content = "[\n" + jsonStrings.joined(separator: ",\n") + "\n]"
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let suggestedName = "transcriptions-\(df.string(from: Date()))"

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.utType]
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        writeExportContent(content, to: url)
    }

    // MARK: - Helpers

    private static func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
