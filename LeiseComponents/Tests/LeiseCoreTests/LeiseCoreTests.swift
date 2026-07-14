import Testing
@testable import LeiseCore

@Test func sourceProgressClampsItsFraction() {
    #expect(TranscriptionSourceProgress(processedDuration: -1, totalDuration: 4).fractionCompleted == 0)
    #expect(TranscriptionSourceProgress(processedDuration: 2, totalDuration: 4).fractionCompleted == 0.5)
    #expect(TranscriptionSourceProgress(processedDuration: 8, totalDuration: 4).fractionCompleted == 1)
}

@Test func dictionaryHintsNormalizeAndClipDeterministically() {
    let hints = DictionaryTerms.normalizedHints(from: [
        DictionaryTermHint(text: " Leise ", ctcMinSimilarity: 0.7),
        DictionaryTermHint(text: "leise"),
        DictionaryTermHint(text: "Swift")
    ])
    #expect(hints == [
        DictionaryTermHint(text: "Leise", ctcMinSimilarity: 0.7),
        DictionaryTermHint(text: "Swift")
    ])
    #expect(DictionaryTerms.clippedHints(hints, maxTotalCharacters: 5).map(\.text) == ["Leise"])
}

@Test func transcriptionRequestsDefaultToAuthoritativeFinalPurpose() {
    let request = TranscriptionRequest(audio: TranscriptionAudio(samples: []))
    #expect(request.purpose == .final)
    #expect(request.sessionID == nil)
}
