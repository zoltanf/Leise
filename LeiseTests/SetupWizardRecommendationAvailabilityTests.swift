import XCTest
import LeiseCore
@testable import Leise

final class SetupWizardRecommendationAvailabilityTests: XCTestCase {
    func testEngineSelectionKeepsReadySelectedEngine() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: "parakeet",
            selectedEngineReady: true,
            parakeetReady: true
        )

        XCTAssertEqual(providerId, "parakeet")
    }

    func testEngineSelectionChoosesParakeetWhenReady() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: nil,
            selectedEngineReady: false,
            parakeetReady: true
        )

        XCTAssertEqual(providerId, SetupWizardParakeetRecommendation.providerId)
    }

    func testEngineSelectionReturnsNilWhenParakeetIsUnavailable() {
        let providerId = SetupWizardEngineSelection.preferredProviderId(
            selectedProviderId: nil,
            selectedEngineReady: false,
            parakeetReady: false
        )

        XCTAssertNil(providerId)
    }


    func testParakeetRecommendationPrefersV2Model() {
        let modelId = SetupWizardParakeetRecommendation.preferredModelId(
            from: [
                TranscriptionModel(id: "parakeet-tdt-0.6b-v2", displayName: "Parakeet TDT v2"),
                TranscriptionModel(id: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT v3")
            ]
        )

        XCTAssertEqual(modelId, "parakeet-tdt-0.6b-v2")
    }

    func testEngineIsNotReadyUntilSelectedModelIsLoaded() {
        XCTAssertFalse(
            SetupWizardEngineReadiness.isReady(
                canUseForTranscription: true,
                isConfigured: false
            )
        )
    }

    func testConfiguredUsableEngineIsReady() {
        XCTAssertTrue(
            SetupWizardEngineReadiness.isReady(
                canUseForTranscription: true,
                isConfigured: true
            )
        )
    }

    func testLoadedParakeetModelIsRecognizedAsLoaded() {
        XCTAssertTrue(
            SetupWizardParakeetModelSelection.isLoaded(
                requestedModelId: "parakeet-v3",
                loadedModelId: "parakeet-v3",
                isConfigured: true
            )
        )
    }

    func testDifferentParakeetModelRemainsDownloadable() {
        XCTAssertFalse(
            SetupWizardParakeetModelSelection.isLoaded(
                requestedModelId: "parakeet-v2",
                loadedModelId: "parakeet-v3",
                isConfigured: true
            )
        )
    }

    func testHybridShowsRecorderWhenSelectedWithoutARecordedHotkey() {
        XCTAssertTrue(
            SetupWizardHotkeyRecorderVisibility.shouldShow(
                mode: .hybrid,
                selectedMode: .hybrid,
                hasRecordedHotkey: false
            )
        )
    }

    func testHybridHidesRecorderAfterAHotkeyIsRecorded() {
        XCTAssertFalse(
            SetupWizardHotkeyRecorderVisibility.shouldShow(
                mode: .hybrid,
                selectedMode: .hybrid,
                hasRecordedHotkey: true
            )
        )
    }

    func testRecommendedHybridFnCanBeAppliedWhenTriggerSlotsAreEmpty() {
        let state = SetupWizardDefaultHotkey.resolve(
            existingTriggerHotkeys: [:],
            conflictingSlot: nil
        )

        XCTAssertEqual(
            state,
            SetupWizardDefaultHotkey.Resolution(shouldApply: true, blockedReason: nil)
        )
        XCTAssertEqual(
            SetupWizardDefaultHotkey.recommendedHybridHotkey,
            UnifiedHotkey(keyCode: 0, modifierFlags: 0, isFn: true)
        )
    }

    func testRecommendedHybridFnDoesNotOverrideExistingTriggerHotkey() {
        let state = SetupWizardDefaultHotkey.resolve(
            existingTriggerHotkeys: [
                .pushToTalk: [UnifiedHotkey(keyCode: 0x69, modifierFlags: 0, isFn: false)]
            ],
            conflictingSlot: nil
        )

        XCTAssertEqual(
            state,
            SetupWizardDefaultHotkey.Resolution(
                shouldApply: false,
                blockedReason: .existingTriggerHotkey
            )
        )
    }

    func testRecommendedHybridFnDoesNotOverrideConflictingSlot() {
        let state = SetupWizardDefaultHotkey.resolve(
            existingTriggerHotkeys: [:],
            conflictingSlot: .recentTranscriptions
        )

        XCTAssertEqual(
            state,
            SetupWizardDefaultHotkey.Resolution(
                shouldApply: false,
                blockedReason: .conflictingSlot(.recentTranscriptions)
            )
        )
    }

    func testParakeetOnIntelIsUnavailableImmediately() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.leise.parakeet",
            isInstalled: false,
            isReady: false,
            architecture: "x86_64"
        )

        XCTAssertEqual(state, .unavailable(.appleSiliconOnly))
    }

    func testMissingBuiltInParakeetIsUnavailable() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.leise.parakeet",
            isInstalled: false,
            isReady: false,
            architecture: "arm64"
        )

        XCTAssertEqual(state, .unavailable(.builtInUnavailable))
    }

    func testReadyStateTakesPrecedenceForCompatibleArchitecture() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.leise.parakeet",
            isInstalled: true,
            isReady: true,
            architecture: "arm64"
        )

        XCTAssertEqual(state, .ready)
    }

    func testInstalledStateTakesPrecedenceForCompatibleArchitecture() {
        let state = SetupWizardRecommendationAvailability.resolve(
            manifestId: "com.leise.parakeet",
            isInstalled: true,
            isReady: false,
            architecture: "arm64"
        )

        XCTAssertEqual(state, .setupRequired)
    }

}
