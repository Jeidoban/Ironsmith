import Foundation

extension ContentViewRepairSupport {
    static func extraneousStringWrapperLabelFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("extraneous argument label 'nextColumnString:'"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("String(nextColumnString:")
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(
            of: #"String\(nextColumnString:\s*([A-Za-z_][A-Za-z0-9_]*)\)"#,
            with: #"nextColumnString($1)"#,
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func extraArgumentFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        let pattern = #"extra argument '([^']+)' in call"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: diagnostic.message,
                range: NSRange(diagnostic.message.startIndex..<diagnostic.message.endIndex, in: diagnostic.message)
            ),
            let argumentRange = Range(match.range(at: 1), in: diagnostic.message)
        else {
            return nil
        }

        let argumentName = String(diagnostic.message[argumentRange])

        if let closureRemoval = closureExtraArgumentRemoval(
            argumentName: argumentName,
            snippetText: snippet.text
        ) {
            return ContentViewDeterministicEdit(operation: .replaceSection, target: closureRemoval, replacement: "", section: nil)
        }

        if let line = lineText(in: snippet, targetLine: diagnostic.line),
           let inlineRemoval = inlineExtraArgumentRemoval(
            argumentName: argumentName,
            line: line
        ) {
            return ContentViewDeterministicEdit(
                operation: .replaceLine,
                target: line,
                replacement: line.replacingOccurrences(of: inlineRemoval, with: ""),
                section: nil
            )
        }

        return nil
    }

    static func stringTextFieldFormatFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("no exact matches in call to initializer")
            || diagnostic.message.contains("ParseableFormatStyle")
            || diagnostic.message.contains("has no member 'string'")
            || diagnostic.message.contains("has no member 'url'")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("TextField("),
              line.contains("value: $"),
              line.contains("format: ."),
              let variableName = firstCapture(in: line, pattern: #"value:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#),
              stringStateDeclarationExists(for: variableName, in: source)
        else {
            return nil
        }

        var updatedLine = line.replacingOccurrences(of: "value: $\(variableName)", with: "text: $\(variableName)")
        updatedLine = updatedLine.replacingOccurrences(
            of: #",\s*format:\s*\.(?:string|url)"#,
            with: "",
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func windowBackgroundColorFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("no exact matches in call to initializer"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("Color(.windowBackground)")
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(
            of: "Color(.windowBackground)",
            with: "Color(NSColor.windowBackgroundColor)"
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func closureExtraArgumentRemoval(
        argumentName: String,
        snippetText: String
    ) -> String? {
        let argumentPattern = #",\s*\#(argumentName):\s*\{"#
        guard
            let argumentRegex = try? NSRegularExpression(pattern: argumentPattern),
            let startMatch = argumentRegex.firstMatch(
                in: snippetText,
                range: NSRange(snippetText.startIndex..<snippetText.endIndex, in: snippetText)
            ),
            let startRange = Range(startMatch.range, in: snippetText)
        else {
            return nil
        }

        let source = snippetText
        var braceDepth = 0
        var index = startRange.upperBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" {
                braceDepth += 1
            } else if character == "}" {
                if braceDepth == 0 {
                    let endIndex = source.index(after: index)
                    return String(source[startRange.lowerBound..<endIndex])
                }
                braceDepth -= 1
            }
            index = source.index(after: index)
        }

        return nil
    }

    static func inlineExtraArgumentRemoval(
        argumentName: String,
        line: String?
    ) -> String? {
        guard let line else {
            return nil
        }

        let pattern = #",\s*\#(argumentName):\s*(?:"(?:[^"\\]|\\.)*"|[^,\)\n]+)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line)
            ),
            let range = Range(match.range, in: line)
        else {
            return nil
        }

        return String(line[range])
    }

    static func unsupportedModifierFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        if let line = lineText(in: snippet, targetLine: diagnostic.line),
           diagnostic.message.contains("has no member 'onDoubleClick'"),
           line.contains(".onDoubleClick") {
            let updatedLine = line.replacingOccurrences(of: ".onDoubleClick", with: ".onTapGesture(count: 2)")
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
        }

        if let line = lineText(in: snippet, targetLine: diagnostic.line),
           diagnostic.message.contains("has no member 'onDoubleTapGesture'"),
           line.contains(".onDoubleTapGesture") {
            let updatedLine = line.replacingOccurrences(of: ".onDoubleTapGesture", with: ".onTapGesture(count: 2)")
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
        }

        guard
            diagnostic.message.contains("has no member 'keyboardType'")
                || diagnostic.message.contains("cannot find 'keyboardType' in scope"),
            let line = lineText(in: snippet, targetLine: diagnostic.line)
        else {
            return nil
        }

        guard line.contains(".keyboardType(") || line.contains("keyboardType(") else {
            return nil
        }

        let snippetLines = snippet.text.components(separatedBy: .newlines)
        let targetOffset = diagnostic.line - snippet.startLine
        if targetOffset > 0,
           snippetLines.indices.contains(targetOffset),
           let textFieldOffset = stride(from: targetOffset - 1, through: 0, by: -1)
               .first(where: { snippetLines[$0].contains("TextField(") }) {
            let targetLines = snippetLines[textFieldOffset...targetOffset]
            let replacementLines = targetLines.dropLast()
            return ContentViewDeterministicEdit(
                operation: .replaceSection,
                target: targetLines.joined(separator: "\n"),
                replacement: replacementLines.joined(separator: "\n"),
                section: nil
            )
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: "", section: nil)
    }

    static func invalidMonospacedDigitFontFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("monospacedDigit")
            || diagnostic.message.contains("Font' has no member 'fixed'")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".font(.monospacedDigit")
        else {
            return nil
        }

        let size = firstCapture(in: line, pattern: #"size:\s*([0-9]+(?:\.[0-9]+)?)"#) ?? "12"
        let updatedLine = "\(deterministicRepairIndentation(of: line)).font(.system(size: \(size), design: .monospaced))"
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func unsupportedFocusModifierFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("cannot find '$")
            || diagnostic.message.contains("cannot convert value of type 'Bool' to expected argument type 'FocusState<Bool>.Binding'")
            || diagnostic.message.contains("cannot convert value of type 'KeyPath")
            || diagnostic.message.contains("cannot infer key path type from context")
            || diagnostic.message.contains("cannot find 'isEditingField' in scope")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".focused(")
        else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: "", section: nil)
    }

    static func numericTextFieldFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard
            diagnostic.message.contains("Binding<String>")
                || diagnostic.message.contains("StringProtocol")
        else {
            return nil
        }

        guard let line = lineText(in: snippet, targetLine: diagnostic.line), line.contains("TextField("), line.contains("text: $") else {
            return nil
        }

        let bindingPattern = #"text:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#
        guard
            let regex = try? NSRegularExpression(pattern: bindingPattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
            let variableRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }

        let variableName = String(line[variableRange])
        guard source.contains("@State private var \(variableName): Double")
            || source.contains("@State private var \(variableName): Int")
            || source.contains("@State private var \(variableName) = 0")
            || source.contains("@State private var \(variableName) = 0.0")
        else {
            return nil
        }

        guard !line.contains("format:") else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(of: "text: $\(variableName)", with: "value: $\(variableName), format: .number")
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func optionalNumericTextFallbackFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("cannot convert value of type 'Double?' to expected argument type 'String?'"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("Text("),
              line.contains("?? \"\""),
              let expression = firstCapture(in: line, pattern: #"\\\(([A-Za-z_][A-Za-z0-9_\.]*)\s*\?\?\s*""\)"#)
        else {
            return nil
        }

        let updatedExpression = "\(expression).map { String(format: \"%.2f\", $0) } ?? \"\""
        let updatedLine = line.replacingOccurrences(of: "\(expression) ?? \"\"", with: updatedExpression)
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func numericIsEmptyFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("isEmpty"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".isEmpty")
        else {
            return nil
        }

        let pattern = #"!([A-Za-z_][A-Za-z0-9_]*)\.isEmpty"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let updatedLine = regex.stringByReplacingMatches(
            in: line,
            range: NSRange(line.startIndex..<line.endIndex, in: line),
            withTemplate: "$1 > 0"
        )
        guard updatedLine != line else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func roundedToPlacesFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("rounded"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".rounded(toPlaces:")
        else {
            return nil
        }

        if line.range(of: #"^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*[A-Za-z_][A-Za-z0-9_]*\.rounded\(toPlaces:\s*\d+\)\s*$"#, options: .regularExpression) != nil {
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: "", section: nil)
        }

        let updatedLine = line.replacingOccurrences(
            of: #"\.rounded\(toPlaces:\s*\d+\)"#,
            with: ".rounded()",
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func simpleNumericConversionFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard let line = lineText(in: snippet, targetLine: diagnostic.line) else {
            return nil
        }

        if diagnostic.message.contains("cannot convert value of type 'Int' to expected argument type 'Double'"),
           let updatedLine = wrapSimpleAssignmentExpression(in: line, with: "Double") {
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
        }

        if diagnostic.message.contains("cannot convert value of type 'Double' to expected argument type 'Int'"),
           let updatedLine = wrapSimpleAssignmentExpression(in: line, with: "Int") {
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
        }

        return nil
    }

    static func substringToStringArgumentFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("String.SubSequence")
            || diagnostic.message.contains("Substring")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line) else {
            return nil
        }

        let pattern = #"([A-Za-z_][A-Za-z0-9_]*)\(([A-Za-z_][A-Za-z0-9_]*\.(?:prefix|dropFirst)\([^)]*\))\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        var updatedLine = line
        for match in regex.matches(in: line, range: range).reversed() {
            guard let fullRange = Range(match.range(at: 0), in: updatedLine),
                  let functionRange = Range(match.range(at: 1), in: line),
                  let expressionRange = Range(match.range(at: 2), in: line)
            else {
                continue
            }

            let functionName = String(line[functionRange])
            let expression = String(line[expressionRange])
            guard !expression.hasPrefix("String(") else {
                continue
            }
            updatedLine.replaceSubrange(fullRange, with: "\(functionName)(String(\(expression)))")
        }

        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func characterSetContainsCharacterFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("String.Element")
            || diagnostic.message.contains("Character")
            || diagnostic.message.contains("Unicode.Scalar")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("CharacterSet."),
              line.contains(".contains($0.first!)")
        else {
            return nil
        }

        let pattern = #"CharacterSet\.([A-Za-z_][A-Za-z0-9_]*)\.contains\(\$0\.first!\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let fullRange = Range(match.range(at: 0), in: line),
              let setRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }

        var updatedLine = line
        updatedLine.replaceSubrange(fullRange, with: "($0.rangeOfCharacter(from: .\(line[setRange])) != nil)")
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func malformedArraySliceFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("expected argument type 'Int'")
            || diagnostic.message.contains("PartialRangeFrom<Int>")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("String("),
              line.contains("[")
        else {
            return nil
        }

        var updatedLine = line.replacingOccurrences(
            of: #"\[0\s*<\s*([A-Za-z_][A-Za-z0-9_]*)\]"#,
            with: #"[0..<\#(firstCapture(in: line, pattern: #"\[0\s*<\s*([A-Za-z_][A-Za-z0-9_]*)\]"#) ?? "")]"#,
            options: .regularExpression
        )
        updatedLine = updatedLine.replacingOccurrences(
            of: #"\[([A-Za-z_][A-Za-z0-9_]*)\s*\+\s*1\.\.\.\]"#,
            with: #"[(\#(firstCapture(in: line, pattern: #"\[([A-Za-z_][A-Za-z0-9_]*)\s*\+\s*1\.\.\.\]"#) ?? "") + 1)...]"#,
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func optionalMapTypeCheckFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard isTypeCheckTimeout(diagnostic),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".map {"),
              line.contains("?? false")
        else {
            return nil
        }

        let pattern = #"([A-Za-z_][A-Za-z0-9_]*)\.map\s*\{\s*\$0\.([A-Za-z_][A-Za-z0-9_]*)\s*==\s*([A-Za-z_][A-Za-z0-9_]*)\s*\}\s*\?\?\s*false"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let optionalRange = Range(match.range(at: 1), in: line),
              let memberRange = Range(match.range(at: 2), in: line),
              let comparedRange = Range(match.range(at: 3), in: line),
              let fullRange = Range(match.range(at: 0), in: line)
        else {
            return nil
        }

        var updatedLine = line
        updatedLine.replaceSubrange(
            fullRange,
            with: "\(line[optionalRange])?.\(line[memberRange]) == \(line[comparedRange])"
        )
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func contextMenuIndexHoistTypeCheckFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard isTypeCheckTimeout(diagnostic),
              snippet.text.contains("ContextMenu {"),
              let expression = repeatedContextMenuIndexExpression(in: snippet.text)
        else {
            return nil
        }

        let lines = snippet.text.components(separatedBy: .newlines)
        let diagnosticIndex = diagnostic.line - snippet.startLine
        guard lines.indices.contains(diagnosticIndex),
              let menuStart = stride(from: diagnosticIndex, through: lines.startIndex, by: -1)
                  .first(where: { line in
                      lines[line].contains(".contextMenu {")
                          || lines[line].contains(".onContextMenu {")
                  })
        else {
            return nil
        }

        let menuEnd = endOfBraceBlock(in: lines, startingAt: menuStart)
        guard menuEnd > menuStart else {
            return nil
        }

        let targetLines = Array(lines[menuStart...menuEnd])
        let target = targetLines.joined(separator: "\n")
        guard target.contains("ContextMenu {"),
              target.contains("Button("),
              !target.contains("let idx ="),
              target.count <= maximumTargetLength
        else {
            return nil
        }

        let contextIndent = String(targetLines[0].prefix { $0.isWhitespace })
        let declarationIndent = targetLines.dropFirst()
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { String($0.prefix { $0.isWhitespace }) } ?? "\(contextIndent)  "
        var replacementLines = targetLines
        replacementLines.insert("\(declarationIndent)let idx = \(expression)", at: 1)
        replacementLines = replacementLines.map { line in
            guard line.contains("Button(") else { return line }
            return line.replacingOccurrences(of: expression, with: "idx")
        }

        let replacement = replacementLines.joined(separator: "\n")
        guard replacement != target,
              replacement.count <= maximumReplacementLength
        else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceSection, target: target, replacement: replacement, section: nil)
    }

    static func ifConditionOperatorSpacingFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("expected '{' after 'if' condition")
            || diagnostic.message.contains("expected '{' after 'while' condition")
            || diagnostic.message.contains("expected 'else' after 'guard' condition")
            || diagnostic.message.contains("'<' is not a postfix unary operator"),
              let line = lineText(in: snippet, targetLine: diagnostic.line)
        else {
            return nil
        }

        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        guard trimmedLine.hasPrefix("if ")
            || trimmedLine.hasPrefix("else if ")
            || trimmedLine.hasPrefix("guard ")
            || trimmedLine.hasPrefix("while ")
        else {
            return nil
        }

        let pattern = #"(?<![<>=!])\s*(<=|>=|==|!=|<|>)\s*(?![<>=])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let updatedLine = regex.stringByReplacingMatches(
            in: line,
            range: NSRange(line.startIndex..<line.endIndex, in: line),
            withTemplate: " $1 "
        )
        guard updatedLine != line else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func malformedRangeIterationFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        let message = diagnostic.message
        guard message.contains("Bool")
            || message.contains("RandomAccessCollection")
            || message.contains("Sequence")
            || message.contains("generic parameter 'C' could not be inferred")
        else {
            return nil
        }
        guard let line = sourceLineText(in: source, targetLine: diagnostic.line)
                ?? lineText(in: snippet, targetLine: diagnostic.line),
              let updatedLine = malformedRangeIterationReplacement(for: line),
              updatedLine != line
        else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func powCoercionFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.localizedCaseInsensitiveContains("pow") || diagnostic.message.contains("cannot convert value of type 'Int' to expected argument type 'Double'") else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line), line.contains("pow(") else {
            return nil
        }

        let pattern = #"pow\((.+),\s*([^)]+)\)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
            let exponentRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }

        let exponent = String(line[exponentRange]).trimmingCharacters(in: .whitespaces)
        guard !exponent.hasPrefix("Double(") else {
            return nil
        }

        var updatedLine = line
        if let range = updatedLine.range(of: exponent) {
            updatedLine.replaceSubrange(range, with: "Double(\(exponent))")
        } else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func doubleRangeIterationFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("Range"),
              diagnostic.message.contains("Double.Stride"),
              let line = lineText(in: snippet, targetLine: diagnostic.line)
        else {
            return nil
        }

        let pattern = #"0\.\.<([A-Za-z_][A-Za-z0-9_]*)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
            let nameRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }

        let name = String(line[nameRange])
        let updatedLine = line.replacingOccurrences(of: "0..<\(name)", with: "0..<Int(\(name))")
        guard updatedLine != line else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }
}
