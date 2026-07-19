import AnyLanguageModel
import Foundation

struct ContentViewCandidateGenerator {
    struct DiagnosticRewrite {
        let instructions: String
        let writeCandidate: (
            _ currentSource: String,
            _ diagnostics: [SwiftCompilerDiagnostic],
            _ session: LanguageModelSession
        ) async throws -> Void

        init(
            instructions: String = ToolGenerationPrompts.singleFileCodingInstructions,
            writeCandidate: @escaping (
                _ currentSource: String,
                _ diagnostics: [SwiftCompilerDiagnostic],
                _ session: LanguageModelSession
            ) async throws -> Void
        ) {
            self.instructions = instructions
            self.writeCandidate = writeCandidate
        }
    }

    struct InvalidCandidateFallback {
        let threshold: Int
        let modeDescription: String
        let instructions: String
        let writeFreshCandidate: (LanguageModelSession) async throws -> Void

        init(
            threshold: Int,
            modeDescription: String,
            instructions: String = ToolGenerationPrompts.singleFileCodingInstructions,
            writeFreshCandidate: @escaping (LanguageModelSession) async throws -> Void
        ) {
            self.threshold = max(1, threshold)
            self.modeDescription = modeDescription
            self.instructions = instructions
            self.writeFreshCandidate = writeFreshCandidate
        }

        func makeGenerator() -> ContentViewCandidateGenerator {
            ContentViewCandidateGenerator(
                modeDescription: modeDescription,
                instructions: instructions,
                writeFreshCandidate: writeFreshCandidate
            )
        }
    }

    let modeDescription: String
    var instructions: String
    var retriesInvalidCandidates: Bool
    var invalidCandidateFallback: InvalidCandidateFallback?
    var diagnosticRewrite: DiagnosticRewrite?
    let writeFreshCandidate: (LanguageModelSession) async throws -> Void

    init(
        modeDescription: String,
        instructions: String = ToolGenerationPrompts.singleFileCodingInstructions,
        retriesInvalidCandidates: Bool = false,
        invalidCandidateFallback: InvalidCandidateFallback? = nil,
        diagnosticRewrite: DiagnosticRewrite? = nil,
        writeFreshCandidate: @escaping (LanguageModelSession) async throws -> Void
    ) {
        self.modeDescription = modeDescription
        self.instructions = instructions
        self.retriesInvalidCandidates = retriesInvalidCandidates
        self.invalidCandidateFallback = invalidCandidateFallback
        self.diagnosticRewrite = diagnosticRewrite
        self.writeFreshCandidate = writeFreshCandidate
    }
}
