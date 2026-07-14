import Foundation

public protocol ParakeetStore: Sendable {
    func storeSecret(key: String, value: String) throws
    func loadSecret(key: String) -> String?
    func userDefault(forKey: String) -> Any?
    func setUserDefault(_ value: Any?, forKey: String)
    var shouldRestoreLoadedModelsPassively: Bool { get }
    var bundledModelsDirectory: URL? { get }
}

public extension ParakeetStore {
    var shouldRestoreLoadedModelsPassively: Bool { true }
    var bundledModelsDirectory: URL? { nil }
}

enum ParakeetAudioUtilities {
    static func paddedSamples(
        _ samples: [Float],
        minimumDuration: TimeInterval,
        sampleRate: Int = 16_000
    ) -> [Float] {
        let minimumSampleCount = Int(minimumDuration * Double(sampleRate))
        guard samples.count < minimumSampleCount else { return samples }
        return samples + repeatElement(.zero, count: minimumSampleCount - samples.count)
    }

    static func shouldAcceptShortClipTranscription(
        audioDuration: TimeInterval,
        confidence: Float,
        minimumDuration: TimeInterval = 1.0,
        minimumConfidence: Float = 0.55
    ) -> Bool {
        audioDuration >= minimumDuration || confidence >= minimumConfidence
    }
}

enum ParakeetHTTPClient {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sharedSession: URLSession?

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session().data(for: request)
    }

    static func data(
        for request: URLRequest,
        resourceTimeout: TimeInterval?
    ) async throws -> (Data, URLResponse) {
        guard let resourceTimeout else { return try await data(for: request) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = min(resourceTimeout, 60)
        configuration.timeoutIntervalForResource = resourceTimeout
        let requestSession = URLSession(configuration: configuration)
        defer { requestSession.finishTasksAndInvalidate() }
        return try await requestSession.data(for: request)
    }

    static func resetSharedSession(reason _: String? = nil) {
        let oldSession = lock.withLock {
            defer { sharedSession = nil }
            return sharedSession
        }
        oldSession?.finishTasksAndInvalidate()
    }

    private static func session() -> URLSession {
        lock.withLock {
            if let sharedSession { return sharedSession }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 600
            let created = URLSession(configuration: configuration)
            sharedSession = created
            return created
        }
    }
}

enum HuggingFaceTokenHelper {
    static let storageKey = "hf-token"
    static let environmentKeys = [
        "HF_TOKEN",
        "HUGGING_FACE_HUB_TOKEN",
        "HUGGINGFACEHUB_API_TOKEN",
    ]

    static func normalizedToken(_ token: String?) -> String? {
        guard let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    static func loadToken(from store: (any ParakeetStore)?) -> String? {
        normalizedToken(store?.loadSecret(key: storageKey))
    }

    @discardableResult
    static func saveToken(_ token: String, to store: (any ParakeetStore)?) -> String? {
        let normalized = normalizedToken(token)
        try? store?.storeSecret(key: storageKey, value: normalized ?? "")
        return normalized
    }

    static func clearToken(from store: (any ParakeetStore)?) {
        try? store?.storeSecret(key: storageKey, value: "")
    }

    static func validateToken(
        _ token: String,
        dataFetcher: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = ParakeetHTTPClient.data
    ) async -> Bool {
        guard let normalized = normalizedToken(token),
              let url = URL(string: "https://huggingface.co/api/whoami-v2") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(normalized)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        do {
            let (data, response) = try await dataFetcher(request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            return json["name"] != nil || json["type"] != nil || json["auth"] != nil
        } catch {
            return false
        }
    }

    static func applyTokenToEnvironment(_ token: String?) {
        guard let normalized = normalizedToken(token) else {
            environmentKeys.forEach { unsetenv($0) }
            return
        }
        environmentKeys.forEach { setenv($0, normalized, 1) }
    }
}

struct ParakeetSettingsActivity: Equatable, Sendable {
    let message: String
    let progress: Double?
    let isError: Bool

    init(message: String, progress: Double? = nil, isError: Bool = false) {
        self.message = message
        self.progress = progress
        self.isError = isError
    }
}
