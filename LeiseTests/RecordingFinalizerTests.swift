import AVFoundation
import XCTest
@testable import Leise

final class RecordingFinalizerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingFinalizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testMicOnlyM4AIsEncodedInChunksAndKeepsFullDuration() async throws {
        // Longer than two chunks so the read/write loop runs more than once.
        let mic = try makeWAV("mic.wav", seconds: 12, sampleRate: 48_000, channels: 1)
        let output = directory.appendingPathComponent("Recording.m4a")

        let outcome = await RecordingFinalizer.finalize(request(mic: mic, output: output, format: .m4a))

        XCTAssertEqual(outcome, .saved(output))
        XCTAssertEqual(try duration(of: output), 12, accuracy: 0.1)
    }

    func testMixUsesLongestTrackAndResamplesToCommonRate() async throws {
        let mic = try makeWAV("mic.wav", seconds: 7, sampleRate: 48_000, channels: 1)
        let system = try makeWAV("sys.wav", seconds: 11, sampleRate: 44_100, channels: 2)
        let output = directory.appendingPathComponent("Recording.wav")

        let outcome = await RecordingFinalizer.finalize(
            request(mic: mic, system: system, output: output, format: .wav)
        )

        XCTAssertEqual(outcome, .saved(output))
        let file = try AVAudioFile(forReading: output)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(try duration(of: output), 11, accuracy: 0.1)
    }

    func testStalledEncoderPreservesTheRawWAV() async throws {
        let mic = try makeWAV("mic-track.wav", seconds: 1, sampleRate: 48_000, channels: 1)
        let output = directory.appendingPathComponent("Recording.m4a")

        let outcome = await RecordingFinalizer.finalize(
            request(mic: mic, output: output, format: .m4a),
            stallTimeout: 0.2,
            renderer: { request, _ in
                FileManager.default.createFile(atPath: request.outputURL.path, contents: Data())
                Thread.sleep(forTimeInterval: 2)
            }
        )

        let preserved = directory.appendingPathComponent("Recording.wav")
        XCTAssertEqual(outcome, .preservedRawAudio(preserved))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mic.path))
        XCTAssertEqual(try duration(of: preserved), 1, accuracy: 0.01)
    }

    func testTruncatedOutputPreservesBothRawTracks() async throws {
        let mic = try makeWAV("mic-track.wav", seconds: 2, sampleRate: 48_000, channels: 1)
        let system = try makeWAV("sys-track.wav", seconds: 2, sampleRate: 48_000, channels: 2)
        let short = try makeWAV("short.wav", seconds: 0.5, sampleRate: 48_000, channels: 1)
        let output = directory.appendingPathComponent("Recording.m4a")

        let outcome = await RecordingFinalizer.finalize(
            request(mic: mic, system: system, output: output, format: .m4a),
            renderer: { request, _ in
                // Simulates the encoder giving up part way through.
                try FileManager.default.copyItem(at: short, to: request.outputURL)
            }
        )

        let micCopy = directory.appendingPathComponent("Recording (Microphone).wav")
        let systemCopy = directory.appendingPathComponent("Recording (System Audio).wav")
        XCTAssertEqual(outcome, .preservedRawAudio(micCopy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemCopy.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testUnreadableOutputPreservesTheRawWAVEvenForAVeryShortRecording() async throws {
        // Shorter than the duration tolerance, so only the readability check can catch it.
        let mic = try makeWAV("mic-track.wav", seconds: 0.3, sampleRate: 48_000, channels: 1)
        let output = directory.appendingPathComponent("Recording.m4a")

        let outcome = await RecordingFinalizer.finalize(
            request(mic: mic, output: output, format: .m4a),
            renderer: { request, _ in
                try Data(repeating: 0, count: 2_048).write(to: request.outputURL)
            }
        )

        XCTAssertEqual(outcome, .preservedRawAudio(directory.appendingPathComponent("Recording.wav")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testLowSampleRateMicEncodesToM4A() async throws {
        // Bluetooth HFP microphones capture at 16 kHz, where 192 kbps AAC is rejected.
        let mic = try makeWAV("mic.wav", seconds: 3, sampleRate: 16_000, channels: 1)
        let output = directory.appendingPathComponent("Recording.m4a")

        let outcome = await RecordingFinalizer.finalize(request(mic: mic, output: output, format: .m4a))

        XCTAssertEqual(outcome, .saved(output))
        XCTAssertEqual(try duration(of: output), 3, accuracy: 0.1)
    }

    func testEmptyRecordingReportsEmpty() async throws {
        let mic = try makeWAV("mic.wav", seconds: 0, sampleRate: 48_000, channels: 1)
        let output = directory.appendingPathComponent("Recording.m4a")

        let outcome = await RecordingFinalizer.finalize(request(mic: mic, output: output, format: .m4a))

        XCTAssertEqual(outcome, .empty)
    }

    func testUnreadableTrackIsPreservedRatherThanTreatedAsEmpty() async throws {
        let mic = directory.appendingPathComponent("mic-track.wav")
        try Data(repeating: 7, count: 4_096).write(to: mic)
        let output = directory.appendingPathComponent("Recording.m4a")

        let outcome = await RecordingFinalizer.finalize(request(mic: mic, output: output, format: .m4a))

        XCTAssertEqual(outcome, .preservedRawAudio(directory.appendingPathComponent("Recording.wav")))
    }

    func testUnreachableRecordingsFolderLeavesTempTrackInPlace() async throws {
        let mic = try makeWAV("mic-track.wav", seconds: 1, sampleRate: 48_000, channels: 1)
        let output = directory
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("Recording.m4a")

        let outcome = await RecordingFinalizer.finalize(request(mic: mic, output: output, format: .m4a))

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mic.path))
    }

    func testRepairsHeaderOfWAVThatWasNeverClosed() throws {
        let wav = try makeWAV("crashed.wav", seconds: 2, sampleRate: 48_000, channels: 1)
        // Zero the RIFF and data sizes, as a writer killed before close leaves them.
        let handle = try FileHandle(forUpdating: wav)
        let bytes = try XCTUnwrap(handle.readToEnd())
        let dataOffset = try XCTUnwrap(bytes.range(of: Data("data".utf8))).lowerBound
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: Data(count: 4))
        try handle.seek(toOffset: UInt64(dataOffset + 4))
        try handle.write(contentsOf: Data(count: 4))
        try handle.close()
        XCTAssertLessThan((try? duration(of: wav)) ?? 0, 1)

        RecordingFinalizer.repairWAVHeaderIfNeeded(at: wav)

        XCTAssertEqual(try duration(of: wav), 2, accuracy: 0.01)
    }

    func testRecoversOnlyStaleRecorderTempTracks() throws {
        let tempDirectory = directory.appendingPathComponent("tmp", isDirectory: true)
        let recordings = directory.appendingPathComponent("Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let session = UUID().uuidString
        let stale = Date().addingTimeInterval(-3_600)

        let staleMic = try makeFile(tempDirectory, "mic-\(session).wav", modified: stale)
        let staleSystem = try makeFile(tempDirectory, "sys-\(session).wav", modified: stale)
        let live = try makeFile(tempDirectory, "mic-\(UUID().uuidString).wav", modified: Date())
        let unrelated = try makeFile(tempDirectory, "mic-notes.wav", modified: stale)

        let recovered = RecordingFinalizer.recoverOrphanedTracks(in: tempDirectory, to: recordings)

        XCTAssertEqual(recovered.count, 2)
        XCTAssertTrue(recovered.allSatisfy { $0.lastPathComponent.hasPrefix("Recovered Recording ") })
        XCTAssertEqual(recovered.filter { $0.lastPathComponent.hasSuffix("(Microphone).wav") }.count, 1)
        XCTAssertEqual(recovered.filter { $0.lastPathComponent.hasSuffix("(System Audio).wav") }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleMic.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleSystem.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    // MARK: - Helpers

    private func request(
        mic: URL? = nil,
        system: URL? = nil,
        output: URL,
        format: AudioRecorderService.OutputFormat
    ) -> RecordingFinalizer.Request {
        RecordingFinalizer.Request(
            micURL: mic,
            systemURL: system,
            outputURL: output,
            format: format,
            trackMode: .mixed,
            micDuckingMode: .aggressive
        )
    }

    /// Writes a sine-tone WAV in the 16-bit PCM format the recorder captures.
    private func makeWAV(
        _ name: String,
        seconds: Double,
        sampleRate: Double,
        channels: AVAudioChannelCount
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ))
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard frames > 0 else { return url }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try XCTUnwrap(buffer.floatChannelData?[channel])
            for i in 0..<Int(frames) {
                data[i] = 0.2 * sin(Float(i) * 2 * .pi * 440 / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func makeFile(_ directory: URL, _ name: String, modified: Date) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("RIFF".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    private func duration(of url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
