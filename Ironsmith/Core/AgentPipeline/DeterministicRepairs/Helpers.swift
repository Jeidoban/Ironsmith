import Foundation

extension ContentViewRepairSupport {
    static func removeWeakSelfCaptureAndOptionalSelf(from text: String) -> String {
        let capturePattern = #"\{\s*\[weak\s+self\]\s*"#
        let withoutCapture: String
        if let regex = try? NSRegularExpression(pattern: capturePattern) {
            withoutCapture = regex.stringByReplacingMatches(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: "{ "
            )
        } else {
            withoutCapture = text.replacingOccurrences(of: "[weak self] ", with: "")
        }
        return withoutCapture.replacingOccurrences(of: "self?.", with: "self.")
    }

    static func enclosingRepairBlock(
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
            let target = lines[range].joined(separator: "\n")
            guard target.contains("self?.") else {
                continue
            }

            fallback = fallback ?? range
            let trimmedStart = lines[startIndex].trimmingCharacters(in: .whitespaces)
            if !isDeterministicRepairControlFlowBlockStart(trimmedStart) {
                preferred = preferred ?? range
            }
        }

        return preferred ?? fallback
    }

    static func isDeterministicRepairControlFlowBlockStart(_ line: String) -> Bool {
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

    static func wrapSimpleAssignmentExpression(in line: String, with wrapper: String) -> String? {
        guard let equalsIndex = line.firstIndex(of: "=") else {
            return nil
        }
        let prefix = line[..<line.index(after: equalsIndex)]
        let expression = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
        guard !expression.contains(" "), !expression.contains("("), !expression.contains(")"), !expression.isEmpty else {
            return nil
        }

        return "\(prefix) \(wrapper)(\(expression))"
    }

    static func sourceLineText(in source: String, targetLine: Int) -> String? {
        let lines = source.components(separatedBy: .newlines)
        let index = targetLine - 1
        guard lines.indices.contains(index) else {
            return nil
        }
        return lines[index]
    }

    static func deterministicRepairIndentation(of line: String) -> String {
        String(line.prefix { $0.isWhitespace })
    }

    static func storedPropertyIndent(in blockLines: [String]) -> String {
        if let propertyLine = blockLines.dropFirst().first(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ")
        }) {
            return deterministicRepairIndentation(of: propertyLine)
        }

        guard let structLine = blockLines.first else {
            return "  "
        }
        return deterministicRepairIndentation(of: structLine) + "  "
    }

    static func storedPropertyType(
        for member: String,
        typeName: String,
        in blockText: String,
        source: String
    ) -> String? {
        let escapedMember = NSRegularExpression.escapedPattern(for: member)
        if let type = firstCapture(in: blockText, pattern: #"\b\#(escapedMember)\s*:\s*([^,\)]+)"#) {
            return type
                .split(separator: "=", maxSplits: 1)
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        if let expression = assignmentExpression(for: member, in: blockText),
           let type = inferredType(forExpression: expression, member: member, source: source) {
            return type
        }
        if let type = constructorArgumentType(for: member, typeName: typeName, source: source) {
            return type
        }
        if let type = memberUsageType(for: member, source: source) {
            return type
        }
        return nil
    }

    static func assignedMemberNames(in blockText: String) -> [String] {
        let pattern = #"\bself\.([A-Za-z_][A-Za-z0-9_]*)\s*="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return regex.matches(in: blockText, range: NSRange(blockText.startIndex..<blockText.endIndex, in: blockText)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: blockText) else {
                return nil
            }
            return String(blockText[range])
        }
    }

    static func assignmentExpression(for member: String, in blockText: String) -> String? {
        let escapedMember = NSRegularExpression.escapedPattern(for: member)
        return firstCapture(in: blockText, pattern: #"\bself\.\#(escapedMember)\s*=\s*([^\n]+)"#)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func constructorArgumentType(
        for member: String,
        typeName: String,
        source: String
    ) -> String? {
        let escapedTypeName = NSRegularExpression.escapedPattern(for: typeName)
        let pattern = #"\b\#(escapedTypeName)\s*\(([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let matches = regex.matches(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source))
        let inferredTypes = Set(matches.compactMap { match -> String? in
            guard let argumentsRange = Range(match.range(at: 1), in: source),
                  let expression = argumentExpression(for: member, in: String(source[argumentsRange]))
            else {
                return nil
            }
            return inferredType(forExpression: expression, member: member, source: source)
        })
        return inferredTypes.count == 1 ? inferredTypes.first : nil
    }

    static func argumentExpression(for member: String, in arguments: String) -> String? {
        let escapedMember = NSRegularExpression.escapedPattern(for: member)
        let pattern = #"(?:^|,)\s*\#(escapedMember)\s*:\s*([^,]+)"#
        return firstCapture(in: arguments, pattern: pattern)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func inferredType(
        forExpression expression: String,
        member: String,
        source: String
    ) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "true" || trimmed == "false" {
            return "Bool"
        }
        if trimmed == "nil" {
            return optionalTypeForNilMember(member)
        }
        if trimmed.range(of: #"^#?""#, options: .regularExpression) != nil {
            return "String"
        }
        if trimmed.range(of: #"^-?\d+$"#, options: .regularExpression) != nil {
            return "Int"
        }
        if trimmed.range(of: #"^-?\d+\.\d+$"#, options: .regularExpression) != nil {
            return "Double"
        }
        if trimmed.range(of: #"\bCGFloat\s*(?:\.|\()"#, options: .regularExpression) != nil {
            return "CGFloat"
        }
        if let arithmeticType = arithmeticExpressionDeclaredType(
            forExpression: trimmed,
            member: member,
            source: source
        ) {
            return arithmeticType
        }
        if trimmed == "Date()" || trimmed.hasPrefix("Date(") {
            return "Date"
        }
        if trimmed == "UUID()" || trimmed.hasPrefix("UUID(") {
            return "UUID"
        }
        if let elementType = firstCapture(in: trimmed, pattern: #"\.map\s*\{[\s\S]*\b([A-Z][A-Za-z0-9_]*)\s*\("#) {
            return "[\(elementType)]"
        }
        if trimmed.contains(".trimmingCharacters(")
            || trimmed.contains(".lowercased()")
            || trimmed.contains(".uppercased()")
        {
            return "String"
        }
        if trimmed.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
           trimmed != member {
            return declaredType(for: trimmed, in: source)
        }
        return nil
    }

    static func arithmeticExpressionDeclaredType(
        forExpression expression: String,
        member: String,
        source: String
    ) -> String? {
        guard expression.range(of: #"[+\-*/]"#, options: .regularExpression) != nil,
              let regex = try? NSRegularExpression(pattern: #"\b[A-Za-z_][A-Za-z0-9_]*\b"#)
        else {
            return nil
        }

        let ignoredIdentifiers: Set<String> = [member, "CGFloat", "Double", "Int", "max", "min"]
        let identifiers = regex.matches(
            in: expression,
            range: NSRange(expression.startIndex..<expression.endIndex, in: expression)
        ).compactMap { match -> String? in
            guard let range = Range(match.range, in: expression) else { return nil }
            let identifier = String(expression[range])
            return ignoredIdentifiers.contains(identifier) ? nil : identifier
        }

        let declaredTypes = Set(identifiers.compactMap { declaredType(for: $0, in: source) })
        if declaredTypes.contains("CGFloat") {
            return "CGFloat"
        }
        if declaredTypes.contains("Double") {
            return "Double"
        }
        return nil
    }

    static func declaredType(for symbol: String, in source: String) -> String? {
        let escapedSymbol = NSRegularExpression.escapedPattern(for: symbol)
        if let explicitType = firstCapture(
            in: source,
            pattern: #"(?m)^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*(?:private\s+)?(?:let|var)\s+\#(escapedSymbol)\s*:\s*([^=\n]+)"#
        ) {
            return explicitType.trimmingCharacters(in: .whitespaces)
        }
        if let initializer = firstCapture(
            in: source,
            pattern: #"(?m)^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*(?:private\s+)?(?:let|var)\s+\#(escapedSymbol)\s*=\s*([^\n]+)"#
        ) {
            return inferredType(forExpression: initializer, member: symbol, source: source)
        }
        return nil
    }

    static func memberUsageType(for member: String, source: String) -> String? {
        let escapedMember = NSRegularExpression.escapedPattern(for: member)
        if source.range(of: #"\.\#(escapedMember)\.toggle\(\)"#, options: .regularExpression) != nil
            || source.range(of: #"\.\#(escapedMember)\s*\?"#, options: .regularExpression) != nil
            || source.range(of: #"!\s*[A-Za-z_][A-Za-z0-9_]*\.\#(escapedMember)\b"#, options: .regularExpression) != nil
            || source.range(of: #"\{\s*\$0\.\#(escapedMember)\s*\}"#, options: .regularExpression) != nil
        {
            return "Bool"
        }

        if source.range(of: #"\.\#(escapedMember)\s*(?:\+=|-=|[+\-*/])"#, options: .regularExpression) != nil
            || source.range(of: #"\.\#(escapedMember)\s*=\s*max\("#, options: .regularExpression) != nil
        {
            return "Int"
        }

        if source.range(of: #"\bText\([^)\n]*\.\#(escapedMember)\b"#, options: .regularExpression) != nil,
           stringLikeMemberName(member) {
            return "String"
        }
        return optionalTypeForNilMember(member)
    }

    static func optionalTypeForNilMember(_ member: String) -> String? {
        member.lowercased().contains("date") ? "Date?" : nil
    }

    static func stringLikeMemberName(_ member: String) -> Bool {
        let lowered = member.lowercased()
        return ["name", "title", "body", "content", "text", "label"].contains(lowered)
    }

    static func storedPropertyInsertionIndex(in blockLines: [String]) -> Int {
        var insertionIndex = min(1, blockLines.count)
        for index in blockLines.indices.dropFirst() {
            let trimmed = blockLines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") {
                insertionIndex = index + 1
            } else if trimmed.hasPrefix("init(") || trimmed.hasPrefix("static ") || trimmed.hasPrefix("func ") {
                break
            }
        }
        return insertionIndex
    }

    static func malformedRangeIterationReplacement(for line: String) -> String? {
        if let range = forEachFirstArgumentRange(in: line),
           let replacement = malformedRangeExpressionReplacement(for: String(line[range])) {
            var updatedLine = line
            updatedLine.replaceSubrange(range, with: replacement)
            return updatedLine
        }

        if let range = forInSequenceExpressionRange(in: line),
           let replacement = malformedRangeExpressionReplacement(for: String(line[range])) {
            var updatedLine = line
            updatedLine.replaceSubrange(range, with: replacement)
            return updatedLine
        }

        if let range = parenthesizedMapExpressionRange(in: line),
           let replacement = malformedRangeExpressionReplacement(for: String(line[range])) {
            var updatedLine = line
            updatedLine.replaceSubrange(range, with: replacement)
            return updatedLine
        }

        return nil
    }

    static func forEachFirstArgumentRange(in line: String) -> Range<String.Index>? {
        guard let callRange = line.range(of: "ForEach(") else {
            return nil
        }

        let start = callRange.upperBound
        var depth = 0
        var index = start
        while index < line.endIndex {
            let character = line[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                if depth == 0 {
                    return nil
                }
                depth -= 1
            } else if character == ",", depth == 0 {
                return trimmedRange(start..<index, in: line)
            }
            index = line.index(after: index)
        }
        return nil
    }

    static func forInSequenceExpressionRange(in line: String) -> Range<String.Index>? {
        let pattern = #"\bfor\s+(?:_|[A-Za-z_][A-Za-z0-9_]*)\s+in\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let matchRange = Range(match.range, in: line)
        else {
            return nil
        }

        let start = matchRange.upperBound
        var depth = 0
        var index = start
        while index < line.endIndex {
            let character = line[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if character == "{", depth == 0 {
                return trimmedRange(start..<index, in: line)
            }
            index = line.index(after: index)
        }
        return trimmedRange(start..<line.endIndex, in: line)
    }

    static func parenthesizedMapExpressionRange(in line: String) -> Range<String.Index>? {
        guard let mapRange = line.range(of: ").map"),
              let openIndex = line[..<mapRange.lowerBound].lastIndex(of: "(")
        else {
            return nil
        }
        let expressionStart = line.index(after: openIndex)
        return trimmedRange(expressionStart..<mapRange.lowerBound, in: line)
    }

    static func malformedRangeExpressionReplacement(for expression: String) -> String? {
        let trimmedExpression = expression.trimmingCharacters(in: .whitespaces)
        var depth = 0
        var index = trimmedExpression.startIndex
        while index < trimmedExpression.endIndex {
            let character = trimmedExpression[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth = max(0, depth - 1)
            } else if character == "<", depth == 0 {
                let previous = index > trimmedExpression.startIndex ? trimmedExpression[trimmedExpression.index(before: index)] : nil
                let next = trimmedExpression.index(after: index) < trimmedExpression.endIndex
                    ? trimmedExpression[trimmedExpression.index(after: index)]
                    : nil
                guard previous != "<", previous != "=", next != "<", next != "=" else {
                    return nil
                }

                let lowerBound = trimmedExpression[..<index].trimmingCharacters(in: .whitespaces)
                let upperStart = trimmedExpression.index(after: index)
                let upperBound = trimmedExpression[upperStart...].trimmingCharacters(in: .whitespaces)
                guard lowerBound.range(of: #"^-?\d+$"#, options: .regularExpression) != nil,
                      !upperBound.isEmpty
                else {
                    return nil
                }
                return "\(lowerBound)..<\(upperBound)"
            }
            index = trimmedExpression.index(after: index)
        }
        return nil
    }

    static func trimmedRange(_ range: Range<String.Index>, in line: String) -> Range<String.Index> {
        var lowerBound = range.lowerBound
        var upperBound = range.upperBound
        while lowerBound < upperBound, line[lowerBound].isWhitespace {
            lowerBound = line.index(after: lowerBound)
        }
        while lowerBound < upperBound {
            let previous = line.index(before: upperBound)
            guard line[previous].isWhitespace else { break }
            upperBound = previous
        }
        return lowerBound..<upperBound
    }

    static func nonOptionalConversionGuardReplacement(for line: String) -> String? {
        let pattern = #"^(\s*)guard\s+(.+)\s+else\s+\{\s*return\s*\}\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)),
              let indentationRange = Range(match.range(at: 1), in: line),
              let clauseRange = Range(match.range(at: 2), in: line)
        else {
            return nil
        }

        let indentation = String(line[indentationRange])
        let clauses = String(line[clauseRange])
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !clauses.isEmpty else {
            return nil
        }

        var assignments: [String] = []
        var sameNameConditions: [String] = []
        for clause in clauses {
            guard let lhs = firstCapture(in: clause, pattern: #"^let\s+([A-Za-z_][A-Za-z0-9_]*)\s*="#),
                  let rhs = firstCapture(in: clause, pattern: #"=\s*(?:Double|Int)\(([A-Za-z_][A-Za-z0-9_]*)\)\s*$"#)
            else {
                return nil
            }

            if lhs == rhs {
                sameNameConditions.append("\(lhs) != 0")
            } else {
                assignments.append("\(indentation)let \(lhs) = \(rhs)")
            }
        }

        if !assignments.isEmpty, !sameNameConditions.isEmpty {
            return nil
        }
        if !assignments.isEmpty {
            return assignments.joined(separator: "\n")
        }
        return "\(indentation)guard \(sameNameConditions.joined(separator: ", ")) else { return }"
    }

    static func numericStateDeclarationExists(for symbol: String, in source: String) -> Bool {
        let escapedSymbol = NSRegularExpression.escapedPattern(for: symbol)
        return source.range(
            of: #"@State\b[^\n]*\b\#(escapedSymbol)\s*:\s*(?:Double|Int)\b"#,
            options: .regularExpression
        ) != nil
    }

    static func stateDeclarationExists(for symbol: String, in source: String) -> Bool {
        let escapedSymbol = NSRegularExpression.escapedPattern(for: symbol)
        return source.range(
            of: #"@State\b[^\n]*\b\#(escapedSymbol)\b"#,
            options: .regularExpression
        ) != nil
    }

    static func stringStateDeclarationExists(for symbol: String, in source: String) -> Bool {
        let escapedSymbol = NSRegularExpression.escapedPattern(for: symbol)
        return source.range(
            of: #"@State\b[^\n]*\b\#(escapedSymbol)\s*(?::\s*String\b|=\s*"[^"]*")"#,
            options: .regularExpression
        ) != nil
    }

    static func stateInitializerLiteral(for symbol: String, in source: String) -> String? {
        let escapedSymbol = NSRegularExpression.escapedPattern(for: symbol)
        let pattern = #"@State\b[^\n]*\b\#(escapedSymbol)\s*(?::\s*[A-Za-z0-9_<>\.\[\]: ]+)?=\s*([^,\n]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)),
              let literalRange = Range(match.range(at: 1), in: source)
        else {
            return nil
        }

        let literal = String(source[literalRange]).trimmingCharacters(in: .whitespaces)
        guard !literal.isEmpty,
              literal.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) == nil,
              !literal.contains("$")
        else {
            return nil
        }
        return literal
    }

    static func declarationExists(for symbol: String, in source: String) -> Bool {
        let escapedSymbol = NSRegularExpression.escapedPattern(for: symbol)
        return source.range(
            of: #"\b(?:let|var|func)\s+\#(escapedSymbol)\b"#,
            options: .regularExpression
        ) != nil
    }

    static func parenthesisBalance(in line: String) -> Int {
        var balance = 0
        var isEscaped = false
        var isInsideString = false
        for character in line {
            if isEscaped {
                isEscaped = false
                continue
            }
            if character == "\\" {
                isEscaped = true
                continue
            }
            if character == "\"" {
                isInsideString.toggle()
                continue
            }
            guard !isInsideString else {
                continue
            }
            if character == "(" {
                balance += 1
            } else if character == ")" {
                balance -= 1
            }
        }
        return balance
    }

    static func repeatedContextMenuIndexExpression(in text: String) -> String? {
        let pattern = #"Button\([^\n]*\)\s*\{\s*[A-Za-z_][A-Za-z0-9_]*\(at:\s*([^)]+)\)\s*\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        var counts: [String: Int] = [:]
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        for match in matches {
            guard let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            let expression = String(text[range]).trimmingCharacters(in: .whitespaces)
            guard expression != "idx",
                  expression.count <= 80,
                  expression.contains("*") || expression.contains("+")
            else {
                continue
            }
            counts[expression, default: 0] += 1
        }

        return counts
            .filter { $0.value >= 2 }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .first?
            .key
    }

    static func endOfParenthesizedModifierCall(
        in lines: [String],
        startingAt startIndex: Int
    ) -> Int? {
        guard lines.indices.contains(startIndex) else {
            return nil
        }

        var depth = 0
        var hasOpened = false
        for index in startIndex..<lines.count {
            let delta = parenthesisBalance(in: lines[index])
            if delta > 0 {
                hasOpened = true
            }
            depth += delta
            if hasOpened, depth <= 0 {
                return index
            }
        }
        return nil
    }

    static func displayLabel(for identifier: String) -> String {
        var words: [String] = []
        var current = ""
        for character in identifier {
            if character.isUppercase, !current.isEmpty {
                words.append(current)
                current = String(character)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty {
            words.append(current)
        }
        return words.joined(separator: " ").capitalized
    }
}
