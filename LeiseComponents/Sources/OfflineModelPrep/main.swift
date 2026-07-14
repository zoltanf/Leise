import FluidAudio
import Foundation

@main
struct OfflineModelPrep {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(
                Data("Usage: OfflineModelPrep <OfflineModels directory>\n".utf8)
            )
            throw ExitCode.usage
        }

        let destination = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )

        let v2 = destination.appendingPathComponent(Repo.parakeetV2.folderName, isDirectory: true)
        let v3 = destination.appendingPathComponent(Repo.parakeetV3.folderName, isDirectory: true)
        let ctc = destination.appendingPathComponent(Repo.parakeetCtc110m.folderName, isDirectory: true)

        if !AsrModels.modelsExist(at: v2, version: .v2) {
            print("Preparing \(Repo.parakeetV2.remotePath) in \(destination.path)")
            try await AsrModels.download(to: v2, version: .v2)
        }
        if !AsrModels.modelsExist(at: v3, version: .v3) {
            print("Preparing \(Repo.parakeetV3.remotePath) in \(destination.path)")
            try await AsrModels.download(to: v3, version: .v3)
        }
        if !CtcModels.modelsExist(at: ctc)
            || !FileManager.default.fileExists(atPath: ctc.appendingPathComponent("tokenizer.json").path) {
            print("Preparing \(Repo.parakeetCtc110m.remotePath) in \(destination.path)")
            try await CtcModels.download(to: ctc, variant: .ctc110m, force: true)
        }

        try require(
            AsrModels.modelsExist(at: v2, version: .v2),
            "Parakeet TDT v2 is incomplete at \(v2.path)"
        )
        try require(
            AsrModels.modelsExist(at: v3, version: .v3),
            "Parakeet TDT v3 is incomplete at \(v3.path)"
        )
        try require(
            CtcModels.modelsExist(at: ctc),
            "Parakeet CTC 110M is incomplete at \(ctc.path)"
        )
        try require(
            FileManager.default.fileExists(
                atPath: ctc.appendingPathComponent("tokenizer.json").path
            ),
            "Parakeet CTC tokenizer.json is missing at \(ctc.path)"
        )

        // Validate the real Core ML payloads with networking disabled. A release
        // must fail here instead of shipping files that merely have the expected names.
        print("Loading Parakeet TDT v2 for offline verification")
        _ = try await AsrModels.load(from: v2, version: .v2)
        print("Loading Parakeet TDT v3 for offline verification")
        _ = try await AsrModels.load(from: v3, version: .v3)
        print("Loading Parakeet CTC 110M for offline verification")
        _ = try await CtcModels.loadDirect(from: ctc, variant: .ctc110m)
        _ = try await CtcTokenizer.load(from: ctc)

        print("All offline model assets are ready at \(destination.path)")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw PreparationError.invalidAssets(message) }
    }
}

private enum PreparationError: LocalizedError {
    case invalidAssets(String)

    var errorDescription: String? {
        switch self {
        case .invalidAssets(let message): message
        }
    }
}

private enum ExitCode: Error {
    case usage
}
