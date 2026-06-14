import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    func makeGenerationSession(instructions: String) -> LanguageModelSession {
        LanguageModelSession(
            model: context.languageModel,
            instructions: instructions
        )
    }

    func repairStatus(errorCount: Int) -> String {
        let errorLabel = errorCount == 1 ? "error" : "errors"
        return "Repairing \(errorCount) \(errorLabel)"
    }
}
