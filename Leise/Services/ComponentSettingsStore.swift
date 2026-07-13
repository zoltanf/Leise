import Foundation
import FillerWordCleanup
import ParakeetEngine

final class ComponentSettingsStore: ParakeetStore, FillerWordCleanupStore, @unchecked Sendable {
    let namespace: String

    init(namespace: String) {
        self.namespace = namespace
    }

    func storeSecret(key: String, value: String) throws {
        let service = "com.leise.\(namespace).\(key)"
        if value.isEmpty {
            try KeychainService.delete(service: service)
        } else {
            try KeychainService.save(key: value, service: service)
        }
    }

    func loadSecret(key: String) -> String? {
        KeychainService.load(service: "com.leise.\(namespace).\(key)")
    }

    func userDefault(forKey key: String) -> Any? {
        return UserDefaults.standard.object(forKey: "component.\(namespace).\(key)")
    }

    func setUserDefault(_ value: Any?, forKey key: String) {
        UserDefaults.standard.set(value, forKey: "component.\(namespace).\(key)")
    }

    var shouldRestoreLoadedModelsPassively: Bool {
        ModelAutoUnloadPolicy.shouldRestoreLoadedModelsPassively()
    }
}
