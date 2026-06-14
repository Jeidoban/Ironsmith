import Foundation

extension ContentViewRepairSupport {
    static func observedObjectStateFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("ObservedObject"),
              diagnostic.message.contains("ObservableObject"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("@ObservedObject")
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(of: "@ObservedObject", with: "@State")
        guard updatedLine != line else { return nil }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func duplicateBodyFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("invalid redeclaration of 'body'") else {
            return nil
        }

        let lines = source.components(separatedBy: .newlines)
        let bodyIndexes = lines.indices.filter { lines[$0].contains("var body: some View") }
        guard bodyIndexes.count > 1 else {
            return nil
        }

        let placeholderStart = bodyIndexes.first { index in
            let end = endOfBraceBlock(in: lines, startingAt: index)
            let bodyText = lines[index...end].joined(separator: "\n")
            return bodyText.contains("Text(\"Generated App\")") || bodyText.contains("Text(\"Generated Tool\")")
        }
        let duplicateStart = placeholderStart ?? bodyIndexes.last!
        let duplicateEnd = endOfBraceBlock(in: lines, startingAt: duplicateStart)
        let target = lines[duplicateStart...duplicateEnd].joined(separator: "\n")
        return ContentViewDeterministicEdit(operation: .replaceSection, target: target, replacement: "", section: nil)
    }

    static func weakSelfCaptureInValueViewFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("'weak' may only be applied"),
              diagnostic.message.contains("ContentView")
        else {
            return nil
        }

        let lines = source.components(separatedBy: .newlines)
        let diagnosticIndex = diagnostic.line - 1
        guard lines.indices.contains(diagnosticIndex),
              lines[diagnosticIndex].contains("[weak self]")
        else {
            return nil
        }

        let closureEnd = endOfBraceBlock(in: lines, startingAt: diagnosticIndex)
        let target = lines[diagnosticIndex...closureEnd].joined(separator: "\n")
        guard target.contains("[weak self]") else {
            return nil
        }

        let replacement = removeWeakSelfCaptureAndOptionalSelf(from: target)
        guard replacement != target,
              target.count <= maximumTargetLength,
              replacement.count <= maximumReplacementLength
        else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceSection, target: target, replacement: replacement, section: nil)
    }

    static func nonOptionalContentViewSelfFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("cannot use optional chaining on non-optional value of type 'ContentView'") else {
            return nil
        }

        let lines = source.components(separatedBy: .newlines)
        let diagnosticIndex = diagnostic.line - 1
        guard lines.indices.contains(diagnosticIndex) else {
            return nil
        }

        if let blockRange = enclosingRepairBlock(in: lines, containing: diagnosticIndex) {
            let target = lines[blockRange].joined(separator: "\n")
            let replacement = target.replacingOccurrences(of: "self?.", with: "self.")
            if replacement != target,
               target.count <= maximumTargetLength,
               replacement.count <= maximumReplacementLength {
                return ContentViewDeterministicEdit(operation: .replaceSection, target: target, replacement: replacement, section: nil)
            }
        }

        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("self?.")
        else {
            return nil
        }
        let replacement = line.replacingOccurrences(of: "self?.", with: "self.")
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: replacement, section: nil)
    }

    static func textFieldNumberFormatterStyleFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("argument passed to call that takes no arguments")
            || diagnostic.message.contains("cannot infer contextual base in reference to member")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("formatter: NumberFormatter(numberStyle:")
        else {
            return nil
        }
        let updatedLine = line.replacingOccurrences(
            of: #",\s*formatter:\s*NumberFormatter\(numberStyle:\s*\.[A-Za-z_][A-Za-z0-9_]*\)"#,
            with: ", format: .number",
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func nonOptionalGuardBindingFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("initializer for conditional binding must have Optional type"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("guard let ")
        else {
            return nil
        }

        if let conversionGuard = nonOptionalConversionGuardReplacement(for: line) {
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: conversionGuard, section: nil)
        }

        let directBindingPattern = #"guard\s+let\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\1,\s*"#
        if let regex = try? NSRegularExpression(pattern: directBindingPattern) {
            let updatedLine = regex.stringByReplacingMatches(
                in: line,
                range: NSRange(line.startIndex..<line.endIndex, in: line),
                withTemplate: "guard "
            )
            if updatedLine != line {
                return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
            }
        }

        return nil
    }

    static func mutableLetAssignmentFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("cannot assign to value:"),
              diagnostic.message.contains("is a 'let' constant"),
              let name = firstCapture(in: diagnostic.message, pattern: #"cannot assign to value: '([^']+)'"#)
        else {
            return nil
        }

        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"^(\s*)let\s+\#(escapedName)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let lines = source.components(separatedBy: .newlines)
        for line in lines {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.range.location != NSNotFound
            else {
                continue
            }
            let updatedLine = regex.stringByReplacingMatches(in: line, range: range, withTemplate: "$1var \(name)")
            guard updatedLine != line else {
                return nil
            }
            return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
        }

        return nil
    }

    static func frameArgumentOrderFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("argument 'width' must precede argument 'height'"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".frame(")
        else {
            return nil
        }

        let pattern = #"\.frame\(\s*height:\s*([^,\)]+),\s*width:\s*([^\)]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let fullRange = Range(match.range(at: 0), in: line),
              let heightRange = Range(match.range(at: 1), in: line),
              let widthRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }

        let height = String(line[heightRange]).trimmingCharacters(in: .whitespaces)
        let width = String(line[widthRange]).trimmingCharacters(in: .whitespaces)
        var updatedLine = line
        updatedLine.replaceSubrange(fullRange, with: ".frame(width: \(width), height: \(height))")
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func horizontalAlignmentFrameFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("cannot convert value of type 'HorizontalAlignment'"),
              diagnostic.message.contains("expected argument type 'Alignment'"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("alignment:")
        else {
            return nil
        }

        let pattern = #"alignment:\s*([A-Za-z_][A-Za-z0-9_\.]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let fullRange = Range(match.range(at: 0), in: line),
              let alignmentRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }

        let alignment = String(line[alignmentRange])
        var updatedLine = line
        updatedLine.replaceSubrange(fullRange, with: "alignment: Alignment(horizontal: \(alignment), vertical: .center)")
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func invalidAlignmentGuideOverlayFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        let isAlignmentGuideDiagnostic = diagnostic.message.contains("AlignmentGuide")
            || (diagnostic.message.contains("cannot infer contextual base")
                && snippet.text.contains("AlignmentGuide("))
        guard isAlignmentGuideDiagnostic else {
            return nil
        }

        let lines = snippet.text.components(separatedBy: .newlines)
        let diagnosticIndex = diagnostic.line - snippet.startLine
        guard lines.indices.contains(diagnosticIndex),
              let overlayStart = stride(from: diagnosticIndex, through: lines.startIndex, by: -1)
                  .first(where: { lines[$0].contains(".overlay(") }),
              let overlayEnd = endOfParenthesizedModifierCall(in: lines, startingAt: overlayStart)
        else {
            return nil
        }

        let target = lines[overlayStart...overlayEnd].joined(separator: "\n")
        guard target.contains("AlignmentGuide("),
              target.count <= maximumTargetLength
        else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceSection, target: target, replacement: "", section: nil)
    }

    static func intSliderBindingFix(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("BinaryFloatingPoint"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("Slider("),
              let variableName = firstCapture(in: line, pattern: #"value:\s*\$([A-Za-z_][A-Za-z0-9_]*)"#),
              source.contains("@State private var \(variableName): Int")
                || source.contains("@State private var \(variableName) = 0")
        else {
            return nil
        }

        let updatedLine: String
        if line.contains("{") {
            updatedLine = line.replacingOccurrences(of: "Slider(", with: "Stepper(")
        } else {
            let label = displayLabel(for: variableName)
            updatedLine = line.replacingOccurrences(
                of: #"Slider\(\s*value:\s*\$\#(variableName)\s*,"#,
                with: #"Stepper("\#(label): \(\#(variableName))", value: $\#(variableName),"#,
                options: .regularExpression
            )
        }

        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func misplacedFillModifierFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("has no member 'fill'"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains(".fill(")
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(of: ".fill(", with: ".background(")
        guard updatedLine != line else {
            return nil
        }

        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func unsupportedSystemColorFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("type 'Color' has no member"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("Color.system")
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(
            of: #"Color\.system[A-Za-z0-9_]+"#,
            with: "Color.gray.opacity(0.15)",
            options: .regularExpression
        )
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func nsColorOpacityFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("NSColor"),
              diagnostic.message.contains("has no member 'opacity'"),
              let line = lineText(in: snippet, targetLine: diagnostic.line),
              line.contains("NSColor."),
              line.contains(".opacity(")
        else {
            return nil
        }

        let updatedLine = line.replacingOccurrences(of: ".opacity(", with: ".withAlphaComponent(")
        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }

    static func stringClosedRangeAlphabetFix(
        for diagnostic: SwiftCompilerDiagnostic,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        guard diagnostic.message.contains("ClosedRange<String>")
            || diagnostic.message.contains("missing argument label")
            || diagnostic.message.contains("requires 'Bool'")
            || diagnostic.message.contains("for-in loop requires")
        else {
            return nil
        }
        guard let line = lineText(in: snippet, targetLine: diagnostic.line) else {
            return nil
        }

        var updatedLine = line
        if line.contains(#""A"..."ZZ""#) {
            let replacement = #"(0..<702).map { index in index < 26 ? String(UnicodeScalar(65 + index)!) : String(UnicodeScalar(65 + ((index / 26) - 1))!) + String(UnicodeScalar(65 + (index % 26))!) }"#
            if line.contains("Array(") {
                updatedLine = line.replacingOccurrences(
                    of: #"Array\(arrayLiteral:\s*"A"\.\.\."ZZ"\)"#,
                    with: replacement,
                    options: .regularExpression
                )
                updatedLine = updatedLine.replacingOccurrences(
                    of: #"Array\("A"\.\.\."ZZ"\)"#,
                    with: replacement,
                    options: .regularExpression
                )
            } else if line.contains(#"["A"..."ZZ"].flatMap"#) {
                updatedLine = line.replacingOccurrences(
                    of: #"\["A"\.\.\."ZZ"\]\.flatMap\s*\{\s*\$0\s*\}"#,
                    with: replacement,
                    options: .regularExpression
                )
            }
        } else if line.contains(#""A"..."Z""#) {
            if line.contains("Array(") {
                updatedLine = line.replacingOccurrences(
                    of: #"Array\("A"\.\.\."Z"\)"#,
                    with: #"(65...90).map { String(UnicodeScalar($0)!) }"#,
                    options: .regularExpression
                )
                updatedLine = updatedLine.replacingOccurrences(
                    of: #"Array\(arrayLiteral:\s*"A"\.\.\."Z"\)"#,
                    with: #"(65...90).map { String(UnicodeScalar($0)!) }"#,
                    options: .regularExpression
                )
            } else if line.range(of: #"\bfor\s+[A-Za-z_][A-Za-z0-9_]*\s+in\s+"A"\.\.\."Z""#, options: .regularExpression) != nil {
                updatedLine = line.replacingOccurrences(
                    of: #""A"\.\.\."Z""#,
                    with: #"(65...90).map({ Character(UnicodeScalar($0)!) })"#,
                    options: .regularExpression
                )
            }
        }

        guard updatedLine != line else {
            return nil
        }
        return ContentViewDeterministicEdit(operation: .replaceLine, target: line, replacement: updatedLine, section: nil)
    }
}
