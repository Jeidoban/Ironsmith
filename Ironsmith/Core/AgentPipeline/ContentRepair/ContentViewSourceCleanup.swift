import Foundation

enum ContentViewSourceCleanup {
    static func normalizedSource(_ response: String) -> String {
        let cleaned = ToolGenerationRuntimeContext.cleanedSource(response)
        let withoutScaffolding = removeGeneratedScaffolding(from: cleaned)
        let withoutCommonMacOSFootguns = normalizeCommonMacOSFootguns(in: withoutScaffolding)
        let withoutMemberScopeViewBlocks = removeMemberScopeViewBlocks(in: withoutCommonMacOSFootguns)
        let withViewScopedState = moveTopLevelStateIntoContentView(in: withoutMemberScopeViewBlocks)
        let scaffolded = scaffoldContentViewIfNeeded(in: withViewScopedState)
        return normalizeImports(in: scaffolded)
    }

    static func isPlaceholderScaffold(_ source: String) -> Bool {
        let lines = source.components(separatedBy: .newlines)
        guard let bodyStart = lines.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespaces) == "var body: some View {"
        }) else {
            return false
        }

        let bodyEnd = endOfBraceBlock(in: lines, startingAt: bodyStart)
        guard bodyEnd > bodyStart else {
            return false
        }

        let bodyLines = lines[(bodyStart + 1)..<bodyEnd]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return bodyLines == ["Text(\"Generated App\")"] || bodyLines == ["Text(\"Generated Tool\")"]
    }

    static func normalizeImports(in source: String) -> String {
        let lines = source.components(separatedBy: .newlines)
        var bodyLines: [String] = []
        var imports: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("import ") {
                imports.append(trimmed)
            } else {
                bodyLines.append(line)
            }
        }

        var modules = Set(imports.map { $0.replacingOccurrences(of: "import ", with: "") })
        modules.insert("SwiftUI")
        if containsAny(source, needles: ["NSPasteboard", "NSOpenPanel", "NSSavePanel", "NSWorkspace", "NSImage", "NSColor"]) {
            modules.insert("AppKit")
        }
        if containsAny(source, needles: ["URL", "Date", "FileManager", "Data", "Regex", "NumberFormatter", "DateFormatter", "JSONDecoder", "JSONEncoder", "UUID", "pow("]) {
            modules.insert("Foundation")
        }
        if containsAny(source, needles: ["UTType", "UniformTypeIdentifiers"]) {
            modules.insert("UniformTypeIdentifiers")
        }

        let orderedImports = ["SwiftUI", "Foundation", "AppKit", "UniformTypeIdentifiers"]
            .filter { modules.contains($0) }
            .map { "import \($0)" }
        let remainingImports = modules
            .subtracting(Set(["SwiftUI", "Foundation", "AppKit", "UniformTypeIdentifiers"]))
            .sorted()
            .map { "import \($0)" }
        let trimmedBody = bodyLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (orderedImports + remainingImports + ["", trimmedBody])
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeGeneratedScaffolding(from source: String) -> String {
        let lines = source.components(separatedBy: .newlines)
        var result: [String] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed == "```" || trimmed.hasPrefix("```swift") {
                index += 1
                continue
            }
            if trimmed == "@main" {
                index += 1
                continue
            }
            if trimmed.hasPrefix("#Preview") {
                index = skipBraceBlock(in: lines, startingAt: index)
                continue
            }
            if isForbiddenTopLevelBlock(trimmed) {
                index = skipBraceBlock(in: lines, startingAt: index)
                continue
            }
            result.append(lines[index])
            index += 1
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isForbiddenTopLevelBlock(_ trimmedLine: String) -> Bool {
        trimmedLine.contains(": App")
            || trimmedLine.contains("AppDelegate")
            || trimmedLine.contains("SceneDelegate")
            || trimmedLine.contains(": PreviewProvider")
    }

    private static func normalizeCommonMacOSFootguns(in source: String) -> String {
        var normalized = source

        normalized = normalized.replacingOccurrences(
            of: #"\bstruct\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*ObservableObject\s*\{"#,
            with: #"final class $1: ObservableObject {"#,
            options: .regularExpression
        )

        normalized = normalized.replacingOccurrences(
            of: #"Color\.system[A-Za-z0-9_]+"#,
            with: "Color.gray.opacity(0.15)",
            options: .regularExpression
        )

        normalized = normalized.replacingOccurrences(
            of: "Color(.windowBackground)",
            with: "Color(NSColor.windowBackgroundColor)"
        )

        normalized = normalized.replacingOccurrences(
            of: #"Text\(([A-Za-z_][A-Za-z0-9_\.]*),\s*style:\s*\.number\)"#,
            with: #"Text("\\($1)")"#,
            options: .regularExpression
        )

        if !normalized.contains("struct ContentView: View") {
            normalized = normalized.replacingOccurrences(
                of: #"\bstruct\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*View\s*\{"#,
                with: "struct ContentView: View {",
                options: [.regularExpression],
                range: normalized.startIndex..<normalized.endIndex
            )
        }

        let lines = normalized
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.contains(".keyboardType(")
                    && !trimmed.hasPrefix("keyboardType(")
                    && trimmed != "```"
                    && !trimmed.hasPrefix("```swift")
                else {
                    return nil
                }
                return normalizeBareSwiftUIModifierCall(line)
            }

        return lines.joined(separator: "\n")
    }

    private static func normalizeBareSwiftUIModifierCall(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix(".") else {
            return line
        }

        let modifierEndCandidates = [
            trimmed.firstIndex(of: "("),
            trimmed.firstIndex(of: "{")
        ].compactMap { $0 }
        guard let modifierEnd = modifierEndCandidates.min() else {
            return line
        }

        let name = String(trimmed[..<modifierEnd]).trimmingCharacters(in: .whitespaces)
        guard bareSwiftUIModifierNames.contains(name) else {
            return line
        }

        let indentationLength = line.prefix { $0 == " " || $0 == "\t" }.count
        let indentation = String(line.prefix(indentationLength))
        return "\(indentation).\(trimmed)"
    }

    private static let bareSwiftUIModifierNames: Set<String> = [
        "accessibilityHint",
        "accessibilityLabel",
        "accessibilityValue",
        "alert",
        "allowsHitTesting",
        "animation",
        "aspectRatio",
        "background",
        "baselineOffset",
        "badge",
        "blendMode",
        "blur",
        "bold",
        "border",
        "brightness",
        "buttonStyle",
        "clipShape",
        "clipped",
        "colorMultiply",
        "compositingGroup",
        "confirmationDialog",
        "contentShape",
        "contrast",
        "controlSize",
        "cornerRadius",
        "datePickerStyle",
        "disabled",
        "drawingGroup",
        "edgesIgnoringSafeArea",
        "fill",
        "fixedSize",
        "focusable",
        "focused",
        "font",
        "fontWeight",
        "foregroundColor",
        "foregroundStyle",
        "formStyle",
        "frame",
        "gesture",
        "help",
        "highPriorityGesture",
        "hoverEffect",
        "hueRotation",
        "imageScale",
        "ignoresSafeArea",
        "italic",
        "kerning",
        "keyboardShortcut",
        "labelStyle",
        "labelsHidden",
        "layoutPriority",
        "lineLimit",
        "listStyle",
        "mask",
        "menuStyle",
        "minimumScaleFactor",
        "modifier",
        "multilineTextAlignment",
        "navigationTitle",
        "offset",
        "onAppear",
        "onChange",
        "onDisappear",
        "onReceive",
        "onSubmit",
        "opacity",
        "overlay",
        "padding",
        "pickerStyle",
        "popover",
        "position",
        "presentationDetents",
        "refreshable",
        "resizable",
        "rotation3DEffect",
        "rotationEffect",
        "safeAreaInset",
        "saturation",
        "scaleEffect",
        "scaledToFill",
        "scaledToFit",
        "scrollContentBackground",
        "scrollDisabled",
        "scrollIndicators",
        "searchable",
        "shadow",
        "sheet",
        "simultaneousGesture",
        "stroke",
        "strokeBorder",
        "symbolRenderingMode",
        "tabViewStyle",
        "task",
        "textFieldStyle",
        "textSelection",
        "tracking",
        "tint",
        "toggleStyle",
        "toolbar",
        "transition",
        "trim",
        "truncationMode",
        "underline",
        "zIndex"
    ]

    private static func removeMemberScopeViewBlocks(in source: String) -> String {
        guard source.contains("struct ContentView: View") else {
            return source
        }

        let lines = source.components(separatedBy: .newlines)
        var result: [String] = []
        var index = 0
        var isInsideContentView = false
        var depth = 0
        var currentSection = FragmentSection.unknown

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.contains("struct ContentView: View") {
                isInsideContentView = true
                result.append(line)
                depth += braceDelta(in: line)
                index += 1
                continue
            }

            if isInsideContentView, depth <= 1 {
                if trimmed == "// MARK: - Body" {
                    currentSection = .body
                } else if trimmed == "// MARK: - Actions" {
                    currentSection = .actions
                } else if trimmed == "// MARK: - Helpers" {
                    currentSection = .helpers
                } else if trimmed == "// MARK: - State" {
                    currentSection = .state
                }

                if currentSection != .body,
                   isLikelyViewExpression(trimmed) {
                    index = skipBraceBlock(in: lines, startingAt: index)
                    continue
                }
            }

            result.append(line)
            if isInsideContentView {
                depth += braceDelta(in: line)
                if depth <= 0 {
                    isInsideContentView = false
                    currentSection = .unknown
                }
            }
            index += 1
        }

        return result.joined(separator: "\n")
    }

    private static func scaffoldContentViewIfNeeded(in source: String) -> String {
        guard !source.contains("struct ContentView: View") else {
            return source
        }

        let lines = source.components(separatedBy: .newlines)
        let bodyCandidate = lines
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("import ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard bodyCandidate.contains("@State")
            || bodyCandidate.contains("// MARK: - Body")
            || bodyCandidate.components(separatedBy: .newlines).contains(where: { isLikelyViewExpression($0.trimmingCharacters(in: .whitespaces)) })
        else {
            return source
        }

        var stateLines: [String] = []
        var bodyLines: [String] = []
        var actionLines: [String] = []
        var helperLines: [String] = []
        var section: FragmentSection = .unknown

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("import ") {
                continue
            }
            if trimmed == "// MARK: - State" {
                section = .state
                continue
            }
            if trimmed == "// MARK: - Body" {
                section = .body
                continue
            }
            if trimmed == "// MARK: - Actions" {
                section = .actions
                continue
            }
            if trimmed == "// MARK: - Helpers" {
                section = .helpers
                continue
            }
            if trimmed.isEmpty {
                appendBlankLine(to: section, stateLines: &stateLines, bodyLines: &bodyLines, actionLines: &actionLines, helperLines: &helperLines)
                continue
            }

            if trimmed.hasPrefix("@State") {
                stateLines.append(trimmed)
                section = .state
                continue
            }
            if let stateLine = topLevelStateDeclaration(from: trimmed, source: source) {
                stateLines.append(stateLine)
                section = .state
                continue
            }
            if isTopLevelHelperStart(trimmed) {
                section = .helpers
            } else if section == .unknown, isLikelyViewExpression(trimmed) {
                section = .body
            }

            switch section {
            case .state:
                stateLines.append(trimmed)
            case .body:
                bodyLines.append(trimmed)
            case .actions:
                actionLines.append(trimmed)
            case .helpers:
                helperLines.append(trimmed)
            case .unknown:
                bodyLines.append(trimmed)
                section = .body
            }
        }

        trimEmptyEdges(&stateLines)
        trimEmptyEdges(&bodyLines)
        trimEmptyEdges(&actionLines)
        trimEmptyEdges(&helperLines)

        var scaffold: [String] = ["struct ContentView: View {"]
        scaffold.append("    // MARK: - State")
        if stateLines.isEmpty {
            scaffold.append("    @State private var input = \"\"")
        } else {
            scaffold.append(contentsOf: indented(stateLines, by: "    "))
        }
        scaffold.append("")
        scaffold.append("    // MARK: - Body")
        scaffold.append("    var body: some View {")
        if bodyLines.isEmpty {
            scaffold.append("        Text(\"Generated App\")")
        } else {
            scaffold.append(contentsOf: indented(bodyLines, by: "        "))
        }
        scaffold.append("    }")
        scaffold.append("")
        scaffold.append("    // MARK: - Actions")
        scaffold.append(contentsOf: indented(actionLines, by: "    "))
        scaffold.append("")
        scaffold.append("    // MARK: - Helpers")
        scaffold.append(contentsOf: indented(helperLines, by: "    "))
        scaffold.append("}")

        return scaffold.joined(separator: "\n")
    }

    private static func moveTopLevelStateIntoContentView(in source: String) -> String {
        guard source.contains("struct ContentView: View") else {
            return source
        }

        let lines = source.components(separatedBy: .newlines)
        var remainingLines: [String] = []
        var stateLines: [String] = []
        var hasSeenContentView = false
        var topLevelDepth = 0

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("struct ContentView: View") {
                hasSeenContentView = true
                remainingLines.append(line)
                continue
            }

            if !hasSeenContentView, topLevelDepth == 0 {
                if trimmed == "// MARK: - State" {
                    continue
                }
                if trimmed.hasPrefix("@State") {
                    stateLines.append(trimmed)
                    continue
                }
                if let stateLine = topLevelStateDeclaration(from: trimmed, source: source) {
                    stateLines.append(stateLine)
                    continue
                }
            }

            remainingLines.append(line)
            if !hasSeenContentView {
                topLevelDepth = max(0, topLevelDepth + braceDelta(in: line))
            }
        }

        trimEmptyEdges(&stateLines)
        guard !stateLines.isEmpty,
              let contentViewIndex = remainingLines.firstIndex(where: { $0.contains("struct ContentView: View") })
        else {
            return source
        }

        var updatedLines = remainingLines
        let nextNonEmptyIndex = updatedLines[(contentViewIndex + 1)...].firstIndex {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if let nextNonEmptyIndex,
           updatedLines[nextNonEmptyIndex].trimmingCharacters(in: .whitespaces) == "// MARK: - State" {
            updatedLines.insert(contentsOf: indented(stateLines, by: "  "), at: nextNonEmptyIndex + 1)
        } else {
            updatedLines.insert(contentsOf: ["  // MARK: - State"] + indented(stateLines, by: "  ") + [""], at: contentViewIndex + 1)
        }

        return updatedLines.joined(separator: "\n")
    }

    private enum FragmentSection {
        case unknown
        case state
        case body
        case actions
        case helpers
    }

    private static func appendBlankLine(
        to section: FragmentSection,
        stateLines: inout [String],
        bodyLines: inout [String],
        actionLines: inout [String],
        helperLines: inout [String]
    ) {
        switch section {
        case .state:
            stateLines.append("")
        case .body:
            bodyLines.append("")
        case .actions:
            actionLines.append("")
        case .helpers:
            helperLines.append("")
        case .unknown:
            break
        }
    }

    private static func topLevelStateDeclaration(from trimmedLine: String, source: String) -> String? {
        guard trimmedLine.hasPrefix("var ") else {
            return nil
        }
        guard firstCapture(in: trimmedLine, pattern: #"^var\s+([A-Za-z_][A-Za-z0-9_]*)\b"#) != nil,
              isSimpleStoredVarDeclaration(trimmedLine)
        else {
            return nil
        }

        return "@State private \(trimmedLine)"
    }

    private static func isSimpleStoredVarDeclaration(_ trimmedLine: String) -> Bool {
        guard !trimmedLine.contains("{"),
              !trimmedLine.contains("}"),
              !trimmedLine.contains("->"),
              trimmedLine.contains("=") || trimmedLine.contains(":")
        else {
            return false
        }
        return true
    }

    private static func isLikelyViewExpression(_ trimmedLine: String) -> Bool {
        [
            "VStack", "HStack", "ZStack", "Form", "ScrollView", "List", "Text(",
            "TextField(", "Button(", "Group", "NavigationStack", "NavigationSplitView"
        ].contains { trimmedLine.hasPrefix($0) }
    }

    private static func isTopLevelHelperStart(_ trimmedLine: String) -> Bool {
        trimmedLine.hasPrefix("func ")
            || trimmedLine.hasPrefix("private func ")
            || trimmedLine.hasPrefix("static func ")
            || trimmedLine.hasPrefix("private var ")
            || trimmedLine.hasPrefix("var ")
            || trimmedLine.hasPrefix("struct ")
            || trimmedLine.hasPrefix("final class ")
            || trimmedLine.hasPrefix("class ")
            || trimmedLine.hasPrefix("enum ")
    }

    private static func indented(_ lines: [String], by indentation: String) -> [String] {
        lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "" : "\(indentation)\(trimmed)"
        }
    }

    private static func trimEmptyEdges(_ lines: inout [String]) {
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }
    }

    private static func skipBraceBlock(in lines: [String], startingAt startIndex: Int) -> Int {
        var index = startIndex
        var depth = 0
        var sawBrace = false

        while index < lines.count {
            for character in lines[index] {
                if character == "{" {
                    depth += 1
                    sawBrace = true
                } else if character == "}" {
                    depth -= 1
                    if sawBrace && depth <= 0 {
                        return index + 1
                    }
                }
            }

            index += 1
            if !sawBrace {
                return index
            }
        }

        return index
    }

    private static func endOfBraceBlock(in lines: [String], startingAt startIndex: Int) -> Int {
        var depth = 0
        var sawOpeningBrace = false

        for index in startIndex..<lines.count {
            for character in lines[index] {
                if character == "{" {
                    depth += 1
                    sawOpeningBrace = true
                } else if character == "}" {
                    depth -= 1
                    if sawOpeningBrace && depth <= 0 {
                        return index
                    }
                }
            }
        }

        return startIndex
    }

    private static func braceDelta(in line: String) -> Int {
        var delta = 0
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
            if character == "{" {
                delta += 1
            } else if character == "}" {
                delta -= 1
            }
        }
        return delta
    }

    private static func containsAny(_ source: String, needles: [String]) -> Bool {
        needles.contains { source.contains($0) }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
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
