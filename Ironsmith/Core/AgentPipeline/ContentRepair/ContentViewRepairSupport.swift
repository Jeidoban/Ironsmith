import Foundation

enum ContentViewRepairSupport {
    static let snippetRadius = 8
    static let maximumTargetLength = 1_200
    static let maximumReplacementLength = 1_200
    static let defaultDeterministicEditOperationsPerBatch = ToolGenerationRepairPolicy.defaultDeterministicEditOperationsPerBatch

    static func actionableErrors(
        from diagnostics: [SwiftCompilerDiagnostic],
        contentViewPath: String
    ) -> [SwiftCompilerDiagnostic] {
        diagnostics
            .filter { $0.relativePath == contentViewPath && $0.severity == .error }
            .sorted { lhs, rhs in
                switch (isTypeCheckTimeout(lhs), isTypeCheckTimeout(rhs)) {
                case (true, false):
                    return false
                case (false, true):
                    return true
                default:
                    return lhs.line < rhs.line
                }
            }
    }

    static func extractSnippet(
        from source: String,
        around line: Int,
        radius: Int = snippetRadius
    ) -> ContentViewRepairSnippet {
        let lines = source.components(separatedBy: .newlines)
        let zeroBasedLine = max(0, line - 1)
        let startIndex = max(0, zeroBasedLine - radius)
        let endIndex = min(lines.count - 1, zeroBasedLine + radius)

        return ContentViewRepairSnippet(
            startLine: startIndex + 1,
            endLine: endIndex + 1,
            text: Array(lines[startIndex...endIndex]).joined(separator: "\n")
        )
    }

    static func snippets(
        from source: String,
        diagnostics: [SwiftCompilerDiagnostic]
    ) -> [ContentViewRepairSnippet] {
        diagnostics.map { extractSnippet(from: source, around: $0.line) }
    }

    static func relatedEditableSnippets(
        from source: String,
        diagnostics: [SwiftCompilerDiagnostic],
        excluding existingSnippets: [ContentViewRepairSnippet] = []
    ) -> [ContentViewRepairSnippet] {
        let lines = source.components(separatedBy: .newlines)
        var snippets: [ContentViewRepairSnippet] = []
        var seenLineIndexes = Set<Int>()
        let existingRanges = existingSnippets.map { ($0.startLine - 1)...($0.endLine - 1) }

        for diagnostic in diagnostics {
            for symbol in repairSymbolsNeedingRelatedDeclarations(for: diagnostic) {
                guard let declarationIndex = declarationLineIndex(for: symbol, in: lines) else {
                    continue
                }
                guard !existingRanges.contains(where: { $0.contains(declarationIndex) }),
                      seenLineIndexes.insert(declarationIndex).inserted
                else {
                    continue
                }
                snippets.append(extractSnippet(from: source, around: declarationIndex + 1, radius: 2))
            }
        }

        return snippets
    }

    static func enclosingEditableBlockSnippets(
        from source: String,
        diagnostics: [SwiftCompilerDiagnostic],
        excluding existingSnippets: [ContentViewRepairSnippet] = []
    ) -> [ContentViewRepairSnippet] {
        let lines = source.components(separatedBy: .newlines)
        let existingRanges = existingSnippets.map { ($0.startLine - 1)...($0.endLine - 1) }
        var snippets: [ContentViewRepairSnippet] = []
        var seenRanges = Set<String>()

        for diagnostic in diagnostics {
            let diagnosticIndex = diagnostic.line - 1
            guard lines.indices.contains(diagnosticIndex),
                  let range = enclosingEditableBlockRange(in: lines, containing: diagnosticIndex)
            else {
                continue
            }
            guard !existingRanges.contains(where: { existingRange in
                existingRange.lowerBound <= range.lowerBound && existingRange.upperBound >= range.upperBound
            }) else {
                continue
            }

            let rangeKey = "\(range.lowerBound)-\(range.upperBound)"
            guard seenRanges.insert(rangeKey).inserted else {
                continue
            }

            snippets.append(
                ContentViewRepairSnippet(
                    startLine: range.lowerBound + 1,
                    endLine: range.upperBound + 1,
                    text: lines[range].joined(separator: "\n")
                )
            )
        }

        return snippets
    }

    static func mergedSnippet(
        from source: String,
        diagnostics: [SwiftCompilerDiagnostic]
    ) -> ContentViewRepairSnippet {
        let lines = source.components(separatedBy: .newlines)
        guard let firstLine = diagnostics.map(\.line).min(),
              let lastLine = diagnostics.map(\.line).max()
        else {
            return extractSnippet(from: source, around: 1)
        }

        let startIndex = max(0, firstLine - 1 - snippetRadius)
        let endIndex = min(lines.count - 1, lastLine - 1 + snippetRadius)
        return ContentViewRepairSnippet(
            startLine: startIndex + 1,
            endLine: endIndex + 1,
            text: Array(lines[startIndex...endIndex]).joined(separator: "\n")
        )
    }

    static func selectedDiagnosticGroup(
        from diagnostics: [SwiftCompilerDiagnostic],
        maximumCount: Int
    ) -> [SwiftCompilerDiagnostic] {
        if let duplicateBody = diagnostics.first(where: { $0.message.contains("invalid redeclaration of 'body'") }) {
            return [duplicateBody]
        }

        if let observedObject = diagnostics.first(where: { $0.message.contains("ObservedObject") && $0.message.contains("ObservableObject") }) {
            return [observedObject]
        }

        guard let first = diagnostics.first else { return [] }
        let key = rootCauseKey(for: first)
        guard key.isBatchable else {
            return [first]
        }

        return Array(diagnostics.filter { rootCauseKey(for: $0) == key }.prefix(maximumCount))
    }

    static func estimatedRepairGroupCount(
        from diagnostics: [SwiftCompilerDiagnostic],
        maximumCount: Int
    ) -> Int {
        var remainingDiagnostics = diagnostics
        var groupCount = 0
        let maximumCount = max(1, maximumCount)

        while !remainingDiagnostics.isEmpty {
            let selectedDiagnostics = selectedDiagnosticGroup(
                from: remainingDiagnostics,
                maximumCount: maximumCount
            )
            guard !selectedDiagnostics.isEmpty else {
                break
            }

            groupCount += 1
            for diagnostic in selectedDiagnostics {
                if let index = remainingDiagnostics.firstIndex(of: diagnostic) {
                    remainingDiagnostics.remove(at: index)
                }
            }
        }

        return groupCount
    }

    static func repairStallKey(
        for diagnostics: [SwiftCompilerDiagnostic],
        source: String,
        maximumCount: Int
    ) -> String {
        let selectedDiagnostics = selectedDiagnosticGroup(
            from: diagnostics,
            maximumCount: maximumCount
        )
        let diagnosticKey = selectedDiagnostics
            .map { "\($0.line):\($0.column):\($0.message)" }
            .joined(separator: "|")
        return "\(source.hashValue)::\(diagnosticKey)"
    }

    private static func rootCauseKey(for diagnostic: SwiftCompilerDiagnostic) -> RepairRootCauseKey {
        if diagnostic.message.contains("'weak' may only be applied"),
           diagnostic.message.contains("ContentView") {
            return RepairRootCauseKey(kind: "weak-self-value-view", value: "ContentView", isBatchable: true)
        }
        if diagnostic.message.contains("cannot use optional chaining on non-optional value of type 'ContentView'") {
            return RepairRootCauseKey(kind: "nonoptional-self-optional-chaining", value: "ContentView", isBatchable: true)
        }
        if diagnostic.message.contains("expected '{' after 'if' condition")
            || diagnostic.message.contains("expected '{' after 'while' condition")
            || diagnostic.message.contains("is not a postfix unary operator") {
            return RepairRootCauseKey(kind: "comparison-operator-spacing", value: "control-flow-condition", isBatchable: true)
        }
        if diagnostic.message.contains("Bool"),
           diagnostic.message.contains("RandomAccessCollection") || diagnostic.message.contains("Sequence") {
            return RepairRootCauseKey(kind: "malformed-range-iteration", value: "bool-range", isBatchable: true)
        }
        if let symbol = firstCapture(in: diagnostic.message, pattern: #"cannot find '([^']+)' in scope"#) {
            return RepairRootCauseKey(kind: "missing-symbol", value: symbol, isBatchable: true)
        }
        if let argument = firstCapture(in: diagnostic.message, pattern: #"extra argument '([^']+)' in call"#) {
            return RepairRootCauseKey(kind: "extra-argument", value: argument, isBatchable: true)
        }
        if let member = firstCapture(in: diagnostic.message, pattern: #"has no member '([^']+)'"#) {
            return RepairRootCauseKey(kind: "unsupported-member", value: member, isBatchable: true)
        }
        return RepairRootCauseKey(kind: "single", value: diagnostic.message, isBatchable: false)
    }

    private static func repairSymbolsNeedingRelatedDeclarations(
        for diagnostic: SwiftCompilerDiagnostic
    ) -> [String] {
        var symbols: [String] = []
        let diagnosticText = diagnosticText(diagnostic)
        let patterns = [
            #"cannot assign to value: '([^']+)' is a 'let' constant"#,
            #"left side of mutating operator isn't mutable: '([^']+)' is a 'let' constant"#,
            #"cannot find '\$([^']+)' in scope"#,
            #"cannot find '([^']+)' in scope"#,
            #"value of type '([^']+)' has no dynamic member"#,
            #"referencing property '([^']+)' requires wrapper"#
        ]

        for pattern in patterns {
            if let symbol = firstCapture(in: diagnosticText, pattern: pattern),
               isIdentifier(symbol),
               !symbols.contains(symbol) {
                symbols.append(symbol)
            }
        }
        return symbols
    }

    static func diagnosticText(_ diagnostic: SwiftCompilerDiagnostic) -> String {
        ([diagnostic.message] + diagnostic.supportingLines).joined(separator: "\n")
    }

    private static func declarationLineIndex(
        for symbol: String,
        in lines: [String]
    ) -> Int? {
        let escapedSymbol = NSRegularExpression.escapedPattern(for: symbol)
        let patterns = [
            #"^\s*@State\b.*\b\#(escapedSymbol)\b"#,
            #"^\s*(?:private\s+)?(?:let|var)\s+\#(escapedSymbol)\b"#,
            #"^\s*(?:private\s+)?(?:let|var)\s+\$\#(escapedSymbol)\b"#,
            #"^\s*(?:private\s+)?func\s+\#(escapedSymbol)\b"#
        ]

        for pattern in patterns {
            if let index = lines.firstIndex(where: { line in
                line.range(of: pattern, options: .regularExpression) != nil
            }) {
                return index
            }
        }
        return nil
    }

    private static func enclosingEditableBlockRange(
        in lines: [String],
        containing diagnosticIndex: Int
    ) -> ClosedRange<Int>? {
        var fallback: ClosedRange<Int>?
        var preferred: ClosedRange<Int>?

        for startIndex in stride(from: diagnosticIndex, through: lines.startIndex, by: -1) {
            guard lines[startIndex].contains("{") else {
                continue
            }
            let endIndex = endOfBraceBlock(in: lines, startingAt: startIndex)
            guard endIndex >= diagnosticIndex else {
                continue
            }

            let range = startIndex...endIndex
            let text = lines[range].joined(separator: "\n")
            guard text.count <= maximumTargetLength else {
                continue
            }

            fallback = fallback ?? range
            let trimmedStart = lines[startIndex].trimmingCharacters(in: .whitespaces)
            if !isControlFlowBlockStart(trimmedStart) {
                preferred = preferred ?? range
            }
        }

        return preferred ?? fallback
    }

    private static func isControlFlowBlockStart(_ line: String) -> Bool {
        line.hasPrefix("if ")
            || line.hasPrefix("else ")
            || line.hasPrefix("else{")
            || line.hasPrefix("else {")
            || line.hasPrefix("guard ")
            || line.hasPrefix("for ")
            || line.hasPrefix("while ")
            || line.hasPrefix("switch ")
            || line.hasPrefix("do ")
            || line == "do {"
            || line.hasPrefix("catch ")
            || line == "catch {"
    }

    static func isTypeCheckTimeout(_ diagnostic: SwiftCompilerDiagnostic) -> Bool {
        diagnostic.message.localizedCaseInsensitiveContains("unable to type-check this expression in reasonable time")
    }

    static func isIdentifier(_ text: String) -> Bool {
        text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    static func containsForbiddenContent(_ text: String) -> Bool {
        text.contains("@main")
            || text.contains("Package.swift")
            || text.contains("AppDelegate")
            || text.contains("SceneDelegate")
    }

    static func validatesTargetContent(for operation: ContentViewDeterministicEditOperation) -> Bool {
        switch operation {
        case .addImport, .addStateProperty, .addHelperFunction, .renameIdentifierInSection:
            return true
        case .replaceLine, .replaceSection:
            return false
        }
    }

    static func containsProseLeak(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let proseMarkers = [
            "compiler diagnostic",
            "the prompt",
            "the best",
            "i will",
            "i cannot",
            "let's",
            "we need",
            "this path is tricky",
            "assuming",
            "however,"
        ]
        return text.contains("```")
            || text.contains("**")
            || text.range(of: #"(?m)(^|\s)//"#, options: .regularExpression) != nil
            || text.contains("/*")
            || proseMarkers.contains { lowered.contains($0) }
    }

    static func containsSchemaPlaceholder(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dummyValues: Set<String> = [
            "placeholder",
            "todo",
            "tbd",
            "dummy",
            "sample",
            "example",
            "fixme",
            "n/a"
        ]
        if dummyValues.contains(lowered) {
            return true
        }
        if lowered == "import placeholder" || lowered == "import dummy" {
            return true
        }
        return false
    }

    static func lineText(in snippet: ContentViewRepairSnippet, targetLine: Int) -> String? {
        guard targetLine >= snippet.startLine, targetLine <= snippet.endLine else {
            return nil
        }

        let lines = snippet.text.components(separatedBy: .newlines)
        return lines[targetLine - snippet.startLine]
    }

    static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[captureRange])
    }
}
