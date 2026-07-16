import AppKit
import Foundation
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Leise", category: "TermPackRegistry")

// MARK: - Registry Models

struct TermPackRegistryResponse: Codable {
    let schemaVersion: Int
    let packs: [RemoteTermPack]
}

struct RemoteTermPack: Codable {
    let id: String
    let name: String
    let description: String
    let icon: String
    let version: String
    let author: String
    let terms: [String]?
    let corrections: [TermPackCorrection]?
    let names: [String: String]?
    let descriptions: [String: String]?

    func toTermPack() -> TermPack {
        TermPack(
            id: id,
            name: name,
            description: description,
            icon: icon,
            terms: terms ?? [],
            corrections: corrections ?? [],
            version: version,
            author: author,
            localizedNames: names,
            localizedDescriptions: descriptions
        )
    }
}

// MARK: - Term Pack Registry Service

@MainActor
final class TermPackRegistryService: ObservableObject {
    @Published var communityPacks: [TermPack] = []
    @Published var fetchState: FetchState = .idle

    private var lastFetchDate: Date?
    private let registryURL: URL?
    private let cacheDuration: TimeInterval
    private let userDefaults: UserDefaults
    private let fetchData: (URLRequest) async throws -> (Data, URLResponse)
    private let bundledRegistryData: () -> Data?

    /// Remote responses larger than this are rejected before decoding.
    static let maxRegistryResponseBytes = 5_000_000

    /// Name of the vendored registry snapshot in the asset catalog.
    static let bundledRegistryAssetName = "TermPackRegistry"

    enum FetchState: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    /// By default the app uses the vendored registry snapshot bundled with the
    /// app: the fork must not depend on upstream-controlled infrastructure at
    /// runtime. A remote registry is only consulted when the user explicitly
    /// configures one via the `termPackRegistryURL` default.
    init(
        registryURL: URL? = nil,
        cacheDuration: TimeInterval = 300,
        userDefaults: UserDefaults = .standard,
        fetchData: @escaping (URLRequest) async throws -> (Data, URLResponse) = { request in
            try await URLSession.shared.data(for: request)
        },
        bundledRegistryData: @escaping () -> Data? = {
            NSDataAsset(name: TermPackRegistryService.bundledRegistryAssetName)?.data
        }
    ) {
        self.registryURL = registryURL ?? Self.configuredRegistryURL(from: userDefaults)
        self.cacheDuration = cacheDuration
        self.userDefaults = userDefaults
        self.fetchData = fetchData
        self.bundledRegistryData = bundledRegistryData
    }

    static func configuredRegistryURL(from userDefaults: UserDefaults) -> URL? {
        guard let raw = userDefaults.string(forKey: UserDefaultsKeys.termPackRegistryURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        return URL(string: raw)
    }

    // MARK: - Fetch Registry

    @discardableResult
    func fetchRegistry(force: Bool = false) async -> Bool {
        if !force,
           let lastFetch = lastFetchDate,
           Date().timeIntervalSince(lastFetch) < cacheDuration,
           !communityPacks.isEmpty {
            return true
        }

        fetchState = .loading

        guard let registryURL else {
            return loadBundledRegistry()
        }

        do {
            var request = URLRequest(url: registryURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await fetchData(request)

            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                fetchState = .error("Registry request failed with status \(httpResponse.statusCode)")
                logger.error("Registry request failed: status=\(httpResponse.statusCode)")
                return false
            }
            guard data.count <= Self.maxRegistryResponseBytes else {
                fetchState = .error("Registry response too large")
                logger.error("Registry response too large: \(data.count) bytes")
                return false
            }

            return applyRegistryData(data)
        } catch {
            fetchState = .error(error.localizedDescription)
            logger.error("Failed to fetch term pack registry: \(error.localizedDescription)")
            return false
        }
    }

    private func loadBundledRegistry() -> Bool {
        guard let data = bundledRegistryData() else {
            fetchState = .error("Bundled term pack registry unavailable")
            logger.error("Bundled term pack registry asset missing")
            return false
        }
        return applyRegistryData(data)
    }

    private func applyRegistryData(_ data: Data) -> Bool {
        do {
            let response = try JSONDecoder().decode(TermPackRegistryResponse.self, from: data)

            guard response.schemaVersion == 1 else {
                fetchState = .error("Unsupported registry schema version \(response.schemaVersion)")
                logger.error("Unsupported schema version: \(response.schemaVersion)")
                return false
            }

            // Filter out packs that collide with built-in IDs or have duplicate IDs
            var seenIDs = Set<String>()
            var validPacks: [TermPack] = []

            for remote in response.packs {
                if TermPack.builtInIDs.contains(remote.id) {
                    logger.warning("Skipping community pack '\(remote.id)': collides with built-in ID")
                    continue
                }
                if seenIDs.contains(remote.id) {
                    logger.warning("Skipping duplicate community pack '\(remote.id)'")
                    continue
                }
                if (remote.terms ?? []).isEmpty && (remote.corrections ?? []).isEmpty {
                    logger.warning("Skipping community pack '\(remote.id)': no terms or corrections")
                    continue
                }
                seenIDs.insert(remote.id)
                validPacks.append(remote.toTermPack())
            }

            // Sort by localized name for stable display order
            communityPacks = validPacks.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            lastFetchDate = Date()
            fetchState = .loaded
            logger.info("Loaded \(self.communityPacks.count) community term pack(s)")
            return true
        } catch {
            fetchState = .error(error.localizedDescription)
            logger.error("Failed to decode term pack registry: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Background Update Check

    func checkForUpdatesInBackground() {
        // The bundled snapshot only changes with app updates; there is nothing
        // to poll unless a remote registry override is configured.
        guard registryURL != nil else { return }

        let lastCheck = userDefaults.double(forKey: UserDefaultsKeys.termPackRegistryLastUpdateCheck)
        let hoursSinceLastCheck = (Date().timeIntervalSince1970 - lastCheck) / 3600
        guard hoursSinceLastCheck >= 24 || lastCheck == 0 else { return }

        Task {
            if await fetchRegistry(force: true) {
                userDefaults.set(Date().timeIntervalSince1970, forKey: UserDefaultsKeys.termPackRegistryLastUpdateCheck)
            }
        }
    }

    // MARK: - Version Comparison

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let partsA = a.split(separator: ".").compactMap { Int($0) }
        let partsB = b.split(separator: ".").compactMap { Int($0) }
        let count = max(partsA.count, partsB.count)
        for i in 0..<count {
            let va = i < partsA.count ? partsA[i] : 0
            let vb = i < partsB.count ? partsB[i] : 0
            if va < vb { return .orderedAscending }
            if va > vb { return .orderedDescending }
        }
        return .orderedSame
    }
}
