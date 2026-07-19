import AnyLanguageModel
import Foundation

final class ContentViewRepairConversation {
    private let makeSession: () -> LanguageModelSession
    private let patchFormat: ToolSourcePatchFormat
    private(set) var session: LanguageModelSession
    private var sourceIsCurrentInSession = false
    private(set) var previousOutcome: String?
    private(set) var compactionSummary: String?

    init(context: ToolGenerationRuntimeContext) {
        let patchFormat = context.sourcePatchFormat
        self.patchFormat = patchFormat
        makeSession = {
            LanguageModelSession(
                model: context.languageModel,
                instructions: ToolGenerationPrompts.repairInstructions(for: patchFormat)
            )
        }
        session = makeSession()
    }

    func startNewCandidate() {
        session = makeSession()
        sourceIsCurrentInSession = false
        previousOutcome = nil
        compactionSummary = nil
    }

    func compactWithCurrentSource(outcome: String, summary: String) {
        session = makeSession()
        sourceIsCurrentInSession = false
        previousOutcome = outcome
        compactionSummary = summary
    }

    func keepAuthoritativeSourceInSession(outcome: String) {
        previousOutcome = outcome
    }

    func repairPrompt(
        diagnostics: [SwiftCompilerDiagnostic],
        source: String,
        editableSnippets: [ContentViewRepairSnippet],
        maximumPatchBlocks: Int
    ) -> String {
        let includeSource = !sourceIsCurrentInSession
        let prompt = ToolGenerationPrompts.conversationalRepairPrompt(
            diagnostics: diagnostics,
            source: includeSource ? source : nil,
            editableSnippets: editableSnippets,
            previousOutcome: previousOutcome,
            compactionSummary: includeSource ? compactionSummary : nil,
            maximumPatchBlocks: maximumPatchBlocks,
            patchFormat: patchFormat
        )
        if includeSource {
            sourceIsCurrentInSession = true
        }
        previousOutcome = nil
        compactionSummary = nil
        return prompt
    }

}
