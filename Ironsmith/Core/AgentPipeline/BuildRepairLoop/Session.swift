import AnyLanguageModel
import Foundation

extension ContentViewBuildRepairLoop {
    func makeGenerationSession(instructions: String) -> LanguageModelSession {
        LanguageModelSession(
            model: context.languageModel,
            instructions: instructions
        )
    }
}
