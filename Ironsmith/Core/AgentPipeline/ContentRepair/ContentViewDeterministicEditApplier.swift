import Foundation

extension ContentViewRepairSupport {

    static func applyValidatedEdit(
        _ edit: ContentViewDeterministicEdit,
        to source: String,
        snippet: ContentViewRepairSnippet
    ) throws -> String {
        try applyValidatedDeterministicEdit(edit, to: source, snippets: [snippet])
    }

    static func applyValidatedDeterministicEdit(
        _ edit: ContentViewDeterministicEdit,
        to source: String,
        snippets: [ContentViewRepairSnippet]? = nil,
        allowedOperations: Set<ContentViewDeterministicEditOperation>? = nil,
        allowWholeSourceTargets: Bool = false
    ) throws -> String {
        try applyValidatedDeterministicEdits(
            [edit],
            to: source,
            snippets: snippets ?? [fullSourceSnippet(for: source)],
            allowedOperations: allowedOperations,
            allowWholeSourceTargets: allowWholeSourceTargets,
            maximumEdits: 1
        )
    }

    static func applyValidatedDeterministicEdits(
        _ edits: [ContentViewDeterministicEdit],
        to source: String,
        snippets: [ContentViewRepairSnippet],
        allowedOperations: Set<ContentViewDeterministicEditOperation>? = nil,
        allowWholeSourceTargets: Bool = false,
        maximumEdits: Int = defaultDeterministicEditOperationsPerBatch
    ) throws -> String {
        let boundedMaximumEdits = max(1, maximumEdits)
        guard !edits.isEmpty, edits.count <= boundedMaximumEdits else {
            throw invalidDeterministicEdit(reason: "batch contains \(edits.count) edits; expected 1...\(boundedMaximumEdits)")
        }

        var updatedSource = source
        let usesWholeSourceSnippet = snippets.count == 1
            && snippets[0].startLine == 1
            && snippets[0].text == source
        var seenTargets = Set<String>()
        for rawEdit in edits {
            let edit = sanitizedDeterministicEdit(rawEdit)
            if let allowedOperations {
                guard allowedOperations.contains(edit.operation) else {
                    throw invalidDeterministicEdit(reason: "operation \(edit.operation.rawValue) is not allowed for the selected diagnostic", edit: edit)
                }
            }
            guard edit.target.count <= maximumTargetLength else {
            throw invalidDeterministicEdit(reason: "target exceeds maximum length of \(maximumTargetLength) characters", edit: edit)
        }
        if validatesTargetContent(for: edit.operation) {
            guard !containsProseLeak(edit.target) else {
                throw invalidDeterministicEdit(reason: "deterministic edit target contains explanation or reasoning text", edit: edit)
            }
            guard !containsSchemaPlaceholder(edit.target) else {
                throw invalidDeterministicEdit(reason: "deterministic edit target contains placeholder or dummy text", edit: edit)
            }
        }
        guard !containsProseLeak(edit.replacement) else {
            throw invalidDeterministicEdit(reason: "deterministic edit fields contain explanation or reasoning text", edit: edit)
        }
        guard !containsSchemaPlaceholder(edit.replacement),
              !containsSchemaPlaceholder(edit.section ?? "")
        else {
            throw invalidDeterministicEdit(reason: "deterministic edit fields contain placeholder or dummy text", edit: edit)
        }
            guard seenTargets.insert("\(edit.operation.rawValue)::\(edit.target)").inserted else {
                throw invalidDeterministicEdit(reason: "duplicate operation target in batch", edit: edit)
            }
            guard edit.replacement.count <= maximumReplacementLength else {
                throw invalidDeterministicEdit(reason: "replacement exceeds maximum length of \(maximumReplacementLength) characters", edit: edit)
            }
            guard !containsForbiddenContent(edit.replacement) else {
                throw invalidDeterministicEdit(reason: "replacement contains forbidden content", edit: edit)
            }

            let operationSnippets = usesWholeSourceSnippet ? [fullSourceSnippet(for: updatedSource)] : snippets
            updatedSource = try applyValidatedOperation(
                edit,
                to: updatedSource,
                snippets: operationSnippets,
                allowWholeSourceTargets: allowWholeSourceTargets
            )
        }

        return updatedSource
    }

    private static func fullSourceSnippet(for source: String) -> ContentViewRepairSnippet {
        ContentViewRepairSnippet(
            startLine: 1,
            endLine: source.components(separatedBy: .newlines).count,
            text: source
        )
    }

    private static func sanitizedDeterministicEdit(_ edit: ContentViewDeterministicEdit) -> ContentViewDeterministicEdit {
        ContentViewDeterministicEdit(
            operation: edit.operation,
            target: sanitizedEditField(edit.target, stripsSwiftComments: false),
            replacement: sanitizedEditField(edit.replacement, stripsSwiftComments: true),
            section: edit.section.map { sanitizedSection($0) }
        )
    }

    private static func sanitizedSection(_ section: String) -> String {
        sanitizedEditField(section, stripsSwiftComments: true)
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func sanitizedEditField(_ text: String, stripsSwiftComments: Bool) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = fencedCodeBody(from: cleaned) ?? cleaned

        let lines = cleaned
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.hasPrefix("```") && !isEditProseLine(trimmed)
            }

        cleaned = lines.joined(separator: "\n")
        if stripsSwiftComments {
            cleaned = stripSwiftComments(from: cleaned)
        }
        return cleaned
            .replacingOccurrences(of: "```swift", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fencedCodeBody(from text: String) -> String? {
        guard let openingRange = text.range(of: "```") else { return nil }
        let afterOpening = text[openingRange.upperBound...]
        let bodyStart = afterOpening.firstIndex(of: "\n").map { text.index(after: $0) } ?? openingRange.upperBound
        guard let closingRange = text[bodyStart...].range(of: "```") else {
            return String(text[bodyStart...])
        }
        return String(text[bodyStart..<closingRange.lowerBound])
    }

    private static func isEditProseLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let lowered = line.lowercased()
        let prosePrefixes = [
            "here is",
            "here's",
            "replace ",
            "replacement:",
            "target:",
            "operation:",
            "section:",
            "explanation:",
            "note:",
            "because ",
            "to fix",
            "the fix",
            "this changes",
            "this replaces",
            "i will",
            "we need"
        ]
        return prosePrefixes.contains { lowered.hasPrefix($0) }
    }

    private static func stripSwiftComments(from text: String) -> String {
        let withoutBlockComments = text.replacingOccurrences(
            of: #"/\*[\s\S]*?\*/"#,
            with: "",
            options: .regularExpression
        )
        return withoutBlockComments
            .components(separatedBy: .newlines)
            .map { stripLineComment(from: $0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripLineComment(from line: String) -> String {
        var isInString = false
        var isEscaped = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                isInString.toggle()
            } else if character == "/",
                      !isInString,
                      line.index(after: index) < line.endIndex,
                      line[line.index(after: index)] == "/" {
                return String(line[..<index]).trimmingCharacters(in: .whitespaces)
            }
            index = line.index(after: index)
        }
        return line
    }

    static func applyValidatedDeterministicEdits(
        _ edits: [ContentViewDeterministicEdit],
        to source: String,
        maximumEdits: Int = defaultDeterministicEditOperationsPerBatch
    ) throws -> String {
        try applyValidatedDeterministicEdits(
            edits,
            to: source,
            snippets: [ContentViewRepairSnippet(startLine: 1, endLine: source.components(separatedBy: .newlines).count, text: source)],
            maximumEdits: maximumEdits
        )
    }

    private static func applyValidatedOperation(
        _ edit: ContentViewDeterministicEdit,
        to source: String,
        snippets: [ContentViewRepairSnippet],
        allowWholeSourceTargets: Bool
    ) throws -> String {
        switch edit.operation {
        case .addImport:
            return try applyAddImport(edit, to: source)
        case .addStateProperty:
            return try insertIntoSection(edit, to: source, section: "State", fallbackAfter: "struct ContentView")
        case .replaceLine:
            return try replaceLine(edit, in: source, snippets: snippets, allowWholeSourceTargets: allowWholeSourceTargets)
        case .replaceSection:
            return try replaceExactRegion(edit, in: source, snippets: snippets, allowWholeSourceTargets: allowWholeSourceTargets)
        case .addHelperFunction:
            return try insertIntoSection(edit, to: source, section: "Helpers", fallbackBeforeFinalBrace: true)
        case .renameIdentifierInSection:
            return try renameIdentifier(edit, in: source)
        }
    }

    private static func applyAddImport(
        _ edit: ContentViewDeterministicEdit,
        to source: String
    ) throws -> String {
        let module = edit.target
            .replacingOccurrences(of: "import ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !module.isEmpty else {
            throw invalidDeterministicEdit(reason: "addImport target is empty", edit: edit)
        }
        let importLine = "import \(module)"
        guard !source.contains(importLine) else {
            return source
        }

        var lines = source.components(separatedBy: .newlines)
        let insertIndex = lines.lastIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("import ") }.map { $0 + 1 } ?? 0
        lines.insert(importLine, at: insertIndex)
        return lines.joined(separator: "\n")
    }

    private static func replaceLine(
        _ edit: ContentViewDeterministicEdit,
        in source: String,
        snippets: [ContentViewRepairSnippet],
        allowWholeSourceTargets: Bool
    ) throws -> String {
        let target = edit.target.trimmingCharacters(in: .newlines)
        guard !target.isEmpty else {
            throw invalidDeterministicEdit(reason: "replaceLine target is empty", edit: edit)
        }

        var lines = source.components(separatedBy: .newlines)
        let indexes = lines.indices.filter { lines[$0] == target }
        let equivalentIndexes = lines.indices.filter { equivalentLine(lines[$0], target) }
        if allowWholeSourceTargets, indexes.count == 1, let index = indexes.first {
            lines[index] = replacementLine(edit.replacement, matching: lines[index])
            return lines.joined(separator: "\n")
        }
        if allowWholeSourceTargets, indexes.isEmpty, equivalentIndexes.count == 1, let index = equivalentIndexes.first {
            lines[index] = replacementLine(edit.replacement, matching: lines[index])
            return lines.joined(separator: "\n")
        }

        let snippetIndexes = lineMatchIndexes(for: target, in: source, snippets: snippets)
        guard !snippetIndexes.isEmpty else {
            throw invalidDeterministicEdit(reason: "replaceLine target does not appear as a full line in the repair excerpt", edit: edit)
        }

        if indexes.count == 1, let index = indexes.first {
            lines[index] = replacementLine(edit.replacement, matching: lines[index])
            return lines.joined(separator: "\n")
        }

        guard snippetIndexes.count == 1, let index = snippetIndexes.first else {
            throw invalidDeterministicEdit(
                reason: "replaceLine target appears \(indexes.count) times in source and \(snippetIndexes.count) times in repair excerpts; expected one targeted occurrence",
                edit: edit
            )
        }

        lines[index] = replacementLine(edit.replacement, matching: lines[index])
        return lines.joined(separator: "\n")
    }

    private static func replaceExactRegion(
        _ edit: ContentViewDeterministicEdit,
        in source: String,
        snippets: [ContentViewRepairSnippet],
        allowWholeSourceTargets: Bool
    ) throws -> String {
        let target = edit.target.trimmingCharacters(in: .newlines)
        let replacement = edit.replacement.trimmingCharacters(in: .newlines)
        guard !target.isEmpty else {
            throw invalidDeterministicEdit(reason: "replaceSection target is empty", edit: edit)
        }
        if allowWholeSourceTargets {
            let ranges = source.ranges(of: target)
            if ranges.count == 1, let range = ranges.first {
                var updated = source
                updated.replaceSubrange(range, with: replacement)
                return updated
            }
        }

        if snippets.contains(where: { $0.text.contains(target) }) {
            let ranges = source.ranges(of: target)
            guard ranges.count == 1, let range = ranges.first else {
                throw invalidDeterministicEdit(reason: "replaceSection target appears \(ranges.count) times in source; expected exactly 1", edit: edit)
            }
            var updated = source
            updated.replaceSubrange(range, with: replacement)
            return updated
        }

        if let region = lineRegionMatch(for: target, in: source, snippets: snippets) {
            var lines = source.components(separatedBy: .newlines)
            let replacementLines = replacement.isEmpty ? [] : replacement.components(separatedBy: .newlines)
            lines.replaceSubrange(region, with: replacementLines)
            return lines.joined(separator: "\n")
        }

        throw invalidDeterministicEdit(reason: "replaceSection target does not appear in the repair excerpt", edit: edit)
    }

    private static func lineMatchIndexes(
        for target: String,
        in source: String,
        snippets: [ContentViewRepairSnippet]
    ) -> Set<Int> {
        let lines = source.components(separatedBy: .newlines)
        return Set(
            snippets.flatMap { snippet in
                snippet.text.components(separatedBy: .newlines).enumerated().compactMap { offset, line -> Int? in
                    guard equivalentLine(line, target) else { return nil }
                    let sourceIndex = snippet.startLine - 1 + offset
                    guard lines.indices.contains(sourceIndex),
                          equivalentLine(lines[sourceIndex], target)
                    else { return nil }
                    return sourceIndex
                }
            }
        )
    }

    private static func lineRegionMatch(
        for target: String,
        in source: String,
        snippets: [ContentViewRepairSnippet]
    ) -> ClosedRange<Int>? {
        let sourceLines = source.components(separatedBy: .newlines)
        let targetLines = trimmedBoundaryLines(target.components(separatedBy: .newlines))
        guard !targetLines.isEmpty else { return nil }

        var matches: [ClosedRange<Int>] = []
        for snippet in snippets {
            let snippetLines = snippet.text.components(separatedBy: .newlines)
            guard snippetLines.count >= targetLines.count else { continue }
            for start in 0...(snippetLines.count - targetLines.count) {
                let window = Array(snippetLines[start..<(start + targetLines.count)])
                guard equivalentBlock(window, targetLines) else { continue }
                let sourceStart = snippet.startLine - 1 + start
                let sourceEnd = sourceStart + targetLines.count - 1
                guard sourceLines.indices.contains(sourceStart),
                      sourceLines.indices.contains(sourceEnd),
                      equivalentBlock(Array(sourceLines[sourceStart...sourceEnd]), targetLines)
                else { continue }
                matches.append(sourceStart...sourceEnd)
            }
        }

        return Set(matches).count == 1 ? matches.first : nil
    }

    private static func equivalentBlock(_ candidate: [String], _ target: [String]) -> Bool {
        guard candidate.count == target.count else { return false }
        if zip(candidate, target).allSatisfy({ equivalentLine($0.0, $0.1) }) {
            return true
        }
        return stripCommonIndent(candidate) == stripCommonIndent(target)
    }

    private static func equivalentLine(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if lhs.trimmingCharacters(in: .whitespaces) == rhs.trimmingCharacters(in: .whitespaces) {
            return true
        }
        return normalizedInlineWhitespace(lhs) == normalizedInlineWhitespace(rhs)
    }

    private static func replacementLine(_ replacement: String, matching original: String) -> String {
        let trimmedReplacement = replacement.trimmingCharacters(in: .newlines)
        guard !trimmedReplacement.isEmpty,
              let firstReplacementCharacter = trimmedReplacement.first,
              !firstReplacementCharacter.isWhitespace,
              original.first?.isWhitespace == true
        else {
            return trimmedReplacement
        }
        return indentation(of: original) + trimmedReplacement
    }

    private static func normalizedInlineWhitespace(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func trimmedBoundaryLines(_ lines: [String]) -> [String] {
        var trimmed = lines
        while trimmed.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            trimmed.removeFirst()
        }
        while trimmed.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func stripCommonIndent(_ lines: [String]) -> [String] {
        let nonEmptyIndents = lines.compactMap { line -> Int? in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return line.prefix { $0 == " " || $0 == "\t" }.count
        }
        guard let commonIndent = nonEmptyIndents.min(), commonIndent > 0 else {
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return lines.map { line in
            guard line.count >= commonIndent else { return line.trimmingCharacters(in: .whitespaces) }
            let dropIndex = line.index(line.startIndex, offsetBy: commonIndent)
            return String(line[dropIndex...])
        }
    }

    private static func indentation(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    static func endOfBraceBlock(in lines: [String], startingAt startIndex: Int) -> Int {
        var depth = 0
        var sawOpeningBrace = false
        var index = startIndex
        while lines.indices.contains(index) {
            for character in lines[index] {
                if character == "{" {
                    depth += 1
                    sawOpeningBrace = true
                } else if character == "}" {
                    depth -= 1
                    if sawOpeningBrace, depth == 0 {
                        return index
                    }
                }
            }
            index += 1
        }
        return startIndex
    }

    private static func insertIntoSection(
        _ edit: ContentViewDeterministicEdit,
        to source: String,
        section: String,
        fallbackAfter: String? = nil,
        fallbackBeforeFinalBrace: Bool = false
    ) throws -> String {
        let replacement = edit.replacement.trimmingCharacters(in: .newlines)
        guard !replacement.isEmpty else {
            throw invalidDeterministicEdit(reason: "\(edit.operation.rawValue) replacement is empty", edit: edit)
        }
        guard !containsForbiddenContent(replacement) else {
            throw invalidDeterministicEdit(reason: "\(edit.operation.rawValue) replacement contains forbidden content", edit: edit)
        }
        guard !source.contains(replacement) else {
            return source
        }

        var lines = source.components(separatedBy: .newlines)
        if let markerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "// MARK: - \(section)" }) {
            lines.insert(replacement, at: markerIndex + 1)
            return lines.joined(separator: "\n")
        }

        if let fallbackAfter,
           let index = lines.firstIndex(where: { $0.contains(fallbackAfter) }) {
            lines.insert("    \(replacement)", at: index + 1)
            return lines.joined(separator: "\n")
        }

        if fallbackBeforeFinalBrace,
           let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "}" }) {
            lines.insert(replacement, at: index)
            return lines.joined(separator: "\n")
        }

        throw invalidDeterministicEdit(reason: "could not find insertion point for \(edit.operation.rawValue)", edit: edit)
    }

    private static func renameIdentifier(
        _ edit: ContentViewDeterministicEdit,
        in source: String
    ) throws -> String {
        let oldName = edit.target.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = edit.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isIdentifier(oldName), isIdentifier(newName) else {
            throw invalidDeterministicEdit(reason: "renameIdentifierInSection requires identifier target and replacement", edit: edit)
        }

        let sectionRange: Range<String.Index>
        if let section = edit.section, let range = rangeForSection(section, in: source) {
            sectionRange = range
        } else {
            sectionRange = source.startIndex..<source.endIndex
        }

        let sectionSource = String(source[sectionRange])
        let pattern = #"\b\#(NSRegularExpression.escapedPattern(for: oldName))\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw invalidDeterministicEdit(reason: "could not build identifier rename regex", edit: edit)
        }
        let matches = regex.matches(in: sectionSource, range: NSRange(sectionSource.startIndex..<sectionSource.endIndex, in: sectionSource))
        guard !matches.isEmpty else {
            throw invalidDeterministicEdit(reason: "identifier target does not appear in selected section", edit: edit)
        }

        let replaced = regex.stringByReplacingMatches(
            in: sectionSource,
            range: NSRange(sectionSource.startIndex..<sectionSource.endIndex, in: sectionSource),
            withTemplate: newName
        )
        var updated = source
        updated.replaceSubrange(sectionRange, with: replaced)
        return updated
    }

    private static func rangeForSection(_ section: String, in source: String) -> Range<String.Index>? {
        let marker = "// MARK: - \(section)"
        guard let start = source.range(of: marker)?.lowerBound else {
            return nil
        }
        let searchStart = source.index(start, offsetBy: marker.count)
        let nextMarker = source.range(of: "// MARK: - ", range: searchStart..<source.endIndex)?.lowerBound ?? source.endIndex
        return start..<nextMarker
    }

    static func invalidDeterministicEdit(
        reason: String,
        edit: ContentViewDeterministicEdit,
        snippet: ContentViewRepairSnippet
    ) -> ToolGenerationError {
        AgentDiagnosticsLog.append(
            """
            Invalid deterministic repair edit.
            reason: \(reason)
            edit:
            \(AgentDiagnosticsLog.renderDeterministicEdit(edit))
            snippetLines: \(snippet.startLine)-\(snippet.endLine)
            snippetPreview: \(AgentDiagnosticsLog.compact(snippet.text, limit: 500))
            """
        )
#if DEBUG
        print("[Ironsmith][Repair] Invalid deterministic edit reason: \(reason)")
        print("[Ironsmith][Repair] Edit operation: \(edit.operation.rawValue)")
        print("[Ironsmith][Repair] Edit target: \(String(reflecting: AgentDiagnosticsLog.compact(edit.target)))")
        print("[Ironsmith][Repair] Edit replacement: \(String(reflecting: AgentDiagnosticsLog.compact(edit.replacement)))")
        print("[Ironsmith][Repair] Snippet lines: \(snippet.startLine)-\(snippet.endLine)")
        print("[Ironsmith][Repair] Snippet preview: \(AgentDiagnosticsLog.compact(snippet.text, limit: 500))")
#endif
        return .invalidRepairPatch
    }

    static func invalidDeterministicEdit(
        reason: String,
        edit: ContentViewDeterministicEdit? = nil
    ) -> ToolGenerationError {
        AgentDiagnosticsLog.append(
            """
            Invalid deterministic repair edit.
            reason: \(reason)
            edit:
            \(edit.map { AgentDiagnosticsLog.renderDeterministicEdit($0) } ?? "<none>")
            """
        )
#if DEBUG
        print("[Ironsmith][Repair] Invalid deterministic edit reason: \(reason)")
        if let edit {
            print("[Ironsmith][Repair] Edit operation: \(edit.operation.rawValue)")
            print("[Ironsmith][Repair] Edit target: \(String(reflecting: AgentDiagnosticsLog.compact(edit.target)))")
            print("[Ironsmith][Repair] Edit replacement: \(String(reflecting: AgentDiagnosticsLog.compact(edit.replacement)))")
            print("[Ironsmith][Repair] Edit section: \(String(describing: edit.section))")
        }
#endif
        return .invalidRepairPatch
    }

    static func logInvalidDeterministicEditAttempt(
        _ edit: ContentViewDeterministicEdit,
        diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet,
        usedDeterministicFixer: Bool
    ) {
#if DEBUG
        let source = usedDeterministicFixer ? "deterministic fixer" : "model repair"
        print("[Ironsmith][Repair] Rejected deterministic edit from \(source).")
        print("[Ironsmith][Repair] Diagnostic: line \(diagnostic.line), column \(diagnostic.column), \(diagnostic.message)")
        print("[Ironsmith][Repair] Edit operation: \(edit.operation.rawValue)")
        print("[Ironsmith][Repair] Edit target: \(String(reflecting: AgentDiagnosticsLog.compact(edit.target)))")
        print("[Ironsmith][Repair] Edit replacement: \(String(reflecting: AgentDiagnosticsLog.compact(edit.replacement)))")
        print("[Ironsmith][Repair] Snippet lines: \(snippet.startLine)-\(snippet.endLine)")
#endif
    }
}

private extension String {
    func ranges(of substring: String) -> [Range<String.Index>] {
        guard !substring.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var startIndex = self.startIndex

        while startIndex < endIndex,
              let range = range(of: substring, range: startIndex..<endIndex) {
            result.append(range)
            startIndex = range.upperBound
        }

        return result
    }
}
