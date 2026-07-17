import Foundation
import os

PerformanceMilestones.processStarted()

#if DEBUG
PerformanceBaselineRunner.prepareDefaultsIfRequested()
#endif

// Override Bundle.main's localization to support in-app language switching.
// This must happen before LeiseApp.main() so that all String(localized:)
// calls resolve using the user's preferred language, not the system language.

private class OverrideBundle: Bundle, @unchecked Sendable {
    // The .lproj sub-bundles never change during a run; resolving them once
    // avoids a filesystem path lookup on every localized-string access.
    private static let bundleCache = OSAllocatedUnfairLock(initialState: [String: Bundle?]())

    private static func bundle(forLanguage candidate: String) -> Bundle? {
        if let cached = bundleCache.withLock({ $0[candidate] }) {
            return cached
        }
        let resolved = Bundle.main.path(forResource: candidate, ofType: "lproj")
            .flatMap { Bundle(path: $0) }
        bundleCache.withLock { $0[candidate] = resolved }
        return resolved
    }

    override func localizedString(forKey key: String, value: String?, table tableName: String?) -> String {
        guard let lang = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage) else {
            return super.localizedString(forKey: key, value: value, table: tableName)
        }

        // Try language-specific .lproj first, then fall back to Base.lproj
        // (English is the source language and may live in Base.lproj or directly in Resources)
        let candidates = [lang, "Base"]
        for candidate in candidates {
            if let bundle = Self.bundle(forLanguage: candidate) {
                let result = bundle.localizedString(forKey: key, value: value, table: tableName)
                // If the bundle returned the key itself, the string wasn't found — try next
                if result != key { return result }
            }
        }

        // If the preferred language is the source language (English), return the key
        // as-is since it IS the English string for String(localized:).
        if lang == "en" {
            return value ?? key
        }

        return super.localizedString(forKey: key, value: value, table: tableName)
    }
}

object_setClass(Bundle.main, OverrideBundle.self)

LeiseApp.main()
