import Foundation

extension ContentViewRepairSupport {
    static func privateMemberwiseInitializerFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("initializer is inaccessible due to 'private' protection level"),
              let typeName = firstCapture(in: diagnostic.message, pattern: #"'(?:[A-Za-z_][A-Za-z0-9_]*\.)?([A-Za-z_][A-Za-z0-9_]*)' initializer"#)
        else {
            return nil
        }

        let lines = source.components(separatedBy: .newlines)
        guard let structStart = lines.indices.first(where: { index in
            lines[index].range(of: #"^\s*struct\s+\#(NSRegularExpression.escapedPattern(for: typeName))\b"#, options: .regularExpression) != nil
        }) else {
            return nil
        }

        let structEnd = endOfBraceBlock(in: lines, startingAt: structStart)
        guard structEnd > structStart else {
            return nil
        }

        for index in (structStart + 1)...structEnd {
            let line = lines[index]
            guard line.range(of: #"^\s*private\s+var\s+"#, options: .regularExpression) != nil else {
                continue
            }
            let updatedLine = line.replacingOccurrences(of: "private var", with: "private(set) var")
            guard updatedLine != line else {
                return nil
            }
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
        }

        return nil
    }

    static func missingStoredPropertyFromInitializerFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("value of type"),
              diagnostic.message.contains("has no member"),
              let typeName = firstCapture(in: diagnostic.message, pattern: #"value of type '([^']+)'"#),
              let missingMember = firstCapture(in: diagnostic.message, pattern: #"has no member '([^']+)'"#)
        else {
            return nil
        }

        let lines = source.components(separatedBy: .newlines)
        let diagnosticIndex = diagnostic.line - 1
        guard lines.indices.contains(diagnosticIndex),
              let structStart = stride(from: diagnosticIndex, through: lines.startIndex, by: -1).first(where: { index in
                  lines[index].range(of: #"^\s*struct\s+\#(NSRegularExpression.escapedPattern(for: typeName))\b"#, options: .regularExpression) != nil
              })
        else {
            return nil
        }

        let structEnd = endOfBraceBlock(in: lines, startingAt: structStart)
        guard structEnd > structStart else {
            return nil
        }

        var blockLines = Array(lines[structStart...structEnd])
        let blockText = blockLines.joined(separator: "\n")
        var candidateMembers = [missingMember] + assignedMemberNames(in: blockText)
        candidateMembers = Array(Set(candidateMembers)).sorted()

        let propertyIndent = storedPropertyIndent(in: blockLines)
        var declarationsToAdd: [String] = []
        for member in candidateMembers where blockText.range(of: #"\b(?:let|var)\s+\#(member)\b"#, options: .regularExpression) == nil {
            guard let type = storedPropertyType(for: member, typeName: typeName, in: blockText, source: source) else {
                continue
            }
            declarationsToAdd.append("\(propertyIndent)var \(member): \(type)")
        }

        guard !declarationsToAdd.isEmpty else {
            return nil
        }

        let insertionIndex = storedPropertyInsertionIndex(in: blockLines)
        blockLines.insert(contentsOf: declarationsToAdd, at: insertionIndex)

        let target = blockText
        let replacement = blockLines.joined(separator: "\n")
        guard target.count <= maximumTargetLength,
              replacement.count <= maximumReplacementLength
        else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceSection, target: target, replacement: replacement, section: nil)
    }

    static func stateInitializedFromStateFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("cannot use instance member"),
              diagnostic.message.contains("within property initializer"),
              let referencedName = firstCapture(in: diagnostic.message, pattern: #"cannot use instance member '([^']+)'"#),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("@State"),
              line.range(of: #"=\s*\#(referencedName)\s*$"#, options: .regularExpression) != nil,
              let literal = stateInitializerLiteral(for: referencedName, in: source)
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(
            of: #"=\s*\#(referencedName)\s*$"#,
            with: "= \(literal)",
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func dynamicMemberStateAliasFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("no dynamic member"),
              let memberName = firstCapture(in: diagnostic.message, pattern: #"no dynamic member '([^']+)'"#),
              stateDeclarationExists(for: memberName, in: source),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".\(memberName)")
        else {
            return nil
        }

        var updatedLine = line.replacingOccurrences(
            of: #"\$[A-Za-z_][A-Za-z0-9_]*\.\#(memberName)\b"#,
            with: "$\(memberName)",
            options: .regularExpression
        )
        updatedLine = updatedLine.replacingOccurrences(
            of: #"\b[A-Za-z_][A-Za-z0-9_]*\.\#(memberName)\b"#,
            with: memberName,
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func equatableConformanceFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("requires that"),
              diagnostic.message.contains("conform to 'Equatable'"),
              let typeName = firstCapture(in: diagnostic.message, pattern: #"'([^']+)'\s+conform to 'Equatable'"#)
        else {
            return nil
        }

        let lines = source.components(separatedBy: .newlines)
        guard let line = lines.first(where: { candidate in
            let trimmed = candidate.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("struct \(typeName)")
                && !trimmed.contains("Equatable")
                && trimmed.contains("{")
        }) else {
            return nil
        }

        let updatedLine: String
        if line.contains(":") {
            updatedLine = line.replacingOccurrences(of: "{", with: ", Equatable {")
        } else {
            updatedLine = line.replacingOccurrences(of: "{", with: ": Equatable {")
        }
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func indexPathMacOSFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard let line = lineText(in: snippet, targetLine: diagnostic.line) else {
            return nil
        }

        if diagnostic.message.contains("incorrect argument label in call"),
           line.contains("IndexPath(row:") {
            let updatedLine = line.replacingOccurrences(of: "IndexPath(row:", with: "IndexPath(item:")
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
        }

        if diagnostic.message.contains("IndexPath"),
           diagnostic.message.contains("has no member 'row'"),
           line.contains(".row") {
            let updatedLine = line.replacingOccurrences(of: ".row", with: ".item")
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
        }

        return nil
    }

    static func unknownKeyTypeFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("cannot find type 'Key' in scope"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(": Key") || line.contains("_ key: Key")
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(of: ": Key", with: ": KeyEquivalent")
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func invalidKeyEquivalentMemberFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("KeyEquivalent"),
              diagnostic.message.contains("has no member"),
              let line = lineText(in: snippet, targetLine: diagnostic.line)
        else {
            return nil
        }

        let replacements = [
            ".enter": ".return",
            ".up": ".upArrow",
            ".down": ".downArrow",
            ".left": ".leftArrow",
            ".right": ".rightArrow"
        ]
        for (target, replacement) in replacements where line.contains(target) {
            let updatedLine = line.replacingOccurrences(of: target, with: replacement)
            guard updatedLine != line else {
                return nil
            }
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
        }

        return nil
    }

    static func reservedKeywordEnumCaseFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("keyword 'operator' cannot be used as an identifier"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.trimmingCharacters(in: .whitespaces) == "case operator"
        else {
            return nil
        }

        return ContentViewDeterministicEdit(
            operation: .replaceLine,
            target: line,
            replacement: line.replacingOccurrences(of: "case operator", with: "case `operator`"),
            section: nil
        )
    }

    static func invalidImportFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard let moduleName = firstCapture(in: diagnostic.message, pattern: #"no such module '([^']+)'"#),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.trimmingCharacters(in: .whitespaces) == "import \(moduleName)"
        else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: "", section: nil)
    }

    static func uiAlertHelperNoopFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("UIAlertController")
            || diagnostic.message.contains("UIAlertAction")
        else {
            return nil
        }

        let lines = source.components(separatedBy: .newlines)
        guard let diagnosticIndex = lines.indices.first(where: { lineIndex in
            lines[lineIndex].contains("UIAlertController") || lines[lineIndex].contains("UIAlertAction")
        }),
        let functionStart = stride(from: diagnosticIndex, through: lines.startIndex, by: -1).first(where: { lineIndex in
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("func ") || trimmed.hasPrefix("private func ")
        }) else {
            return nil
        }

        let functionEnd = endOfBraceBlock(in: lines, startingAt: functionStart)
        let target = lines[functionStart...functionEnd].joined(separator: "\n")
        guard target.contains("UIAlertController") || target.contains("UIAlertAction") else {
            return nil
        }

        let functionLine = lines[functionStart]
        let signature = functionLine.split(separator: "{", maxSplits: 1).first.map(String.init) ?? functionLine
        let replacement = "\(signature.trimmingCharacters(in: .whitespaces)) { }"
        return ContentViewDeterministicEdit(operation: .replaceSection, target: target, replacement: replacement, section: nil)
    }

    static func shadowedPropertySelfAssignmentFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnosticText(diagnostic).contains("add explicit 'self.'"),
              let line = lineText(in: snippet, targetLine: diagnostic.line)
        else {
            return nil
        }

        let pattern = #"^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\2\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let indentationRange = Range(match.range(at: 1), in: line),
              let nameRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }

        let indentation = String(line[indentationRange])
        let name = String(line[nameRange])
        return ContentViewDeterministicEdit(
            operation: .replaceLine,
            target: line,
            replacement: "\(indentation)self.\(name) = \(name)",
            section: nil
        )
    }

    static func formattedNumericAssignmentFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("let' constant")
            || diagnostic.message.contains("cannot assign value of type 'String' to type 'Double'")
            || diagnostic.message.contains("cannot assign value of type 'String' to type 'Int'")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("String(format:")
        else {
            return nil
        }

        let pattern = #"^(\s*)((?:self\.)?)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*String\(format:\s*"[^"]+"\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\)\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let indentationRange = Range(match.range(at: 1), in: line),
              let receiverRange = Range(match.range(at: 2), in: line),
              let lhsRange = Range(match.range(at: 3), in: line),
              let rhsRange = Range(match.range(at: 4), in: line)
        else {
            return nil
        }

        let indentation = String(line[indentationRange])
        let receiver = String(line[receiverRange])
        let lhs = String(line[lhsRange])
        let rhs = String(line[rhsRange])
        guard lhs == rhs || numericStateDeclarationExists(for: lhs, in: source) else {
            return nil
        }

        if !receiver.isEmpty, lhs != rhs {
            return ContentViewDeterministicEdit(
                operation: .replaceLine,
                target: line,
                replacement: "\(indentation)\(receiver)\(lhs) = \(rhs)",
                section: nil
            )
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: "", section: nil)
    }

    static func missingDisplayStateFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String
    ) -> ContentViewDeterministicEdit? {
        guard let symbol = firstCapture(in: diagnostic.message, pattern: #"cannot find '([^']+)' in scope"#),
              isIdentifier(symbol),
              !declarationExists(for: symbol, in: source)
        else {
            return nil
        }

        let lowered = symbol.lowercased()
        if lowered.hasSuffix("formatted") {
            return ContentViewDeterministicEdit(
                operation: .addStateProperty,
                target: "State",
                replacement: "@State private var \(symbol): String = \"\"",
                section: "State"
            )
        }

        let integerWords = ["count", "counter", "cookie", "score", "tap", "click", "level", "time", "timer"]
        if integerWords.contains(where: { lowered.contains($0) }) {
            return ContentViewDeterministicEdit(
                operation: .addStateProperty,
                target: "State",
                replacement: "@State private var \(symbol): Int = 0",
                section: "State"
            )
        }

        let numericWords = ["amount", "balance", "interest", "payment", "principal", "total"]
        guard numericWords.contains(where: { lowered.contains($0) }) else {
            return nil
        }

        return ContentViewDeterministicEdit(
            operation: .addStateProperty,
            target: "State",
            replacement: "@State private var \(symbol): Double = 0.0",
            section: "State"
        )
    }

    static func nonVoidButtonActionFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("expected argument type"),
              diagnostic.message.contains("() -> Void"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("Button(action:")
        else {
            return nil
        }

        let pattern = #"Button\(action:\s*([A-Za-z_][A-Za-z0-9_]*)\)"#
        guard let functionName = firstCapture(in: line, pattern: pattern) else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(
            of: #"Button\(action:\s*\#(functionName)\)"#,
            with: "Button(action: { _ = \(functionName)() })",
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func missingClosingParenthesisFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("expected ',' separator"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("="),
              line.contains("pow(") || line.contains("/") || line.contains("*")
        else {
            return nil
        }

        let difference = parenthesisBalance(in: line)
        guard difference > 0, difference <= 2 else {
            return nil
        }

        return ContentViewDeterministicEdit(
            operation: .replaceLine,
            target: line,
            replacement: line + String(repeating: ")", count: difference),
            section: nil
        )
    }

    static func exponentOperatorFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("no operator '**' is defined"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("**")
        else {
            return nil
        }

        let pattern = #"(\([^()]+\)|[A-Za-z_][A-Za-z0-9_\.]*)\s*\*\*\s*(-?[A-Za-z_][A-Za-z0-9_\.]*|-?\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        var updatedLine = line
        for match in regex.matches(in: line, range: range).reversed() {
            guard let fullRange = Range(match.range(at: 0), in: updatedLine),
                  let baseRange = Range(match.range(at: 1), in: line),
                  let exponentRange = Range(match.range(at: 2), in: line)
            else {
                continue
            }
            let base = String(line[baseRange])
            let exponent = String(line[exponentRange])
            updatedLine.replaceSubrange(fullRange, with: "pow(\(base), \(exponent))")
        }

        guard updatedLine != line else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func methodPowFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard isTypeCheckTimeout(diagnostic)
            || diagnostic.message.localizedCaseInsensitiveContains("pow")
            || diagnostic.message.contains("has no member 'pow'")
        else {
            return nil
        }

        let lines = snippet.text.components(separatedBy: .newlines)
        guard let line = lines.first(where: { $0.contains(".pow(") }) else {
            return nil
        }

        let pattern = #"(\([^()]+\)|[A-Za-z_][A-Za-z0-9_\.]*)\.pow\(([^)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        var updatedLine = line
        for match in regex.matches(in: line, range: range).reversed() {
            guard let fullRange = Range(match.range(at: 0), in: updatedLine),
                  let baseRange = Range(match.range(at: 1), in: line),
                  let exponentRange = Range(match.range(at: 2), in: line)
            else {
                continue
            }
            let base = String(line[baseRange])
            let exponent = String(line[exponentRange])
            updatedLine.replaceSubrange(fullRange, with: "pow(\(base), \(exponent))")
        }

        guard updatedLine != line else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func observableObjectStructFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("non-class type"),
              diagnostic.message.contains("ObservableObject"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("struct "),
              line.contains(": ObservableObject")
        else {
            return nil
        }

        return ContentViewDeterministicEdit(
            operation: .replaceLine,
            target: line,
            replacement: line.replacingOccurrences(of: "struct ", with: "final class ", options: [], range: line.startIndex..<line.endIndex),
            section: nil
        )
    }

    static func helperViewConformanceFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("does not conform to protocol 'View'"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("struct "),
              line.contains(": View"),
              !line.contains("ContentView")
        else {
            return nil
        }

        return ContentViewDeterministicEdit(
            operation: .replaceLine,
            target: line,
            replacement: line.replacingOccurrences(of: ": View", with: ""),
            section: nil
        )
    }

    static func identifiableConformanceFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("does not conform to protocol 'Identifiable'"),
              !source.contains("let id"),
              !source.contains("var id"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(": Identifiable"),
              line.contains("{")
        else {
            return nil
        }

        return ContentViewDeterministicEdit(
            operation: .replaceLine,
            target: line,
            replacement: "\(line)\n  let id = UUID()",
            section: nil
        )
    }

    static func missingBindingPrefixFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("expected type 'Binding<String>'")
            || diagnostic.message.contains("to expected type 'Binding<String>'")
            || diagnostic.message.contains("use wrapper instead")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              let variableName = firstCapture(in: diagnostic.message, pattern: #"value '([^']+)'"#),
              line.contains(": \(variableName)"),
              stringStateDeclarationExists(for: variableName, in: source)
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(
            of: #":\s*\#(variableName)\b"#,
            with: ": $\(variableName)",
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func borderEdgesArgumentFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("extra argument 'edges' in call")
            || diagnostic.message.contains("reference to member 'bottom' cannot be resolved")
            || diagnostic.message.contains("reference to member 'trailing' cannot be resolved")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".border("),
              line.contains("edges:")
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(
            of: #",\s*edges:\s*\[[^\]]+\]"#,
            with: "",
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func unsupportedControlGroupStyleFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("ControlGroupStyle"),
              diagnostic.message.contains("has no member 'bordered'"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".controlGroupStyle(.bordered)")
        else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: "", section: nil)
    }

    static func invalidColorInitializerFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("no exact matches in call to initializer"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("Color(.")
        else {
            return nil
        }
        guard !line.contains("Color(.windowBackground)") else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(
            of: #"Color\(\.[A-Za-z_][A-Za-z0-9_]*\)"#,
            with: "Color.gray.opacity(0.3)",
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }
}
