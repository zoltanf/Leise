import XCTest
import LeiseCore
@testable import Leise

final class DictionaryServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPackStates)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedIndustryPreset)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.activatedTermPackStates)
        UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.selectedIndustryPreset)
        super.tearDown()
    }

    @MainActor
    func testDictionaryTermsCorrectionsAndLearning() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)

        service.addEntry(type: .term, original: "Leise")
        service.addEntry(type: .term, original: "leise")
        service.addEntry(type: .correction, original: "teh", replacement: "the")

        XCTAssertEqual(service.termsCount, 1)
        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.getTermsForPrompt(providerId: nil), "Leise")

        let corrected = service.applyCorrections(to: "teh Leise")
        XCTAssertEqual(corrected, "the Leise")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        service.learnCorrection(original: "langauge", replacement: "language")
        XCTAssertEqual(service.correctionsCount, 2)
    }

    @MainActor
    func testBatchLearningSkipsDuplicatesAndUndoDeletesOnlyMatchingCreatedEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "teh", replacement: "the")

        let learned = service.learnCorrections([
            CorrectionSuggestion(original: "teh", replacement: "the"),
            CorrectionSuggestion(original: "langauge", replacement: "language"),
            CorrectionSuggestion(original: "recieve", replacement: "receive"),
            CorrectionSuggestion(original: "recieve", replacement: "receipt")
        ])

        XCTAssertEqual(learned.count, 2)
        XCTAssertEqual(learned.map(\.original), ["langauge", "recieve"])
        XCTAssertEqual(service.correctionsCount, 3)
        XCTAssertEqual(
            service.corrections.filter { $0.source == .autoLearned }.map(\.original),
            ["langauge", "recieve"]
        )

        let protectedEntry = try XCTUnwrap(service.corrections.first { $0.original == "langauge" })
        service.updateEntry(
            protectedEntry,
            original: protectedEntry.original,
            replacement: "languages",
            caseSensitive: protectedEntry.caseSensitive
        )

        service.undoLearnedCorrections(learned)

        XCTAssertEqual(service.correctionsCount, 2)
        XCTAssertTrue(service.corrections.contains { $0.original == "teh" })
        XCTAssertTrue(service.corrections.contains { $0.original == "langauge" && $0.replacement == "languages" })
        XCTAssertFalse(service.corrections.contains { $0.original == "recieve" })
    }

    @MainActor
    func testEmptyCorrectionReplacementPersistsAndRemovesText() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "¿", replacement: "")

        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.corrections.first?.replacement, "")
        XCTAssertEqual(service.applyCorrections(to: "¿Como estas?"), "Como estas?")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        let reloadedService = DictionaryService(appSupportDirectory: appSupportDirectory)
        XCTAssertEqual(reloadedService.correctionsCount, 1)
        XCTAssertEqual(reloadedService.corrections.first?.replacement, "")
        XCTAssertEqual(reloadedService.applyCorrections(to: "¿Como estas?"), "Como estas?")
        reloadedService.loadEntries()
        XCTAssertEqual(reloadedService.corrections.first?.usageCount, 2)
    }

    @MainActor
    func testBatchLearningAllowsEmptyReplacementCorrections() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)

        let learned = service.learnCorrections([
            CorrectionSuggestion(original: "filler", replacement: "")
        ])

        XCTAssertEqual(learned.count, 1)
        XCTAssertEqual(learned.first?.original, "filler")
        XCTAssertEqual(learned.first?.replacement, "")
        XCTAssertEqual(service.applyCorrections(to: "drop filler text"), "drop text")
    }

    @MainActor
    func testWhitespaceBearingLatinFillerCorrectionsStillApplyAtWordBoundaries() throws {
        let plainDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(plainDirectory) }

        let plainService = DictionaryService(appSupportDirectory: plainDirectory)
        plainService.addEntry(type: .correction, original: "um", replacement: "")

        XCTAssertEqual(plainService.applyCorrections(to: "Um I think this works"), "I think this works")
        XCTAssertEqual(plainService.applyCorrections(to: "I said um today"), "I said today")

        let whitespaceDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(whitespaceDirectory) }

        let service = DictionaryService(appSupportDirectory: whitespaceDirectory)
        service.addEntry(type: .correction, original: "um ", replacement: "")
        service.addEntry(type: .correction, original: " huh", replacement: "")

        XCTAssertEqual(service.applyCorrections(to: "Um I think this works"), "I think this works")
        XCTAssertEqual(service.applyCorrections(to: "I said um today"), "I said today")
        XCTAssertEqual(service.applyCorrections(to: "this was huh"), "this was")
    }

    @MainActor
    func testWhitespaceBearingFillerCorrectionsKeepOneSeparatorBetweenWords() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: " um ", replacement: "")

        XCTAssertEqual(service.applyCorrections(to: "I said um today"), "I said today")
        XCTAssertEqual(service.applyCorrections(to: "I said, um today"), "I said, today")
    }

    @MainActor
    func testLatinCorrectionsMatchWholeWordsOnly() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "rake", replacement: "RAKE")
        service.addEntry(type: .correction, original: "um", replacement: "")
        service.addEntry(type: .correction, original: "um ", replacement: "")

        XCTAssertEqual(service.applyCorrections(to: "rake"), "RAKE")
        XCTAssertEqual(service.applyCorrections(to: "Rake"), "RAKE")
        XCTAssertEqual(service.applyCorrections(to: "brake rakes"), "brake rakes")
        XCTAssertEqual(service.applyCorrections(to: "Use rake, rake/brake, and (rake)."), "Use RAKE, RAKE/brake, and (RAKE).")
        XCTAssertEqual(service.applyCorrections(to: "umbrella stand"), "umbrella stand")
        XCTAssertEqual(service.applyCorrections(to: "album art"), "album art")
    }

    @MainActor
    func testCorrectionsDoNotReplaceInsideLongerKatakanaWords() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "ライン", replacement: "LINE")
        service.addEntry(type: .correction, original: "リフ", replacement: "LIFF")

        XCTAssertEqual(service.applyCorrections(to: "具体的にはオンライン。"), "具体的にはオンライン。")
        XCTAssertEqual(service.applyCorrections(to: "リファレンス。"), "リファレンス。")
        XCTAssertEqual(service.applyCorrections(to: "ラインで送って。"), "LINEで送って。")
    }

    @MainActor
    func testCorrectionsStillApplyForKnownJapaneseNameAndBrandTerms() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "恋ちゃん", replacement: "こいちゃん")
        service.addEntry(type: .correction, original: "鯉フィット", replacement: "Koi-Fit")

        XCTAssertEqual(service.applyCorrections(to: "恋ちゃんです。"), "こいちゃんです。")
        XCTAssertEqual(service.applyCorrections(to: "今日は恋ちゃんです。"), "今日はこいちゃんです。")
        XCTAssertEqual(service.applyCorrections(to: "鯉フィットの件です。"), "Koi-Fitの件です。")
        XCTAssertEqual(service.applyCorrections(to: "今日は鯉フィットの件です。"), "今日はKoi-Fitの件です。")
        XCTAssertEqual(service.applyCorrections(to: "鯉フィットネスではありません。"), "鯉フィットネスではありません。")
    }

    @MainActor
    func testCorrectionsDoNotFoldJapaneseDakutenDifferences() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "ハン", replacement: "HAN")

        XCTAssertEqual(service.applyCorrections(to: "ハンで始まる。"), "HANで始まる。")
        XCTAssertEqual(service.applyCorrections(to: "バンで始まる。"), "バンで始まる。")
    }

    @MainActor
    func testMixedJapaneseCorrectionsDoNotReplaceInsideCompoundWords() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "日本", replacement: "Japan")
        service.addEntry(type: .correction, original: "東京", replacement: "Tokyo")

        XCTAssertEqual(service.applyCorrections(to: "日本です。"), "Japanです。")
        XCTAssertEqual(service.applyCorrections(to: "これは日本です。"), "これはJapanです。")
        XCTAssertEqual(service.applyCorrections(to: "東京へ行く。"), "Tokyoへ行く。")
        XCTAssertEqual(service.applyCorrections(to: "明日は東京へ行く。"), "明日はTokyoへ行く。")
        XCTAssertEqual(service.applyCorrections(to: "日本から出発します。"), "Japanから出発します。")
        XCTAssertEqual(service.applyCorrections(to: "日本まで送ってください。"), "Japanまで送ってください。")
        XCTAssertEqual(service.applyCorrections(to: "日本語です。"), "日本語です。")
        XCTAssertEqual(service.applyCorrections(to: "東京都です。"), "東京都です。")
    }

    @MainActor
    func testShortJapaneseCorrectionsDoNotReplaceInsideWordsContainingParticles() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "だ", replacement: "です")

        XCTAssertEqual(service.applyCorrections(to: "からだです。"), "からだです。")
    }

    @MainActor
    func testSingleCharacterCorrectionsDoNotUseMultiCharacterParticleSuffixesInsideWords() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "ち", replacement: "地")

        XCTAssertEqual(service.applyCorrections(to: "ちからです。"), "ちからです。")
    }

    @MainActor
    func testAPITermHelpersDeleteSingleTermWithoutClearingOthers() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        try service.setAPITerms([" Leise ", "WhisperKit", "leise"], replaceExisting: true)

        XCTAssertTrue(try service.deleteAPITerm("leise"))
        XCTAssertEqual(service.enabledTerms(), ["WhisperKit"])
        XCTAssertFalse(try service.deleteAPITerm("Missing"))
    }

    @MainActor
    func testAPICorrectionHelpersUpsertCaseInsensitiveAndPreserveUsageCount() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        try service.upsertAPICorrection(original: "teh", replacement: "the", caseSensitive: false)
        XCTAssertEqual(service.applyCorrections(to: "teh"), "the")
        XCTAssertEqual(service.corrections.first?.usageCount, 1)

        try service.upsertAPICorrection(original: "TEH", replacement: "The", caseSensitive: true)

        XCTAssertEqual(service.correctionsCount, 1)
        XCTAssertEqual(service.corrections.first?.original, "TEH")
        XCTAssertEqual(service.corrections.first?.replacement, "The")
        XCTAssertEqual(service.corrections.first?.caseSensitive, true)
        XCTAssertEqual(service.corrections.first?.source, .manual)
        XCTAssertEqual(service.corrections.first?.usageCount, 1)
        XCTAssertTrue(try service.deleteAPICorrection(original: "teh"))
        XCTAssertEqual(service.correctionsCount, 0)
        XCTAssertFalse(try service.deleteAPICorrection(original: "missing"))
    }

    @MainActor
    func testEnabledTermsAreNormalizedAndPromptRendererStaysBackwardCompatible() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: " Kubernetes ", ctcMinSimilarity: 0.65)
        service.addEntry(type: .term, original: "MLX")
        service.addEntry(type: .term, original: "mlx")
        service.addEntry(type: .term, original: "Leise")

        XCTAssertEqual(service.enabledTerms(), ["Kubernetes", "Leise", "MLX"])
        XCTAssertEqual(service.enabledTermHints(), [
            DictionaryTermHint(text: "Kubernetes", ctcMinSimilarity: 0.65),
            DictionaryTermHint(text: "Leise", ctcMinSimilarity: nil),
            DictionaryTermHint(text: "MLX", ctcMinSimilarity: nil),
        ])
        XCTAssertEqual(
            service.getTermsForPrompt(providerId: nil),
            DictionaryTerms.prompt(from: ["Kubernetes", "Leise", "MLX"])
        )
    }

    @MainActor
    func testAPITermEntriesPersistThresholdsAndPlainTermsPreserveExistingValues() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        try service.setAPITermEntries(
            [
                (term: " Leise ", ctcMinSimilarity: 0.65),
                (term: "Reson8", ctcMinSimilarity: nil),
            ],
            replaceExisting: true
        )

        XCTAssertEqual(service.enabledTermHints(), [
            DictionaryTermHint(text: "Leise", ctcMinSimilarity: 0.65),
            DictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
        ])

        try service.setAPITerms(["leise", "Caivex"], replaceExisting: false)

        XCTAssertEqual(service.enabledTermHints(), [
            DictionaryTermHint(text: "Caivex", ctcMinSimilarity: nil),
            DictionaryTermHint(text: "leise", ctcMinSimilarity: 0.65),
            DictionaryTermHint(text: "Reson8", ctcMinSimilarity: nil),
        ])

        try service.setAPITermEntries(
            [(term: "Leise", ctcMinSimilarity: nil)],
            replaceExisting: true
        )

        XCTAssertEqual(service.enabledTermHints(), [
            DictionaryTermHint(text: "Leise", ctcMinSimilarity: nil),
        ])
    }

    @MainActor
    func testGetTermsForPromptFallsBackToLegacyBudgetForUnknownOrUnbudgetedEngines() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.setTerms(makeLongTerms(count: 40, length: 24), replaceExisting: true)

        let expectedFallback = DictionaryTerms.prompt(from: service.enabledTerms())
        XCTAssertEqual(service.getTermsForPrompt(providerId: nil), expectedFallback)
        XCTAssertEqual(service.getTermsForPrompt(providerId: "parakeet"), expectedFallback)
        XCTAssertEqual(service.getTermsForPrompt(providerId: "missing"), expectedFallback)
        XCTAssertLessThanOrEqual(expectedFallback?.count ?? 0, 600)
    }

    @MainActor
    func testDictionaryEntryRowsSnapshotLargeFilteredListsWithStableIDs() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let terms = (1...120).map {
            (
                type: DictionaryEntryType.term,
                original: String(format: "Term-%03d", $0),
                replacement: nil as String?,
                caseSensitive: true,
                ctcMinSimilarity: nil as Float?
            )
        }
        let corrections = (1...120).map {
            (
                type: DictionaryEntryType.correction,
                original: String(format: "Wrong-%03d", $0),
                replacement: String(format: "Correct-%03d", $0) as String?,
                caseSensitive: false,
                ctcMinSimilarity: nil as Float?
            )
        }
        service.addEntries(terms + corrections + [
            (
                type: DictionaryEntryType.correction,
                original: "empty-replacement",
                replacement: "" as String?,
                caseSensitive: true,
                ctcMinSimilarity: nil as Float?
            )
        ])

        let viewModel = DictionaryViewModel(dictionaryService: service)
        viewModel.filterTab = .corrections
        let correctionRows = viewModel.filteredEntryRows

        XCTAssertEqual(correctionRows.count, 121)
        XCTAssertTrue(correctionRows.allSatisfy { $0.type == .correction })
        XCTAssertEqual(correctionRows.first { $0.original == "empty-replacement" }?.replacementDisplayText, "\"\"")

        let correctionIDs = correctionRows.map(\.id)
        viewModel.filterTab = .all
        let allCorrectionIDs = viewModel.filteredEntryRows
            .filter { $0.type == .correction }
            .map(\.id)
        XCTAssertEqual(allCorrectionIDs, correctionIDs)

        service.learnCorrection(original: "autolearned", replacement: "auto learned")
        let refreshedViewModel = DictionaryViewModel(dictionaryService: service)
        refreshedViewModel.filterTab = .corrections
        XCTAssertTrue(refreshedViewModel.filteredEntryRows.contains { $0.original == "autolearned" })
    }

    @MainActor
    func testDictionaryEntryIDActionsEditSetEnabledToggleAndDeleteMatchingEntry() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .correction, original: "teh", replacement: "the", caseSensitive: true)
        let viewModel = DictionaryViewModel(dictionaryService: service)
        let row = try XCTUnwrap(viewModel.filteredEntryRows.first)

        viewModel.setEntryEnabled(id: row.id, enabled: false)
        XCTAssertFalse(try XCTUnwrap(service.entries.first { $0.id == row.id }).isEnabled)
        viewModel.setEntryEnabled(id: row.id, enabled: false)
        XCTAssertFalse(try XCTUnwrap(service.entries.first { $0.id == row.id }).isEnabled)
        viewModel.setEntryEnabled(id: row.id, enabled: true)
        XCTAssertTrue(try XCTUnwrap(service.entries.first { $0.id == row.id }).isEnabled)
        viewModel.toggleEntry(id: row.id)
        XCTAssertFalse(try XCTUnwrap(service.entries.first { $0.id == row.id }).isEnabled)

        viewModel.startEditingEntry(id: row.id)
        XCTAssertTrue(viewModel.isEditing)
        XCTAssertFalse(viewModel.isCreatingNew)
        XCTAssertEqual(viewModel.editType, .correction)
        XCTAssertEqual(viewModel.editOriginal, "teh")
        XCTAssertEqual(viewModel.editReplacement, "the")
        XCTAssertTrue(viewModel.editCaseSensitive)

        viewModel.deleteEntry(id: row.id)
        XCTAssertFalse(service.entries.contains { $0.id == row.id })
    }

    @MainActor
    func testTermPackActivationPreservesManualEntriesAndDeactivationRemovesOnlyPackEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        service.addEntry(type: .term, original: "Rust")

        let viewModel = DictionaryViewModel(dictionaryService: service)
        let pack = TermPack(
            id: "community-rust",
            name: "Rust Terms",
            description: "Rust ecosystem terms",
            icon: "shippingbox",
            terms: ["Rust", "Tokio"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )

        viewModel.activatePack(pack)

        XCTAssertEqual(service.entries.filter { $0.type == .term }.map(\.original).sorted(), ["Rust", "Tokio"])
        XCTAssertEqual(service.entries.first(where: { $0.original == "Rust" })?.caseSensitive, false)
        XCTAssertEqual(viewModel.activatedPackStates[pack.id]?.installedTerms, ["Tokio"])

        viewModel.deactivatePack(pack)

        XCTAssertEqual(service.entries.filter { $0.type == .term }.map(\.original), ["Rust"])
        XCTAssertFalse(viewModel.isPackActivated(pack))
    }

    @MainActor
    func testTermPackUpdateReplacesPreviousSnapshotEntries() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let viewModel = DictionaryViewModel(dictionaryService: service)

        let v1 = TermPack(
            id: "community-rust",
            name: "Rust Terms",
            description: "Rust ecosystem terms",
            icon: "shippingbox",
            terms: ["Tokio"],
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
        let v2 = TermPack(
            id: "community-rust",
            name: "Rust Terms",
            description: "Rust ecosystem terms",
            icon: "shippingbox",
            terms: ["Cargo"],
            corrections: [],
            version: "1.1.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )

        viewModel.activatePack(v1)
        viewModel.updatePack(v2)

        XCTAssertEqual(service.entries.filter { $0.type == .term }.map(\.original), ["Cargo"])
        XCTAssertEqual(viewModel.activatedPackStates[v2.id]?.installedTerms, ["Cargo"])
        XCTAssertEqual(viewModel.activatedPackStates[v2.id]?.installedVersion, "1.1.0")
    }

    @MainActor
    func testIndustryPacksAreAvailable() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let registry = TermPackRegistryService()
        registry.communityPacks = [
            makeIndustryPack(id: "real-estate", terms: ["Exposé"]),
            makeIndustryPack(id: "architecture", terms: ["HOAI"]),
            makeIndustryPack(id: "legal", terms: ["Mandat"])
        ]
        let viewModel = DictionaryViewModel(
            dictionaryService: service,
            termPackRegistryService: registry
        )

        XCTAssertEqual(Set(viewModel.visibleCommunityPacks.map(\.id)), ["real-estate", "architecture", "legal"])
    }

    @MainActor
    func testIndustryPresetActivatesMatchingPack() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let service = DictionaryService(appSupportDirectory: appSupportDirectory)
        let registry = TermPackRegistryService()
        let realEstatePack = makeIndustryPack(id: "real-estate", terms: ["Exposé", "Grundbuch"])
        registry.communityPacks = [realEstatePack]
        let viewModel = DictionaryViewModel(
            dictionaryService: service,
            termPackRegistryService: registry
        )

        viewModel.applyIndustryPreset(.realEstate)

        XCTAssertEqual(UserDefaults.standard.string(forKey: UserDefaultsKeys.selectedIndustryPreset), IndustryPreset.realEstate.rawValue)
        XCTAssertTrue(viewModel.isPackActivated(realEstatePack))
        XCTAssertTrue(service.entries.contains { $0.original == "Exposé" })
    }

    private func makeIndustryPack(id: String, terms: [String]) -> TermPack {
        TermPack(
            id: id,
            name: id,
            description: "Industry test pack",
            icon: "shippingbox",
            terms: terms,
            corrections: [],
            version: "1.0.0",
            author: "Tests",
            localizedNames: nil,
            localizedDescriptions: nil
        )
    }

    private func makeLongTerms(count: Int, length: Int) -> [String] {
        (1...count).map { index in
            let prefix = "Term\(index)-"
            let paddingLength = max(0, length - prefix.count)
            return prefix + String(repeating: "x", count: paddingLength)
        }
    }
}

final class UserDataBackupServiceTests: XCTestCase {
    @MainActor
    func testExportAndImportRoundTripsPreferencesDictionaryProfilesAndHistory() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let suiteName = "UserDataBackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let history = HistoryService(appSupportDirectory: appSupportDirectory)
        let dictionary = DictionaryService(appSupportDirectory: appSupportDirectory)
        let profiles = ProfileService(appSupportDirectory: appSupportDirectory)
        let usage = UsageStatisticsService(appSupportDirectory: appSupportDirectory)
        let service = UserDataBackupService(
            defaults: defaults,
            defaultsDomain: suiteName,
            historyService: history,
            dictionaryService: dictionary,
            profileService: profiles,
            usageStatisticsService: usage
        )

        defaults.set(true, forKey: "boolSetting")
        defaults.set(42, forKey: "integerSetting")
        defaults.set(2.5, forKey: "doubleSetting")
        defaults.set("parakeet", forKey: "stringSetting")
        defaults.set(Data([0x01, 0x02, 0x03]), forKey: "dataSetting")
        defaults.set(["one", "two"], forKey: "arraySetting")
        defaults.set(["enabled": true], forKey: "dictionarySetting")

        dictionary.addEntry(
            type: .correction,
            original: "teh",
            replacement: "the",
            caseSensitive: true,
            source: .autoLearned
        )
        profiles.addProfile(
            name: "Writing",
            bundleIdentifiers: ["com.apple.TextEdit"],
            inputLanguage: "en",
            autoEnterEnabled: true,
            priority: 7
        )
        history.addRecord(
            rawText: "test one",
            finalText: "Test one.",
            appName: "TextEdit",
            appBundleIdentifier: "com.apple.TextEdit",
            durationSeconds: 1.25,
            language: "en",
            engineUsed: "parakeet",
            modelUsed: "tdt-v3",
            pipelineSteps: ["punctuation"]
        )
        let historyRecord = try XCTUnwrap(history.records.first)
        history.updateRecord(
            historyRecord,
            finalText: "Test two.",
            isManualEdit: true,
            changedWordCount: 1
        )

        let originalDictionaryID = try XCTUnwrap(dictionary.entries.first?.id)
        let originalProfileID = try XCTUnwrap(profiles.profiles.first?.id)
        let originalHistoryID = try XCTUnwrap(history.records.first?.id)
        let backupURL = appSupportDirectory.appendingPathComponent("backup.json")

        let exported = try service.exportBackup(to: backupURL)
        XCTAssertEqual(exported.dictionaryEntryCount, 1)
        XCTAssertEqual(exported.profileCount, 1)
        XCTAssertEqual(exported.historyRecordCount, 1)

        defaults.set(false, forKey: "boolSetting")
        defaults.set("temporary", forKey: "temporarySetting")
        dictionary.addEntry(type: .term, original: "Temporary")
        profiles.addProfile(name: "Temporary")
        history.addRecord(
            rawText: "temporary",
            finalText: "Temporary.",
            appName: nil,
            appBundleIdentifier: nil,
            durationSeconds: 0.5,
            language: nil,
            engineUsed: "test"
        )

        let imported = try service.importBackup(from: backupURL)

        XCTAssertEqual(imported, exported)
        XCTAssertEqual(defaults.bool(forKey: "boolSetting"), true)
        XCTAssertEqual(defaults.integer(forKey: "integerSetting"), 42)
        XCTAssertEqual(defaults.double(forKey: "doubleSetting"), 2.5)
        XCTAssertEqual(defaults.string(forKey: "stringSetting"), "parakeet")
        XCTAssertEqual(defaults.data(forKey: "dataSetting"), Data([0x01, 0x02, 0x03]))
        XCTAssertNil(defaults.object(forKey: "temporarySetting"))

        XCTAssertEqual(dictionary.entries.count, 1)
        XCTAssertEqual(dictionary.entries.first?.id, originalDictionaryID)
        XCTAssertEqual(dictionary.entries.first?.source, .autoLearned)
        XCTAssertEqual(profiles.profiles.count, 1)
        XCTAssertEqual(profiles.profiles.first?.id, originalProfileID)
        XCTAssertEqual(profiles.profiles.first?.priority, 7)
        XCTAssertEqual(history.records.count, 1)
        XCTAssertEqual(history.records.first?.id, originalHistoryID)
        XCTAssertEqual(history.records.first?.pipelineStepList, ["punctuation"])
        XCTAssertEqual(history.records.first?.initialFinalText, "Test one.")
        XCTAssertEqual(history.records.first?.finalText, "Test two.")
        XCTAssertEqual(history.records.first?.manualEditCount, 1)
        XCTAssertEqual(history.records.first?.manualChangedWordCount, 1)
        XCTAssertNotNil(history.records.first?.lastManuallyEditedAt)

        let statistics = usage.summary(from: nil)
        XCTAssertEqual(statistics.transcriptionCount, 1)
        XCTAssertEqual(statistics.words, history.records.first?.wordsCount)
        XCTAssertEqual(statistics.manualCorrectionCount, 1)
        XCTAssertEqual(statistics.correctionUsage.values.first?.original, "one")
        XCTAssertEqual(statistics.correctionUsage.values.first?.replacement, "two")
    }

    @MainActor
    func testInspectRejectsNonLeiseJSONBeforeMutatingData() throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let suiteName = "UserDataBackupServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = UserDataBackupService(
            defaults: defaults,
            defaultsDomain: suiteName,
            historyService: HistoryService(appSupportDirectory: appSupportDirectory),
            dictionaryService: DictionaryService(appSupportDirectory: appSupportDirectory),
            profileService: ProfileService(appSupportDirectory: appSupportDirectory),
            usageStatisticsService: UsageStatisticsService(appSupportDirectory: appSupportDirectory)
        )
        let url = appSupportDirectory.appendingPathComponent("not-a-backup.json")
        try Data("{\"format\":\"something-else\"}".utf8).write(to: url)

        XCTAssertThrowsError(try service.inspectBackup(at: url))
    }
}

final class TermPackRegistryServiceTests: XCTestCase {
    @MainActor
    func testBackgroundCheckDoesNotRecordTimestampWhenFetchFails() async {
        let suiteName = "TermPackRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let service = TermPackRegistryService(
            userDefaults: defaults,
            fetchData: { _ in throw URLError(.notConnectedToInternet) }
        )

        service.checkForUpdatesInBackground()

        for _ in 0..<20 {
            if case .error = service.fetchState {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(defaults.double(forKey: UserDefaultsKeys.termPackRegistryLastUpdateCheck), 0)
    }

    @MainActor
    func testBackgroundCheckRecordsTimestampWhenFetchSucceeds() async throws {
        let suiteName = "TermPackRegistryServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let payload = """
        {
          "schemaVersion": 1,
          "packs": [
            {
              "id": "community-rust",
              "name": "Rust Terms",
              "description": "Rust ecosystem terms",
              "icon": "shippingbox",
              "version": "1.0.0",
              "author": "Tests",
              "terms": ["Tokio"]
            }
          ]
        }
        """.data(using: .utf8)!

        let service = TermPackRegistryService(
            userDefaults: defaults,
            fetchData: { _ in
                let response = HTTPURLResponse(
                    url: URL(string: "https://example.com/termpacks.json")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (payload, response)
            }
        )

        service.checkForUpdatesInBackground()

        for _ in 0..<20 {
            if service.fetchState == .loaded {
                break
            }
            await Task.yield()
        }

        XCTAssertGreaterThan(defaults.double(forKey: UserDefaultsKeys.termPackRegistryLastUpdateCheck), 0)
        XCTAssertEqual(service.communityPacks.map(\.id), ["community-rust"])
    }
}
