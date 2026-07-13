import SwiftUI
import UniformTypeIdentifiers
import LeiseCore

struct FileTranscriptionView: View {
    @ObservedObject private var viewModel = ServiceContainer.shared.fileTranscriptionViewModel

    @State private var isDragTargeted = false
    @State private var showFilePicker = false
    @State private var expandedFileId: UUID?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if viewModel.files.isEmpty {
                    dropZone
                } else {
                    fileList
                    controls
                }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
        .onDrop(of: [.fileURL], isTargeted: $isDragTargeted) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: FileTranscriptionViewModel.allowedContentTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                viewModel.addFiles(urls)
            }
        }
        .onAppear {
            if viewModel.showFilePickerFromMenu {
                viewModel.showFilePickerFromMenu = false
                showFilePicker = true
            }
        }
    }

    // MARK: - Drop Zone

    @ViewBuilder
    private var dropZone: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "arrow.down.doc")
                .font(.largeTitle)
                .foregroundStyle(isDragTargeted ? .blue : .secondary)
                .accessibilityHidden(true)

            Text(String(localized: "Drop audio or video files here"))
                .font(.headline)

            Text(String(localized: "or"))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(String(localized: "Choose Files...")) {
                showFilePicker = true
            }
            .buttonStyle(.bordered)

            Text("WAV, MP3, M4A, FLAC, MP4, MOV")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDragTargeted ? Color.blue.opacity(0.1) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(
                            isDragTargeted ? Color.blue : Color.secondary.opacity(0.3),
                            style: StrokeStyle(lineWidth: 2, dash: [8])
                        )
                )
        )
    }

    // MARK: - File List

    @ViewBuilder
    private var fileList: some View {
        LazyVStack(spacing: 8) {
            ForEach(viewModel.files) { item in
                fileRow(item)
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ item: FileTranscriptionViewModel.FileItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                fileStatusIcon(item.state)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.fileName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    if let error = item.errorMessage {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else if let result = item.result {
                        Text(String(localized: "Audio \(String(format: "%.1f", result.duration))s - processed in \(String(format: "%.1f", result.processingTime))s"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let phase = item.phaseDescription {
                        Text(statusSummary(for: item, phase: phase))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if item.state == .done {
                    fileActionButtons(item)
                }

                if viewModel.batchState != .processing {
                    Button {
                        viewModel.removeFile(item)
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Remove \(item.fileName)"))
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture {
                if item.state == .done {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        expandedFileId = expandedFileId == item.id ? nil : item.id
                    }
                }
            }

            if expandedFileId == item.id, let result = item.result {
                Text(result.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            } else if item.state == .loading || item.state == .transcribing {
                activeFileDetails(item)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    @ViewBuilder
    private func fileStatusIcon(_ state: FileTranscriptionViewModel.FileItemState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Pending"))
        case .loading:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Loading"))
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(String(localized: "Transcribing"))
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel(String(localized: "Done"))
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel(String(localized: "Error"))
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityLabel(String(localized: "Cancelled"))
        }
    }

    @ViewBuilder
    private func activeFileDetails(_ item: FileTranscriptionViewModel.FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let progress = item.progressFraction {
                ProgressView(value: progress)
                    .controlSize(.small)
            }

            if let progressText = item.progressText, !progressText.isEmpty {
                Text(progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private func fileActionButtons(_ item: FileTranscriptionViewModel.FileItem) -> some View {
        HStack(spacing: 4) {
            Button {
                viewModel.copyText(for: item)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help(String(localized: "Copy"))
            .accessibilityLabel(String(localized: "Copy"))

            if let result = item.result, !result.segments.isEmpty {
                Menu {
                    Button("SRT") { viewModel.exportSubtitles(for: item, format: .srt) }
                    Button("VTT") { viewModel.exportSubtitles(for: item, format: .vtt) }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
                .help(String(localized: "Export Subtitles"))
            }
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            fileTranscriptionSettings

            LanguageSelectionEditor(
                selection: $viewModel.languageSelection,
                availableLanguages: fileTranscriptionLanguageOptions,
                hintBehavior: LanguageSelectionHintBehavior(engine: viewModel.resolvedEngine)
            )

            HStack {
                Button(String(localized: "Add Files...")) {
                    showFilePicker = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.batchState == .processing)

                Spacer(minLength: 12)

                if viewModel.hasResults {
                    Menu(String(localized: "Export All")) {
                        Button(String(localized: "Copy All Text")) { viewModel.copyAllText() }
                        Divider()
                        Button(String(localized: "Export All as SRT")) { viewModel.exportAllSubtitles(format: .srt) }
                        Button(String(localized: "Export All as VTT")) { viewModel.exportAllSubtitles(format: .vtt) }
                    }
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                }

                if viewModel.batchState == .processing {
                    HStack(spacing: 10) {
                        processingSummary

                        Button(role: .destructive) {
                            viewModel.cancelTranscription()
                        } label: {
                            Label(String(localized: "Stop"), systemImage: "stop.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                } else {
                    Button {
                        viewModel.transcribeAll()
                    } label: {
                        Label(String(localized: "Transcribe All"), systemImage: "waveform")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize(horizontal: true, vertical: false)
                    .disabled(!viewModel.canTranscribe)
                }

                Button {
                    viewModel.reset()
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .disabled(viewModel.batchState == .processing)
                .help(String(localized: "Clear All"))
                .accessibilityLabel(String(localized: "Clear All"))
            }
        }
    }

    @ViewBuilder
    private var processingSummary: some View {
        if viewModel.files.indices.contains(viewModel.currentIndex) {
            let item = viewModel.files[viewModel.currentIndex]
            HStack(spacing: 4) {
                Text(statusSummary(for: item, phase: item.phaseDescription ?? String(localized: "Processing...")))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(localized: "\(viewModel.processedFiles)/\(viewModel.totalFiles)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        } else {
            Text(String(localized: "\(viewModel.processedFiles)/\(viewModel.totalFiles)"))
                .font(.caption)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var fileTranscriptionSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(String(localized: "Engine"), selection: $viewModel.selectedEngine) {
                Text(String(localized: "Default Engine")).tag(nil as String?)
                Divider()
                ForEach(viewModel.availableEngines, id: \.id) { engine in
                    enginePickerLabel(for: engine)
                        .tag(engine.id as String?)
                        .disabled(!viewModel.canUseForTranscription(engine))
                }
            }
            .controlSize(.small)
            .disabled(viewModel.batchState == .processing)

            if let engine = viewModel.resolvedEngine {
                let models = engine.models
                if models.count > 1 {
                    Picker(String(localized: "Model"), selection: $viewModel.selectedModel) {
                        Text(String(localized: "Default")).tag(nil as String?)
                        Divider()
                        ForEach(models, id: \.id) { model in
                            Text(model.displayName).tag(model.id as String?)
                        }
                    }
                    .controlSize(.small)
                    .disabled(viewModel.batchState == .processing)
                }
            }
        }
    }

    private var fileTranscriptionLanguageOptions: [(code: String, name: String)] {
        let supportedLanguages = viewModel.selectedEngineSupportedLanguages
        guard !supportedLanguages.isEmpty else {
            return ServiceContainer.shared.settingsViewModel.availableLanguages
        }
        return localizedAppLanguageOptions(for: supportedLanguages)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { (code: $0.code, name: $0.name) }
    }

    @ViewBuilder
    private func enginePickerLabel(for engine: any TranscriptionEngine) -> some View {
        HStack {
            Text(engine.displayName)
            if !viewModel.canUseForTranscription(engine) {
                Text("(\(String(localized: "not ready")))")
                    .foregroundStyle(.secondary)
            } else if !viewModel.canPrepareForTranscription(engine) {
                Text("(\(String(localized: "not ready")))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Drop Handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

                let ext = url.pathExtension.lowercased()
                guard AudioFileService.supportedExtensions.contains(ext) else { return }

                Task { @MainActor in
                    viewModel.addFiles([url])
                }
            }
            handled = true
        }
        return handled
    }

    private func statusSummary(for item: FileTranscriptionViewModel.FileItem, phase: String) -> String {
        guard let elapsed = viewModel.elapsedTime(for: item) else { return phase }
        if let sourceProgress = item.sourceProgress {
            var parts = [
                "\(phase) - \(formattedSourceDuration(sourceProgress.processedDuration)) / \(formattedSourceDuration(sourceProgress.totalDuration)) \(String(localized: "processed"))"
            ]
            if let realtimeFactor = realtimeFactor(for: sourceProgress, elapsed: elapsed) {
                parts.append("\(realtimeFactor)x \(String(localized: "realtime"))")
            }
            parts.append(formattedElapsed(elapsed))
            return parts.joined(separator: " - ")
        }
        return "\(phase) - \(formattedElapsed(elapsed))"
    }

    private func formattedElapsed(_ elapsed: TimeInterval) -> String {
        let seconds = max(Int(elapsed.rounded()), 0)
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes > 0 {
            return String(format: "%d:%02d", minutes, remainder)
        }
        return "\(remainder)s"
    }

    private func formattedSourceDuration(_ duration: TimeInterval) -> String {
        let seconds = max(Int(duration.rounded()), 0)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%d:%02d", minutes, remainder)
    }

    private func realtimeFactor(
        for sourceProgress: TranscriptionSourceProgress,
        elapsed: TimeInterval
    ) -> String? {
        guard elapsed > 0,
              elapsed >= 5,
              sourceProgress.processedDuration >= 30 else {
            return nil
        }
        return String(format: "%.1f", sourceProgress.processedDuration / elapsed)
    }
}
