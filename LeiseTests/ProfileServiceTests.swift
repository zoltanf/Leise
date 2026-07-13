import XCTest
@testable import Leise

final class ProfileServiceTests: XCTestCase {
    @MainActor
    func testProfileMatchingPrefersBundleAndURLSpecificity() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = ProfileService(appSupportDirectory: directory)

        service.addProfile(name: "Bundle Only", bundleIdentifiers: ["com.apple.Safari"], priority: 5)
        service.addProfile(name: "URL Only", urlPatterns: ["docs.github.com"], priority: 10)
        service.addProfile(
            name: "Bundle + URL",
            bundleIdentifiers: ["com.apple.Safari"],
            urlPatterns: ["github.com"],
            priority: 1
        )

        let first = service.matchProfile(
            bundleIdentifier: "com.apple.Safari",
            url: "https://docs.github.com/en/get-started"
        )
        XCTAssertEqual(first?.name, "Bundle + URL")
        service.toggleProfile(try XCTUnwrap(first))
        XCTAssertEqual(
            service.matchProfile(
                bundleIdentifier: "com.apple.Safari",
                url: "https://docs.github.com/en/get-started"
            )?.name,
            "URL Only"
        )
    }

    @MainActor
    func testRuleMatchDetailsExplainPriorityWinsWithinSameTier() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = ProfileService(appSupportDirectory: directory)
        service.addProfile(name: "Docs Low", urlPatterns: ["docs.github.com"], priority: 1)
        service.addProfile(name: "Docs High", urlPatterns: ["docs.github.com"], priority: 9)

        let match = service.matchRule(
            bundleIdentifier: "com.apple.Safari",
            url: "https://docs.github.com/en/get-started"
        )
        XCTAssertEqual(match?.profile.name, "Docs High")
        XCTAssertEqual(match?.kind, .websiteOnly)
        XCTAssertTrue(match?.wonByPriority == true)
        XCTAssertEqual(match?.matchedDomain, "docs.github.com")
        XCTAssertEqual(match?.competingProfileCount, 1)
    }

    @MainActor
    func testRuleMatchingFallsBackToGlobalProfileWhenNothingSpecificMatches() throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(directory) }
        let service = ProfileService(appSupportDirectory: directory)
        service.addProfile(name: "Fallback Low", priority: 1)
        service.addProfile(name: "Fallback High", priority: 8)
        service.addProfile(name: "Safari Only", bundleIdentifiers: ["com.apple.Safari"], priority: 20)

        let fallback = service.matchRule(
            bundleIdentifier: "com.example.OtherApp",
            url: "https://example.com"
        )
        XCTAssertEqual(fallback?.profile.name, "Fallback High")
        XCTAssertEqual(fallback?.kind, .globalFallback)
        XCTAssertTrue(fallback?.wonByPriority == true)

        let specific = service.matchRule(
            bundleIdentifier: "com.apple.Safari",
            url: "https://example.com"
        )
        XCTAssertEqual(specific?.profile.name, "Safari Only")
        XCTAssertEqual(specific?.kind, .appOnly)
    }
}
