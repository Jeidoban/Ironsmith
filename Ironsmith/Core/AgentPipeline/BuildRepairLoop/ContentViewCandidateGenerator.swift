import AnyLanguageModel
import Foundation

struct ContentViewCandidateGenerator {
    struct InvalidCandidateFallback {
        let threshold: Int
        let modeDescription: String
        let initialStatusVerb: String
        let retryStatusVerb: String
        let instructions: String
        let writeFreshCandidate: (LanguageModelSession) async throws -> Void

        init(
            threshold: Int,
            modeDescription: String,
            initialStatusVerb: String,
            retryStatusVerb: String,
            instructions: String = ToolGenerationPrompts.singleFileCodingInstructions,
            writeFreshCandidate: @escaping (LanguageModelSession) async throws -> Void
        ) {
            self.threshold = max(1, threshold)
            self.modeDescription = modeDescription
            self.initialStatusVerb = initialStatusVerb
            self.retryStatusVerb = retryStatusVerb
            self.instructions = instructions
            self.writeFreshCandidate = writeFreshCandidate
        }

        func makeGenerator() -> ContentViewCandidateGenerator {
            ContentViewCandidateGenerator(
                modeDescription: modeDescription,
                initialStatusVerb: initialStatusVerb,
                retryStatusVerb: retryStatusVerb,
                instructions: instructions,
                writeFreshCandidate: writeFreshCandidate
            )
        }
    }

    let modeDescription: String
    let initialStatusVerb: String
    let retryStatusVerb: String
    var instructions: String
    var retriesInvalidCandidates: Bool
    var invalidCandidateFallback: InvalidCandidateFallback?
    let writeFreshCandidate: (LanguageModelSession) async throws -> Void

    init(
        modeDescription: String,
        initialStatusVerb: String = "Generating",
        retryStatusVerb: String = "Regenerating",
        instructions: String = ToolGenerationPrompts.singleFileCodingInstructions,
        retriesInvalidCandidates: Bool = false,
        invalidCandidateFallback: InvalidCandidateFallback? = nil,
        writeFreshCandidate: @escaping (LanguageModelSession) async throws -> Void
    ) {
        self.modeDescription = modeDescription
        self.initialStatusVerb = initialStatusVerb
        self.retryStatusVerb = retryStatusVerb
        self.instructions = instructions
        self.retriesInvalidCandidates = retriesInvalidCandidates
        self.invalidCandidateFallback = invalidCandidateFallback
        self.writeFreshCandidate = writeFreshCandidate
    }
}
