import XCTest
@testable import Leise

final class AppFormatterServiceTests: XCTestCase {
    func testBundledReleaseChannelUsesInfoDictionaryValue() {
        let channel = AppConstants.bundledReleaseChannel(
            infoDictionary: ["LeiseReleaseChannel": AppConstants.ReleaseChannel.releaseCandidate.rawValue]
        )

        XCTAssertEqual(channel, .releaseCandidate)
    }

    func testSelectedUpdateChannelUsesStoredOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set(AppConstants.ReleaseChannel.daily.rawValue, forKey: UserDefaultsKeys.updateChannel)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let channel = AppConstants.selectedUpdateChannel(
            defaults: defaults,
            infoDictionary: ["LeiseReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue]
        )

        XCTAssertEqual(channel, .daily)
    }

    func testSelectedUpdateChannelIgnoresInvalidStoredOverride() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defaults.set("beta", forKey: UserDefaultsKeys.updateChannel)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let channel = AppConstants.selectedUpdateChannel(
            defaults: defaults,
            infoDictionary: ["LeiseReleaseChannel": AppConstants.ReleaseChannel.stable.rawValue]
        )

        XCTAssertEqual(channel, .stable)
    }

    @MainActor
    func testMarkdownFormattingNormalizesBullets() {
        let service = AppFormatterService()

        let output = service.format(
            text: "bullet first item\n* second item",
            bundleId: "md.obsidian",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "- first item\n- second item")
    }

    @MainActor
    func testMailAutoFormattingLeavesTextForRichTextClipboardConversion() {
        let service = AppFormatterService()

        let output = service.format(
            text: "hello <team>\n- launch",
            bundleId: "com.apple.mail",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "hello <team>\n- launch")
    }

    @MainActor
    func testBrowserAutoFormattingUsesURLDomainForGoogleMail() {
        let service = AppFormatterService()

        let output = service.format(
            text: "hello <team>\n- launch",
            bundleId: "com.google.Chrome",
            url: "https://mail.google.com/mail/u/0/#inbox",
            outputFormat: "auto"
        )

        XCTAssertEqual(output, "hello <team>\n- launch")
    }

    @MainActor
    func testRTFFormattingLeavesMarkdownTextForClipboardConversion() {
        let service = AppFormatterService()

        let output = service.format(
            text: "**Launch**\n- Budget",
            bundleId: "com.apple.mail",
            outputFormat: "rtf"
        )

        XCTAssertEqual(output, "**Launch**\n- Budget")
    }

    func testAutoFormatResolverMapsRichTextAndBrowserTargets() {
        XCTAssertEqual(
            AppOutputFormatResolver.resolvedFormat(
                storedFormat: "auto",
                bundleIdentifier: "com.microsoft.Word"
            ),
            "rtf"
        )
        XCTAssertEqual(
            AppOutputFormatResolver.resolvedFormat(
                storedFormat: "auto",
                bundleIdentifier: "com.google.Chrome",
                url: "https://docs.google.com/document/d/abc/edit"
            ),
            "rtf"
        )
        XCTAssertEqual(
            AppOutputFormatResolver.resolvedFormat(
                storedFormat: "auto",
                bundleIdentifier: "com.google.Chrome",
                url: "https://github.com/Leise/leise-mac"
            ),
            "plaintext"
        )
        XCTAssertNil(
            AppOutputFormatResolver.resolvedFormat(
                storedFormat: nil,
                bundleIdentifier: "com.microsoft.Word"
            )
        )
    }

    @MainActor
    func testRegisterDefaultUserDefaultsIncludesAppFormattingFlag() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        AppDelegate.registerDefaultUserDefaults(defaults)

        XCTAssertEqual(defaults.object(forKey: UserDefaultsKeys.appFormattingEnabled) as? Bool, true)
        XCTAssertEqual(defaults.object(forKey: UserDefaultsKeys.transcriptionNumberNormalizationEnabled) as? Bool, true)
    }
}
