import Foundation
import os

final class PunctuationRulesLoader: Sendable {
    private let bundle: Bundle
    private let dataLoader: (@Sendable (String) -> Data?)?
    // One loader instance is shared between main-actor and non-isolated
    // consumers, so the cache must be lock-protected.
    private let cache = OSAllocatedUnfairLock<[String: PunctuationRuleSet]>(initialState: [:])

    init(bundle: Bundle = .main, dataLoader: (@Sendable (String) -> Data?)? = nil) {
        self.bundle = bundle
        self.dataLoader = dataLoader
    }

    func ruleSet(for languageCode: String?) -> PunctuationRuleSet? {
        guard let normalizedLanguage = PunctuationLanguageNormalizer.normalize(languageCode) else {
            return nil
        }

        if let cached = cache.withLock({ $0[normalizedLanguage] }) {
            return cached
        }

        guard let data = loadData(for: normalizedLanguage),
              let ruleSet = try? JSONDecoder().decode(PunctuationRuleSet.self, from: data) else {
            return nil
        }

        cache.withLock { $0[normalizedLanguage] = ruleSet }
        return ruleSet
    }

    private func loadData(for languageCode: String) -> Data? {
        if let dataLoader {
            return dataLoader(languageCode)
        }

        guard let url = bundle.url(forResource: languageCode, withExtension: "json") else {
            return nil
        }

        return try? Data(contentsOf: url)
    }
}
