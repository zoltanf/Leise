import Combine
import Foundation

struct SettingsNavigationRequest: Identifiable, Equatable {
    let id = UUID()
    let tab: SettingsTab
}

@MainActor
final class SettingsNavigationCoordinator: ObservableObject {
    static let shared = SettingsNavigationCoordinator()

    @Published private(set) var request: SettingsNavigationRequest?

    func navigate(to tab: SettingsTab) {
        request = SettingsNavigationRequest(tab: tab)
    }
}
