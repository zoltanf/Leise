import Foundation
@preconcurrency import AVFoundation
import os

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "leise-mac", category: "RecordingFinalizer")

/// Turns the recorder's temporary WAV tracks into the saved recording.
///
/// Audio is processed in fixed-size chunks so memory stays flat regardless of
/// recording length, and every chunk beats a heartbeat so a stalled encoder is
/// detected instead of leaving the recorder stuck in `.finalizing`. When the
/// output cannot be produced or comes out short, the raw WAV tracks are moved
/// into the recordings folder instead of being deleted.
enum RecordingFinalizer {
    struct Request: Sendable {
        let micURL: URL?
        let systemURL: URL?
        let outputURL: URL
        let format: AudioRecorderService.OutputFormat
        let trackMode: AudioRecorderService.TrackMode
        let micDuckingMode: AudioRecorderService.MicDuckingMode
    }

    enum Outcome: Equatable, Sendable {
        case saved(URL)
        /// Conversion failed; the raw WAV track(s) were moved next to where the
        /// recording would have been. The URL is the first track that moved
        /// (the microphone track when there is one). Tracks that could not be
        /// moved stay in the temp folder for launch recovery.
        case preservedRawAudio(URL)
        /// The tracks held no audio; there is nothing to keep.
        case empty
        /// Nothing could be written or preserved. The temp tracks are left in
        /// place for launch recovery.
        case failed

        var url: URL? {
            switch self {
            case .saved(let url), .preservedRawAudio(let url): url
            case .empty, .failed: nil
            }
        }
    }

    enum FinalizationError: LocalizedError {
        case noSource
        case cannotCreateFormat
        case cannotAllocateBuffer
        case cannotCreateConverter
        case truncatedOutput(actual: TimeInterval, expected: TimeInterval)
        case unreadableOutput
        case stalled

        var errorDescription: String? {
            switch self {
            case .noSource: "No source track to finalize"
            case .cannotCreateFormat: "Cannot create mix format"
            case .cannotAllocateBuffer: "Cannot allocate conversion buffer"
            case .cannotCreateConverter: "Cannot create audio converter"
            case .truncatedOutput(let actual, let expected):
                "Output holds \(actual)s of \(expected)s"
            case .unreadableOutput: "Output file cannot be read back"
            case .stalled: "Encoder made no progress"
            }
        }
    }

    static let chunkDuration: TimeInterval = 5
    static let defaultStallTimeout: TimeInterval = 30
    /// Slack for encoder priming/remainder frames when comparing durations.
    private static let durationTolerance: TimeInterval = 0.5

    // MARK: - Finalize

    static func finalize(
        _ request: Request,
        stallTimeout: TimeInterval = defaultStallTimeout,
        renderer: @escaping @Sendable (Request, Heartbeat) throws -> Void = { try render($0, heartbeat: $1) }
    ) async -> Outcome {
        guard let sourceDuration = expectedDuration(of: request) else {
            logger.error("A recording track could not be opened")
            return await abandonOutput(of: request)
        }
        guard sourceDuration > 0 else {
            logger.error("Recording contains no audio")
            return .empty
        }

        let heartbeat = Heartbeat()
        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            // Encoding is long blocking work and can stall inside AVFoundation,
            // so it runs on GCD rather than a cooperative-pool thread. A stalled
            // job is abandoned: it only ever touches the output file, which is
            // deleted below.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try renderer(request, heartbeat)
                    try verifyOutput(of: request, expectedDuration: sourceDuration)
                    once.resume(.success(()))
                } catch {
                    once.resume(.failure(error))
                }
            }
            watchForStall(heartbeat: heartbeat, timeout: stallTimeout, once: once)
        }

        switch result {
        case .success:
            return .saved(request.outputURL)
        case .failure(let error):
            logger.error("Failed to finalize recording: \(error.localizedDescription)")
            return await abandonOutput(of: request)
        }
    }

    private static func abandonOutput(of request: Request) async -> Outcome {
        await onBackgroundQueue {
            try? FileManager.default.removeItem(at: request.outputURL)
            return preserveRawAudio(of: request)
        }
    }

    /// Runs blocking file work (moves can cross volumes) off the cooperative pool.
    static func onBackgroundQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func watchForStall(heartbeat: Heartbeat, timeout: TimeInterval, once: ResumeOnce) {
        let interval = min(1, timeout / 4)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interval) {
            guard !once.isResumed else { return }
            if heartbeat.secondsSinceLastBeat > timeout {
                once.resume(.failure(FinalizationError.stalled))
            } else {
                watchForStall(heartbeat: heartbeat, timeout: timeout, once: once)
            }
        }
    }

    // MARK: - Rendering

    static func render(_ request: Request, heartbeat: Heartbeat) throws {
        switch (request.micURL, request.systemURL) {
        case let (mic?, system?):
            try mix(
                micURL: mic,
                systemURL: system,
                outputURL: request.outputURL,
                format: request.format,
                trackMode: request.trackMode,
                micDuckingMode: request.micDuckingMode,
                heartbeat: heartbeat
            )
        case let (source?, nil), let (nil, source?):
            try convert(from: source, to: request.outputURL, format: request.format, heartbeat: heartbeat)
        case (nil, nil):
            throw FinalizationError.noSource
        }
    }

    private static func convert(
        from sourceURL: URL,
        to destinationURL: URL,
        format: AudioRecorderService.OutputFormat,
        heartbeat: Heartbeat
    ) throws {
        if format == .wav {
            try copy(from: sourceURL, to: destinationURL, heartbeat: heartbeat)
            return
        }

        let source = try AVAudioFile(forReading: sourceURL)
        let processingFormat = source.processingFormat
        let output = try AVAudioFile(
            forWriting: destinationURL,
            settings: outputSettings(
                format: format,
                sampleRate: processingFormat.sampleRate,
                channels: processingFormat.channelCount
            ),
            commonFormat: processingFormat.commonFormat,
            interleaved: processingFormat.isInterleaved
        )
        let chunkFrames = frames(for: processingFormat.sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkFrames) else {
            throw FinalizationError.cannotAllocateBuffer
        }

        while source.framePosition < source.length {
            try source.read(into: buffer, frameCount: chunkFrames)
            guard buffer.frameLength > 0 else { break }
            try output.write(from: buffer)
            heartbeat.beat()
        }
        close(output)
    }

    /// Clones within a volume; otherwise copies in chunks so a slow destination
    /// volume keeps beating the heartbeat.
    private static func copy(from sourceURL: URL, to destinationURL: URL, heartbeat: Heartbeat) throws {
        if isSameVolume(sourceURL, destinationURL.deletingLastPathComponent()) {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return
        }
        guard FileManager.default.createFile(atPath: destinationURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destinationURL.path])
        }
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }
        while let data = try input.read(upToCount: 8 << 20), !data.isEmpty {
            try output.write(contentsOf: data)
            heartbeat.beat()
        }
    }

    private static func isSameVolume(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = try? lhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let right = try? rhs.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier else {
            return false
        }
        return left.isEqual(right)
    }

    private static func mix(
        micURL: URL,
        systemURL: URL,
        outputURL: URL,
        format: AudioRecorderService.OutputFormat,
        trackMode: AudioRecorderService.TrackMode,
        micDuckingMode: AudioRecorderService.MicDuckingMode,
        heartbeat: Heartbeat
    ) throws {
        let micFile = try AVAudioFile(forReading: micURL)
        let systemFile = try AVAudioFile(forReading: systemURL)
        let sampleRate = max(micFile.processingFormat.sampleRate, systemFile.processingFormat.sampleRate)
        let channels: AVAudioChannelCount = 2
        guard let mixFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else { throw FinalizationError.cannotCreateFormat }

        let chunkFrames = frames(for: sampleRate)
        let micReader = try ChunkReader(file: micFile, targetFormat: mixFormat, chunkFrames: chunkFrames)
        let systemReader = try ChunkReader(file: systemFile, targetFormat: mixFormat, chunkFrames: chunkFrames)
        guard let micChunk = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: chunkFrames),
              let systemChunk = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: chunkFrames),
              let mixedChunk = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: chunkFrames),
              let micData = micChunk.floatChannelData,
              let systemData = systemChunk.floatChannelData,
              let mixedData = mixedChunk.floatChannelData else {
            throw FinalizationError.cannotAllocateBuffer
        }

        let output = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings(format: format, sampleRate: sampleRate, channels: channels),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        var ducker = trackMode == .mixed ? MicDucker(mode: micDuckingMode, sampleRate: sampleRate) : nil

        while true {
            try micReader.read(into: micChunk)
            try systemReader.read(into: systemChunk)
            let micFrames = Int(micChunk.frameLength)
            let systemFrames = Int(systemChunk.frameLength)
            let frameCount = max(micFrames, systemFrames)
            guard frameCount > 0 else { break }

            for i in 0..<frameCount {
                let micLeft = i < micFrames ? micData[0][i] : 0
                let micRight = i < micFrames ? micData[1][i] : 0
                let systemLeft = i < systemFrames ? systemData[0][i] : 0
                let systemRight = i < systemFrames ? systemData[1][i] : 0

                if trackMode == .separate {
                    mixedData[0][i] = (micLeft + micRight) * 0.5
                    mixedData[1][i] = (systemLeft + systemRight) * 0.5
                } else {
                    let micGain = ducker?.gain(forReferenceSample: (systemLeft + systemRight) * 0.5) ?? 1
                    mixedData[0][i] = micLeft * micGain + systemLeft
                    mixedData[1][i] = micRight * micGain + systemRight
                }
            }
            mixedChunk.frameLength = AVAudioFrameCount(frameCount)
            try output.write(from: mixedChunk)
            heartbeat.beat()
        }
        close(output)
    }

    private static func outputSettings(
        format: AudioRecorderService.OutputFormat,
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) -> [String: Any] {
        switch format {
        case .wav:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        case .m4a:
            // The AAC encoder rejects 192 kbps below 44.1 kHz (e.g. Bluetooth
            // HFP mics at 16/24 kHz); its default bit rate works at every rate.
            sampleRate >= 44_100
                ? [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: 192000,
                ]
                : [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                ]
        }
    }

    private static func frames(for sampleRate: Double) -> AVAudioFrameCount {
        AVAudioFrameCount(sampleRate * chunkDuration)
    }

    /// Writes the container trailer (the m4a `moov` atom) now rather than at deinit.
    private static func close(_ file: AVAudioFile) {
        if #available(macOS 15.0, *) {
            file.close()
        }
    }

    // MARK: - Verification

    /// The longest track's duration, or nil when any track cannot be opened
    /// (so an unreadable track is preserved rather than treated as empty).
    private static func expectedDuration(of request: Request) -> TimeInterval? {
        var longest: TimeInterval = 0
        for url in [request.micURL, request.systemURL].compactMap({ $0 }) {
            guard let file = try? AVAudioFile(forReading: url) else { return nil }
            longest = max(longest, Double(file.length) / file.fileFormat.sampleRate)
        }
        return longest
    }

    /// The output must open and hold audio before the tolerance applies, so a
    /// missing or corrupt file never passes for a sub-tolerance recording.
    private static func verifyOutput(of request: Request, expectedDuration: TimeInterval) throws {
        guard let output = try? AVAudioFile(forReading: request.outputURL), output.length > 0 else {
            throw FinalizationError.unreadableOutput
        }
        let actual = Double(output.length) / output.fileFormat.sampleRate
        guard actual + durationTolerance >= expectedDuration else {
            throw FinalizationError.truncatedOutput(actual: actual, expected: expectedDuration)
        }
    }

    // MARK: - Raw audio preservation

    private static func preserveRawAudio(of request: Request) -> Outcome {
        let base = request.outputURL.deletingPathExtension()
        let tracks: [(URL, String)] = [
            request.micURL.map { ($0, "Microphone") },
            request.systemURL.map { ($0, "System Audio") },
        ].compactMap { $0 }
        let singleTrack = tracks.count == 1

        var preserved: [URL] = []
        for (source, label) in tracks where FileManager.default.fileExists(atPath: source.path) {
            let name = singleTrack ? base.lastPathComponent : "\(base.lastPathComponent) (\(label))"
            let destination = uniqueURL(
                in: base.deletingLastPathComponent(),
                name: name,
                pathExtension: "wav"
            )
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                preserved.append(destination)
            } catch {
                logger.error("Failed to preserve raw recording track: \(error.localizedDescription)")
            }
        }
        return preserved.first.map(Outcome.preservedRawAudio) ?? .failed
    }

    // MARK: - Launch recovery

    /// Moves recorder temp tracks left behind by a crash or a failed stop into
    /// `recordingsDirectory`, repairing unclosed WAV headers. Files modified
    /// within `minimumAge` are skipped because another Leise instance may
    /// still be recording into them.
    static func recoverOrphanedTracks(
        in temporaryDirectory: URL,
        to recordingsDirectory: URL,
        now: Date = Date(),
        minimumAge: TimeInterval = 120
    ) -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: keys
        ) else { return [] }

        let orphans = files.compactMap { url -> (url: URL, session: String, kind: String, created: Date)? in
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-", maxSplits: 1)
            guard url.pathExtension == "wav", parts.count == 2,
                  parts[0] == "mic" || parts[0] == "sys",
                  UUID(uuidString: String(parts[1])) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) >= minimumAge else { return nil }
            return (url, String(parts[1]), String(parts[0]), values.creationDate ?? modified)
        }
        guard !orphans.isEmpty else { return [] }
        try? FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let sessions = Dictionary(grouping: orphans, by: \.session)

        var recovered: [URL] = []
        for tracks in sessions.values {
            let started = tracks.map(\.created).min() ?? now
            for track in tracks.sorted(by: { $0.kind < $1.kind }) {
                repairWAVHeaderIfNeeded(at: track.url)
                var name = "Recovered Recording \(formatter.string(from: started))"
                if tracks.count > 1 {
                    name += track.kind == "mic" ? " (Microphone)" : " (System Audio)"
                }
                let destination = uniqueURL(in: recordingsDirectory, name: name, pathExtension: "wav")
                do {
                    try FileManager.default.moveItem(at: track.url, to: destination)
                    recovered.append(destination)
                } catch {
                    logger.error("Failed to recover orphaned recording track: \(error.localizedDescription)")
                }
            }
        }
        return recovered
    }

    /// A WAV whose writer never closed it (the app crashed mid-recording) still
    /// carries zero RIFF and `data` sizes, so players report it as empty. Patch
    /// both from the file size. Headers that look written are left alone.
    static func repairWAVHeaderIfNeeded(at url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 12, fileSize <= UInt64(UInt32.max),
              (try? handle.seek(toOffset: 0)) != nil,
              let header = try? handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else { return }

        var offset: UInt64 = 12
        while offset + 8 <= fileSize {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let chunk = try? handle.read(upToCount: 8), chunk.count == 8 else { return }
            let size = chunk.suffix(4).reduce(into: (value: UInt64(0), shift: UInt64(0))) { result, byte in
                result.value |= UInt64(byte) << result.shift
                result.shift += 8
            }.value
            guard chunk.prefix(4) == Data("data".utf8) else {
                offset += 8 + size + (size & 1)
                continue
            }
            let actual = fileSize - offset - 8
            guard size == 0 || size > actual else { return }
            func littleEndian(_ value: UInt64) -> Data {
                withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) }
            }
            try? handle.seek(toOffset: offset + 4)
            try? handle.write(contentsOf: littleEndian(actual))
            try? handle.seek(toOffset: 4)
            try? handle.write(contentsOf: littleEndian(fileSize - 8))
            return
        }
    }

    private static func uniqueURL(in directory: URL, name: String, pathExtension: String) -> URL {
        var candidate = directory.appendingPathComponent(name).appendingPathExtension(pathExtension)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(suffix)").appendingPathExtension(pathExtension)
            suffix += 1
        }
        return candidate
    }
}

// MARK: - Support types

extension RecordingFinalizer {
    /// Last time the render loop made progress; read by the stall watchdog.
    final class Heartbeat: Sendable {
        // Uptime, like the watchdog's `asyncAfter` deadline, so sleeping the
        // Mac mid-finalization does not read as a stall.
        private let lastBeat = OSAllocatedUnfairLock(initialState: DispatchTime.now().uptimeNanoseconds)

        func beat() {
            lastBeat.withLock { $0 = DispatchTime.now().uptimeNanoseconds }
        }

        var secondsSinceLastBeat: TimeInterval {
            let last = lastBeat.withLock { $0 }
            let now = DispatchTime.now().uptimeNanoseconds
            return now > last ? Double(now - last) / 1_000_000_000 : 0
        }
    }

    /// Resumes a continuation exactly once, whichever of the render job and
    /// the watchdog finishes first.
    private final class ResumeOnce: Sendable {
        private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Result<Void, Error>, Never>?>

        init(_ continuation: CheckedContinuation<Result<Void, Error>, Never>) {
            self.continuation = OSAllocatedUnfairLock(initialState: continuation)
        }

        var isResumed: Bool {
            continuation.withLock { $0 == nil }
        }

        func resume(_ result: Result<Void, Error>) {
            let pending = continuation.withLock { value in
                defer { value = nil }
                return value
            }
            pending?.resume(returning: result)
        }
    }

    /// Reads a file chunk by chunk in `targetFormat`, resampling and remapping
    /// channels when the file's format differs. Short reads mean end of file.
    /// Confined to the render thread; the converter calls its input block
    /// synchronously inside `convert`, hence `@unchecked Sendable`.
    private final class ChunkReader: @unchecked Sendable {
        private let file: AVAudioFile
        private let converter: AVAudioConverter?
        private let sourceBuffer: AVAudioPCMBuffer
        /// The file has been read to the end (the converter may still hold frames).
        private var sourceExhausted = false
        /// No more output frames will be produced.
        private var finished = false
        private var readError: Error?

        init(file: AVAudioFile, targetFormat: AVAudioFormat, chunkFrames: AVAudioFrameCount) throws {
            self.file = file
            let sourceFormat = file.processingFormat
            if sourceFormat == targetFormat {
                converter = nil
            } else {
                guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                    throw FinalizationError.cannotCreateConverter
                }
                self.converter = converter
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames) else {
                throw FinalizationError.cannotAllocateBuffer
            }
            sourceBuffer = buffer
        }

        func read(into output: AVAudioPCMBuffer) throws {
            output.frameLength = 0
            guard !finished else { return }

            guard let converter else {
                // AVAudioFile throws when asked to read at end of file.
                guard file.framePosition < file.length else {
                    finished = true
                    return
                }
                try file.read(into: output, frameCount: output.frameCapacity)
                return
            }

            readError = nil
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                if self.file.framePosition >= self.file.length {
                    self.sourceExhausted = true
                }
                if self.sourceExhausted {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try self.file.read(into: self.sourceBuffer, frameCount: self.sourceBuffer.frameCapacity)
                } catch {
                    self.readError = error
                }
                guard self.readError == nil, self.sourceBuffer.frameLength > 0 else {
                    self.sourceExhausted = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return self.sourceBuffer
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? FinalizationError.cannotCreateConverter }
            if status == .endOfStream { finished = true }
        }
    }
}
