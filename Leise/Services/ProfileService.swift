import Foundation
import SwiftData
import Combine
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Leise", category: "ProfileService")

enum RuleMatchKind: String, Sendable {
    case appAndWebsite
    case websiteOnly
    case appOnly
    case globalFallback
    case manualOverride

    var label: String {
        switch self {
        case .appAndWebsite:
            String(localized: "App + Website")
        case .websiteOnly:
            String(localized: "Website Only")
        case .appOnly:
            String(localized: "App Only")
        case .globalFallback:
            String(localized: "Global Fallback")
        case .manualOverride:
            String(localized: "Manual Override")
        }
    }
}

struct RuleMatchResult {
    let profile: Profile
    let kind: RuleMatchKind
    let matchedDomain: String?
    let competingProfileCount: Int
    let wonByPriority: Bool
}

@MainActor
final class ProfileService: ObservableObject {
    @Published var profiles: [Profile] = []

    private let modelContainer: ModelContainer?
    private let modelContext: ModelContext?

    init(appSupportDirectory: URL = AppConstants.appSupportDirectory) {

        do {
            let (container, context) = try SwiftDataStoreFactory.create(
                for: [Profile.self],
                storeName: "profiles",
                in: appSupportDirectory
            )
            modelContainer = container
            modelContext = context
        } catch {
            // A corrupt or unopenable store must not make the app unlaunchable;
            // profiles are simply unavailable until the store can be recreated.
            logger.error("Failed to initialize profiles store: \(error.localizedDescription)")
            modelContainer = nil
            modelContext = nil
        }

        fetchProfiles()
    }

    func addProfile(
        name: String,
        isEnabled: Bool = true,
        bundleIdentifiers: [String] = [],
        urlPatterns: [String] = [],
        inputLanguage: String? = nil,
        engineOverride: String? = nil,
        cloudModelOverride: String? = nil,
        outputFormat: String? = nil,
        hotkeyData: Data? = nil,
        autoEnterEnabled: Bool = false,
        priority: Int = 0
    ) {
        let profile = Profile(
            name: name,
            isEnabled: isEnabled,
            priority: priority,
            bundleIdentifiers: bundleIdentifiers,
            urlPatterns: urlPatterns,
            inputLanguage: inputLanguage,
            engineOverride: engineOverride,
            cloudModelOverride: cloudModelOverride,
            outputFormat: outputFormat,
            hotkeyData: hotkeyData,
            autoEnterEnabled: autoEnterEnabled
        )
        modelContext?.insert(profile)
        save()
        fetchProfiles()
    }

    func nextPriority() -> Int {
        (profiles.map(\.priority).max() ?? -1) + 1
    }

    func updateProfile(_ profile: Profile) {
        profile.updatedAt = Date()
        save()
        fetchProfiles()
    }

    func deleteProfile(_ profile: Profile) {
        modelContext?.delete(profile)
        save()
        fetchProfiles()
    }

    func replaceAll(with snapshots: [BackupProfile]) throws {
        guard let modelContext else {
            throw CocoaError(.persistentStoreOpen)
        }
        do {
            for profile in try modelContext.fetch(FetchDescriptor<Profile>()) {
                modelContext.delete(profile)
            }
            for snapshot in snapshots {
                modelContext.insert(Profile(
                    id: snapshot.id,
                    name: snapshot.name,
                    isEnabled: snapshot.isEnabled,
                    priority: snapshot.priority,
                    bundleIdentifiers: snapshot.bundleIdentifiers,
                    urlPatterns: snapshot.urlPatterns,
                    inputLanguage: snapshot.inputLanguage,
                    engineOverride: snapshot.engineOverride,
                    cloudModelOverride: snapshot.cloudModelOverride,
                    outputFormat: snapshot.outputFormat,
                    hotkeyData: snapshot.hotkeyData,
                    autoEnterEnabled: snapshot.autoEnterEnabled,
                    createdAt: snapshot.createdAt,
                    updatedAt: snapshot.updatedAt
                ))
            }
            try modelContext.save()
            fetchProfiles()
        } catch {
            modelContext.rollback()
            fetchProfiles()
            throw error
        }
    }

    func toggleProfile(_ profile: Profile) {
        profile.isEnabled.toggle()
        profile.updatedAt = Date()
        save()
        fetchProfiles()
    }

    func forcedRuleMatch(for profile: Profile) -> RuleMatchResult {
        RuleMatchResult(
            profile: profile,
            kind: .manualOverride,
            matchedDomain: nil,
            competingProfileCount: 0,
            wonByPriority: false
        )
    }

    func matchRule(bundleIdentifier: String?, url: String? = nil) -> RuleMatchResult? {
        let bundleId = bundleIdentifier ?? ""
        let domain = extractDomain(from: url)
        let enabled = profiles.filter { $0.isEnabled }

        if !bundleId.isEmpty, let domain {
            let matches = enabled.filter { profile in
                profile.bundleIdentifiers.contains(bundleId) &&
                profile.urlPatterns.contains { domainMatches(domain, pattern: $0) }
            }
            if let result = bestMatch(from: matches, kind: .appAndWebsite, matchedDomain: domain) {
                return result
            }
        }

        if let domain {
            let matches = enabled.filter { profile in
                !profile.urlPatterns.isEmpty &&
                profile.urlPatterns.contains { domainMatches(domain, pattern: $0) }
            }
            if let result = bestMatch(from: matches, kind: .websiteOnly, matchedDomain: domain) {
                return result
            }
        }

        if !bundleId.isEmpty {
            let matches = enabled.filter { $0.bundleIdentifiers.contains(bundleId) }
            if let result = bestMatch(from: matches, kind: .appOnly, matchedDomain: nil) {
                return result
            }
        }

        let fallbackMatches = enabled.filter {
            $0.bundleIdentifiers.isEmpty && $0.urlPatterns.isEmpty
        }
        if let result = bestMatch(from: fallbackMatches, kind: .globalFallback, matchedDomain: nil) {
            return result
        }

        return nil
    }

    func matchProfile(bundleIdentifier: String?, url: String? = nil) -> Profile? {
        matchRule(bundleIdentifier: bundleIdentifier, url: url)?.profile
    }

    /// Extracts a clean domain from a URL string, stripping "www." prefix.
    private func extractDomain(from urlString: String?) -> String? {
        guard let urlString, !urlString.isEmpty,
              let url = URL(string: urlString),
              let host = url.host() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// Checks if a domain matches a pattern. Supports exact match and subdomain match.
    /// e.g. pattern "google.com" matches "google.com" and "docs.google.com"
    private func domainMatches(_ domain: String, pattern: String) -> Bool {
        let d = domain.lowercased()
        let p = pattern.lowercased()
        return d == p || d.hasSuffix("." + p)
    }

    private func bestMatch(from matches: [Profile], kind: RuleMatchKind, matchedDomain: String?) -> RuleMatchResult? {
        let sorted = matches.sorted {
            if $0.priority != $1.priority {
                return $0.priority > $1.priority
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        guard let best = sorted.first else { return nil }
        let secondPriority = sorted.dropFirst().first?.priority

        return RuleMatchResult(
            profile: best,
            kind: kind,
            matchedDomain: matchedDomain,
            competingProfileCount: max(sorted.count - 1, 0),
            wonByPriority: secondPriority.map { best.priority > $0 } ?? false
        )
    }

    private func fetchProfiles() {
        guard let modelContext else {
            profiles = []
            return
        }
        let descriptor = FetchDescriptor<Profile>(
            sortBy: [SortDescriptor(\.priority, order: .reverse), SortDescriptor(\.name)]
        )
        do {
            profiles = try modelContext.fetch(descriptor)
        } catch {
            logger.error("Fetch failed: \(error.localizedDescription)")
            profiles = []
        }
    }

    private func save() {
        do {
            try modelContext?.save()
        } catch {
            // Roll back so the uncommitted change is not flushed later by an
            // unrelated successful save; fetchProfiles() (run by every caller)
            // re-syncs the published list with what is actually persisted.
            modelContext?.rollback()
            logger.error("Save failed: \(error.localizedDescription)")
        }
    }
}
