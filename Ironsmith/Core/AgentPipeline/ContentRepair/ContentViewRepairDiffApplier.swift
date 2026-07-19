import Foundation

extension ContentViewRepairSupport {
    struct UnifiedDiffValidationError: LocalizedError, Equatable {
        enum Kind: Equatable {
            case emptyDiff
            case tooLong
            case tooManyHunks
            case malformedDiff
            case wrongFile
            case noChanges
            case missingContext
            case ambiguousContext
        }

        let kind: Kind
        let reason: String

        var errorDescription: String? {
            "The repair model returned an invalid diff. \(reason)"
        }

        var isStaleContextFailure: Bool {
            kind == .missingContext
        }
    }

    struct CompletedDiffApplication: Equatable {
        let source: String
        let appliedHunkCount: Int
    }

    static func applyValidatedDiff(
        _ rawDiff: String,
        to source: String,
        maximumHunks: Int,
        maximumCharacters: Int = maximumPatchCharacters
    ) throws -> String {
        let diff = sanitizedDiffSummary(rawDiff)
        guard !diff.isEmpty else {
            throw invalidDiff(kind: .emptyDiff, reason: "diff is empty")
        }
        guard diff.count <= maximumCharacters else {
            throw invalidDiff(
                kind: .tooLong,
                reason: "diff exceeds maximum length of \(maximumCharacters) characters"
            )
        }

        let hunks = try parseUnifiedDiff(diff)
        return try apply(hunks, to: source, maximumHunks: maximumHunks)
    }

    static func applyCompletedDiffHunks(
        _ rawDiff: String,
        to source: String,
        maximumHunks: Int,
        maximumCharacters: Int = maximumPatchCharacters
    ) throws -> CompletedDiffApplication? {
        let diff = sanitizedDiffSummary(rawDiff)
        guard !diff.isEmpty else { return nil }
        guard diff.count <= maximumCharacters else {
            throw invalidDiff(
                kind: .tooLong,
                reason: "diff exceeds maximum length of \(maximumCharacters) characters"
            )
        }

        let hunks = try parseUnifiedDiff(diff).filter(\.isSafeToApplyFromInterruptedDraft)
        guard !hunks.isEmpty else { return nil }
        return CompletedDiffApplication(
            source: try apply(hunks, to: source, maximumHunks: maximumHunks),
            appliedHunkCount: hunks.count
        )
    }

    static func sanitizedDiffSummary(_ rawDiff: String) -> String {
        var cleaned = stripVisibleDiffThinking(
            from: rawDiff.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        cleaned = fencedDiffBody(from: cleaned) ?? diffEnvelope(from: cleaned)

        let lines = cleaned.components(separatedBy: .newlines).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.hasPrefix("```")
                && !isDiffProseLine(trimmed)
                && trimmed != "*** Begin Patch"
                && trimmed != "*** End Patch"
                && trimmed != "*** End of File"
        }
        return removingCommonIndentation(from: lines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct UnifiedDiffHunk: Equatable {
        var lines: [String]
        var endedAtNextHunk: Bool

        var containsChangedLine: Bool {
            lines.contains { $0.hasPrefix("+") || $0.hasPrefix("-") }
        }

        var isSafeToApplyFromInterruptedDraft: Bool {
            // EOF is not a reliable completion marker for a streamed response: a
            // truncated added line can still satisfy the model's declared counts.
            endedAtNextHunk
        }
    }

    private enum UnifiedDiffLine: Equatable {
        case context(String)
        case removal(String)
        case addition(String)

        var existingLine: ExistingDiffLine? {
            switch self {
            case .context(let content):
                return ExistingDiffLine(content: content, isRemoval: false)
            case .removal(let content):
                return ExistingDiffLine(content: content, isRemoval: true)
            case .addition:
                return nil
            }
        }

        var proposedLine: String? {
            switch self {
            case .context(let content), .addition(let content):
                return content
            case .removal:
                return nil
            }
        }
    }

    private struct ExistingDiffLine: Equatable {
        let content: String
        let isRemoval: Bool
    }

    private static func parseUnifiedDiff(_ diff: String) throws -> [UnifiedDiffHunk] {
        let lines = diff.components(separatedBy: .newlines)
        try validateDiffFileMetadata(in: lines)

        var hunks: [UnifiedDiffHunk] = []
        var current: UnifiedDiffHunk?

        for line in lines {
            if line.hasPrefix("@@") {
                if var current {
                    current.endedAtNextHunk = true
                    hunks.append(current)
                }
                current = UnifiedDiffHunk(lines: [], endedAtNextHunk: false)
                continue
            }

            if current == nil, isDiffMetadataLine(line) {
                continue
            }

            if current == nil {
                guard isChangedDiffLine(line) else { continue }
                current = UnifiedDiffHunk(lines: [], endedAtNextHunk: false)
            }

            current?.lines.append(line)
        }

        if let current {
            hunks.append(current)
        }

        let changingHunks = hunks.filter(\.containsChangedLine)
        guard !changingHunks.isEmpty else {
            throw invalidDiff(kind: .noChanges, reason: "diff contains no changing hunks")
        }
        return changingHunks
    }

    private static func apply(
        _ hunks: [UnifiedDiffHunk],
        to source: String,
        maximumHunks: Int
    ) throws -> String {
        let boundedMaximumHunks = max(1, maximumHunks)
        guard hunks.count <= boundedMaximumHunks else {
            throw invalidDiff(
                kind: .tooManyHunks,
                reason: "diff contains \(hunks.count) hunks; expected 1...\(boundedMaximumHunks)"
            )
        }

        var updatedSource = source
        for hunk in hunks {
            updatedSource = try apply(hunk, to: updatedSource)
        }
        return updatedSource
    }

    private static func apply(_ hunk: UnifiedDiffHunk, to source: String) throws -> String {
        let diffLines = hunk.lines.compactMap(parsedDiffLine)
        let oldLines = diffLines.compactMap(\.existingLine)
        let proposedNewLines = diffLines.compactMap(\.proposedLine)

        guard !oldLines.isEmpty else {
            throw invalidDiff(
                kind: .malformedDiff,
                reason: "diff hunk needs at least one existing context or removed line"
            )
        }
        guard oldLines.map(\.content) != proposedNewLines else {
            throw invalidDiff(kind: .noChanges, reason: "diff hunk does not change source")
        }

        let sourceLines = source.components(separatedBy: .newlines)
        let matches = matchingDiffRanges(for: oldLines, in: sourceLines)
        guard matches.count == 1, let range = matches.first else {
            throw invalidDiff(
                kind: matches.isEmpty ? .missingContext : .ambiguousContext,
                reason: "diff hunk matches \(matches.count) source regions; expected exactly 1"
            )
        }

        var replacementLines: [String] = []
        var sourceIndex = range.lowerBound
        for line in diffLines {
            switch line {
            case .context:
                // Matching may tolerate imperfect context from a small model. Keep
                // the authoritative source line instead of writing that stale context.
                replacementLines.append(sourceLines[sourceIndex])
                sourceIndex += 1
            case .removal:
                sourceIndex += 1
            case .addition(let content):
                replacementLines.append(content)
            }
        }

        var updatedLines = sourceLines
        updatedLines.replaceSubrange(range, with: replacementLines)
        return updatedLines.joined(separator: "\n")
    }

    private static func matchingDiffRanges(
        for oldLines: [ExistingDiffLine],
        in sourceLines: [String]
    ) -> [ClosedRange<Int>] {
        let oldContents = oldLines.map(\.content)
        let exact = diffLineBlockMatches(oldContents, in: sourceLines) { $0 == $1 }
        if !exact.isEmpty { return exact }

        let normalizedOldLines = oldContents.map(normalizedDiffLine)
        let normalized = diffLineBlockMatches(normalizedOldLines, in: sourceLines) {
            normalizedDiffLine($0) == $1
        }
        if !normalized.isEmpty { return normalized }

        guard oldLines.count >= 4 else { return [] }
        let maximumMismatches = max(1, min(2, oldLines.count / 4))
        return fuzzyDiffLineBlockMatches(
            oldLines,
            in: sourceLines,
            maximumContextMismatches: maximumMismatches
        )
    }

    private static func diffLineBlockMatches(
        _ targetLines: [String],
        in sourceLines: [String],
        matchesLine: (String, String) -> Bool
    ) -> [ClosedRange<Int>] {
        guard !targetLines.isEmpty, targetLines.count <= sourceLines.count else { return [] }
        let lastStart = sourceLines.count - targetLines.count
        return (0...lastStart).compactMap { start in
            let end = start + targetLines.count - 1
            let candidate = sourceLines[start...end]
            let matchCount = zip(candidate, targetLines).filter(matchesLine).count
            return matchCount == targetLines.count ? start...end : nil
        }
    }

    private static func fuzzyDiffLineBlockMatches(
        _ targetLines: [ExistingDiffLine],
        in sourceLines: [String],
        maximumContextMismatches: Int
    ) -> [ClosedRange<Int>] {
        guard !targetLines.isEmpty, targetLines.count <= sourceLines.count else { return [] }
        let lastStart = sourceLines.count - targetLines.count
        return (0...lastStart).compactMap { start in
            let end = start + targetLines.count - 1
            let candidate = sourceLines[start...end]
            var contextMismatchCount = 0

            for (candidateLine, targetLine) in zip(candidate, targetLines) {
                if normalizedDiffLine(candidateLine) == normalizedDiffLine(targetLine.content) {
                    continue
                }
                guard !targetLine.isRemoval else { return nil }
                contextMismatchCount += 1
                guard contextMismatchCount <= maximumContextMismatches else { return nil }
            }
            return start...end
        }
    }

    private static func parsedDiffLine(_ line: String) -> UnifiedDiffLine? {
        if line == #"\ No newline at end of file"# {
            return nil
        }
        guard let marker = line.first else {
            return .context("")
        }

        let content = String(line.dropFirst())
        switch marker {
        case " ":
            return .context(content)
        case "-":
            return .removal(content)
        case "+":
            return .addition(content)
        default:
            // Small models sometimes omit the leading context-space marker.
            return .context(line)
        }
    }

    private static func normalizedDiffLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func validateDiffFileMetadata(in lines: [String]) throws {
        var beforeFirstHunk = true
        for line in lines {
            if line.hasPrefix("@@") {
                beforeFirstHunk = false
                continue
            }
            guard beforeFirstHunk else { continue }

            if line.hasPrefix("diff --git ") {
                let paths = line.split(separator: " ").dropFirst(2)
                guard paths.count == 2, paths.allSatisfy({ isContentViewDiffPath(String($0)) }) else {
                    throw invalidDiff(kind: .wrongFile, reason: "diff edits a file other than ContentView.swift")
                }
            } else if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                let path = line.dropFirst(4).split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                guard path == "/dev/null" || isContentViewDiffPath(path) else {
                    throw invalidDiff(kind: .wrongFile, reason: "diff edits a file other than ContentView.swift")
                }
            } else if line.hasPrefix("*** Update File:") {
                let path = line.dropFirst("*** Update File:".count).trimmingCharacters(in: .whitespaces)
                guard isContentViewDiffPath(path) else {
                    throw invalidDiff(kind: .wrongFile, reason: "diff edits a file other than ContentView.swift")
                }
            } else if line.hasPrefix("*** Add File:") || line.hasPrefix("*** Delete File:") || line.hasPrefix("*** Move to:") {
                throw invalidDiff(kind: .wrongFile, reason: "diff may only update ContentView.swift")
            }
        }
    }

    private static func isDiffMetadataLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            || line.hasPrefix("diff --git ")
            || line.hasPrefix("index ")
            || line.hasPrefix("--- ")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("*** Update File:")
    }

    private static func isChangedDiffLine(_ line: String) -> Bool {
        guard line.hasPrefix("+") || line.hasPrefix("-") else { return false }
        return !line.hasPrefix("+++ ") && !line.hasPrefix("--- ")
    }

    private static func isContentViewDiffPath(_ path: String) -> Bool {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last == "ContentView.swift"
    }

    private static func fencedDiffBody(from text: String) -> String? {
        let pattern = #"```[A-Za-z0-9_-]*\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range).reversed() where match.numberOfRanges > 1 {
            guard let bodyRange = Range(match.range(at: 1), in: text) else { continue }
            let body = String(text[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.contains("@@") || (body.contains("\n-") && body.contains("\n+")) {
                return body
            }
        }
        return nil
    }

    private static func diffEnvelope(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        if let hunkIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@@") }) {
            let prefix = lines.startIndex...hunkIndex
            let start = lines[prefix].lastIndex(where: {
                let trimmed = $0.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("diff --git ")
                    || trimmed.hasPrefix("*** Begin Patch")
                    || trimmed.hasPrefix("--- ")
            }) ?? hunkIndex
            return lines[start...].joined(separator: "\n")
        }

        if let headerIndex = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("diff --git ")
                || trimmed.hasPrefix("*** Update File:")
                || trimmed.hasPrefix("--- ")
        }) {
            return lines[headerIndex...].joined(separator: "\n")
        }
        return text
    }

    private static func removingCommonIndentation(from lines: [String]) -> [String] {
        let nonempty = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let indentation = nonempty.map({ $0.prefix(while: { $0 == " " || $0 == "\t" }).count }).min(),
              indentation > 0
        else {
            return lines
        }
        return lines.map { line in
            line.isEmpty ? line : String(line.dropFirst(min(indentation, line.count)))
        }
    }

    private static func stripVisibleDiffThinking(from text: String) -> String {
        var cleaned = text
        for pattern in [
            #"<think>[\s\S]*?</think>"#,
            #"<thinking>[\s\S]*?</thinking>"#,
            #"<reasoning>[\s\S]*?</reasoning>"#,
            #"<\|channel\>(thought|analysis)[\s\S]*?<channel\|>"#,
        ] {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isDiffProseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        return [
            "here is", "here's", "the diff", "diff:", "patch:",
            "explanation:", "note:", "this changes", "i will", "we need",
        ].contains { lowered.hasPrefix($0) }
    }

    private static func invalidDiff(
        kind: UnifiedDiffValidationError.Kind,
        reason: String
    ) -> UnifiedDiffValidationError {
        AgentDiagnosticsLog.append(
            """
            Invalid model diff.
            reason: \(reason)
            """
        )
#if DEBUG
        print("[Ironsmith][Repair] Invalid model diff reason: \(reason)")
#endif
        return UnifiedDiffValidationError(kind: kind, reason: reason)
    }
}
