import Foundation

/// The CPU architecture the process runs on, overridable for tests.
public enum RuntimeArchitecture {
    nonisolated(unsafe) public static var overrideCurrent: String?

    public static var current: String {
        if let overrideCurrent { return overrideCurrent }
#if arch(arm64)
        return "arm64"
#elseif arch(x86_64)
        return "x86_64"
#else
        return "unknown"
#endif
    }
}

// MARK: - Engine setup decision helpers
//
// These are engine-capability decisions consumed by the setup wizard. They
// live next to the `TranscriptionEngine` contract so they can be evolved and
// unit-tested with the engines rather than with the app's view code.

public enum SetupWizardEngineReadiness {
    public static func isReady(canUseForTranscription: Bool, isConfigured: Bool) -> Bool {
        canUseForTranscription && isConfigured
    }
}

public enum SetupWizardParakeetModelSelection {
    public static func isLoaded(
        requestedModelId: String,
        loadedModelId: String?,
        isConfigured: Bool
    ) -> Bool {
        isConfigured && requestedModelId == loadedModelId
    }
}

/// Identity and model-selection facts about the built-in Parakeet engine.
/// User-facing copy for these values lives in the app layer.
public enum SetupWizardParakeetRecommendation {
    public static let providerId = "parakeet"
    public static let manifestId = "com.leise.parakeet"
    public static let v2ModelId = "parakeet-tdt-0.6b-v2"
    public static let v3ModelId = "parakeet-tdt-0.6b-v3"

    public static func preferredModelId(from models: [TranscriptionModel]) -> String? {
        models.first { $0.id == v2ModelId }?.id
            ?? models.first { $0.id.localizedCaseInsensitiveContains("v2") }?.id
            ?? models.first?.id
    }
}

public enum SetupWizardRecommendationUnavailableReason: Equatable, Sendable {
    case appleSiliconOnly
    case builtInUnavailable
}

public enum SetupWizardRecommendationAvailability: Equatable, Sendable {
    case ready
    case setupRequired
    case unavailable(SetupWizardRecommendationUnavailableReason)

    public static func resolve(
        manifestId: String,
        isInstalled: Bool,
        isReady: Bool,
        hasBundledModels: Bool = false,
        architecture: String = RuntimeArchitecture.current
    ) -> SetupWizardRecommendationAvailability {
        if manifestId == SetupWizardParakeetRecommendation.manifestId, architecture != "arm64" {
            return .unavailable(.appleSiliconOnly)
        }

        if isReady || hasBundledModels {
            return .ready
        }

        if isInstalled {
            return .setupRequired
        }

        return .unavailable(.builtInUnavailable)
    }
}
