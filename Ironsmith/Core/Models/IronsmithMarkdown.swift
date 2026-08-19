import Foundation

nonisolated enum IronsmithMarkdown {
    static func attributedString(_ text: String) -> AttributedString {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? AttributedString(
            markdown: trimmed,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        )) ?? AttributedString(trimmed)
    }
}
