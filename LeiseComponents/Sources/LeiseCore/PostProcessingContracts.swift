import Foundation

public struct PostProcessingContext: Equatable, Sendable {
    public let bundleIdentifier: String?
    public let url: String?
    public let language: String?

    public init(bundleIdentifier: String? = nil, url: String? = nil, language: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.language = language
    }
}

@MainActor
public protocol TextPostProcessor: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }
    var priority: Int { get }
    func process(_ text: String, context: PostProcessingContext) async throws -> String
}
