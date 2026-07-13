import Foundation
import LeiseCore
import os.log

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Leise", category: "PostProcessingPipeline")

struct PostProcessingResult {
    let text: String
    let appliedSteps: [String]
}

@MainActor
final class PostProcessingPipeline {
    private let dictionaryService: DictionaryService
    private let appFormatterService: AppFormatterService?
    private let speechPunctuationService: SpeechPunctuationService
    private let punctuationStrategyResolver: PunctuationStrategyResolver
    private let postProcessors: [any TextPostProcessor]

    init(
        dictionaryService: DictionaryService,
        appFormatterService: AppFormatterService? = nil,
        speechPunctuationService: SpeechPunctuationService = SpeechPunctuationService(),
        punctuationStrategyResolver: PunctuationStrategyResolver,
        postProcessors: [any TextPostProcessor] = []
    ) {
        self.dictionaryService = dictionaryService
        self.appFormatterService = appFormatterService
        self.speechPunctuationService = speechPunctuationService
        self.punctuationStrategyResolver = punctuationStrategyResolver
        self.postProcessors = postProcessors
    }

    func process(
        text: String,
        context: PostProcessingContext,
        dictationContext: DictationRuntimeContext? = nil,
        outputFormat: String? = nil,
        normalizeNumbers: Bool? = nil
    ) async throws -> PostProcessingResult {
        let processors = postProcessors

        // Build priority-ordered step list: (priority, id)
        // IDs: -3 = dictionary, -4 = app formatter, -5 = punctuation, -6 = normalization, 0+ = processor index
        var steps: [(priority: Int, id: Int)] = []

        steps.append((100, -6))

        // App formatter at priority 150.
        let formattingEnabled = UserDefaults.standard.bool(forKey: UserDefaultsKeys.appFormattingEnabled)
        if formattingEnabled, outputFormat != nil, appFormatterService != nil {
            steps.append((150, -4))
        }

        steps.append((200, -5))

        for (index, processor) in processors.enumerated() {
            steps.append((processor.priority, index))
        }
        steps.append((600, -3))
        steps.sort { $0.priority < $1.priority }

        var result = text
        var appliedSteps: [String] = []

        func stepName(for id: Int) -> String {
            switch id {
            case -6: return "Number Normalization"
            case -4: return "Formatting"
            case -5: return "Speech Punctuation"
            case -3: return "Corrections"
            default: return processors[id].displayName
            }
        }

        for step in steps {
            let before = result
            let name = stepName(for: step.id)
            let stepStart = ContinuousClock.now
            do {
                switch step.id {
                case -6:
                    let languages = TranscriptionNormalizationService.normalizationLanguages(
                        task: .transcribe,
                        detectedLanguage: dictationContext?.detectedLanguage ?? context.language,
                        configuredLanguage: dictationContext?.configuredLanguage ?? context.language,
                        configuredLanguageCandidates: dictationContext?.configuredLanguageCandidates ?? []
                    )
                    result = TranscriptionNormalizationService.normalizeText(
                        result,
                        languages: languages,
                        normalizeNumbers: normalizeNumbers
                    )
                case -4:
                    result = appFormatterService!.format(
                        text: result,
                        bundleId: context.bundleIdentifier,
                        url: context.url,
                        outputFormat: outputFormat
                    )
                case -5:
                    if let resolvedStrategy = punctuationStrategyResolver.resolve(
                        engineId: dictationContext?.engineId,
                        modelId: dictationContext?.modelId,
                        configuredLanguage: dictationContext?.configuredLanguage,
                        detectedLanguage: dictationContext?.detectedLanguage ?? context.language
                    ) {
                        switch resolvedStrategy.strategy {
                        case .nativeOnly:
                            break
                        case .automatic:
                            result = speechPunctuationService.normalize(
                                text: result,
                                language: resolvedStrategy.languageCode,
                                mode: .selectiveFallback
                            )
                        case .fallbackOnly:
                            result = speechPunctuationService.normalize(
                                text: result,
                                language: resolvedStrategy.languageCode,
                                mode: .fullFallback
                            )
                        }
                    }
                case -3:
                    result = dictionaryService.applyCorrections(to: result)
                default:
                    result = try await processors[step.id].process(result, context: context)
                }
                let changed = result != before
                logger.info("Post-processing step '\(name)' finished in \(ContinuousClock.now - stepStart), changed: \(changed)")
                if changed {
                    appliedSteps.append(name)
                }
            } catch {
                logger.error("Post-processing step '\(name)' failed after \(ContinuousClock.now - stepStart): \(error.localizedDescription)")
            }
        }

        return PostProcessingResult(text: result, appliedSteps: appliedSteps)
    }
}
