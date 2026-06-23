import Foundation

extension ContentViewRepairSupport {
    static let maximumDiffCharacters = 32_000

    static func applyValidatedDiff(
        _ rawDiff: String,
        to source: String,
        maximumHunks: Int?
    ) throws -> String {
        let diff = sanitizedDiff(rawDiff)
        guard !diff.isEmpty else {
            throw invalidRepairDiff(reason: "diff is empty")
        }
        if maximumHunks != nil {
            guard diff.count <= maximumDiffCharacters else {
                throw invalidRepairDiff(reason: "diff exceeds maximum length of \(maximumDiffCharacters) characters")
            }
        }

        let hunks = try parseUnifiedDiff(diff)
        guard !hunks.isEmpty else {
            throw invalidRepairDiff(reason: "diff contains no hunks")
        }
        let changingHunks = hunks.filter(\.containsChangedLine)
        guard !changingHunks.isEmpty else {
            throw invalidRepairDiff(reason: "diff contains no changing hunks")
        }
        if let maximumHunks {
            let boundedMaximumHunks = max(1, maximumHunks)
            guard changingHunks.count <= boundedMaximumHunks else {
                throw invalidRepairDiff(reason: "diff contains \(changingHunks.count) hunks; expected 1...\(boundedMaximumHunks)")
            }
        }

        var updatedSource = source
        for hunk in changingHunks {
            updatedSource = try apply(hunk, to: updatedSource)
        }
        return updatedSource
    }

    static func sanitizedRepairDiffSummary(_ rawDiff: String) -> String {
        sanitizedDiff(rawDiff)
    }

    private struct UnifiedDiffHunk: Equatable {
        var lines: [String]

        var containsChangedLine: Bool {
            lines.dropFirst().contains { line in
                line.hasPrefix("+") || line.hasPrefix("-")
            }
        }
    }

    private static func sanitizedDiff(_ text: String) -> String {
        var cleaned = stripVisibleThinking(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
        cleaned = fencedDiffBody(from: cleaned) ?? diffEnvelope(from: cleaned)
        let lines = cleaned
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.hasPrefix("```")
                    && !isDiffProseLine(trimmed)
                    && !isApplyPatchEnvelopeLine(trimmed)
            }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fencedDiffBody(from text: String) -> String? {
        let pattern = #"```[A-Za-z0-9_-]*\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else {
                continue
            }
            let body = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if containsDiffHunk(body) {
                return body
            }
        }
        return nil
    }

    private static func diffEnvelope(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard let firstHunkIndex = lines.firstIndex(where: { $0.hasPrefix("@@") }) else {
            return text
        }

        let prefixRange = lines.startIndex...firstHunkIndex
        let startIndex = lines[prefixRange].lastIndex { line in
            line.hasPrefix("diff --git ")
                || line.hasPrefix("--- ")
        } ?? firstHunkIndex
        return lines[startIndex...].joined(separator: "\n")
    }

    private static func stripVisibleThinking(from text: String) -> String {
        var cleaned = text
        let patterns = [
            #"<think>[\s\S]*?</think>"#,
            #"<thinking>[\s\S]*?</thinking>"#,
            #"<reasoning>[\s\S]*?</reasoning>"#,
            #"<\|channel\>(thought|analysis)[\s\S]*?<channel\|>"#
        ]

        for pattern in patterns {
            cleaned = cleaned.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsDiffHunk(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { $0.hasPrefix("@@") }
    }

    private static func isDiffProseLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let lowered = line.lowercased()
        let prosePrefixes = [
            "here is",
            "here's",
            "the diff",
            "diff:",
            "explanation:",
            "note:",
            "this changes",
            "i will",
            "we need"
        ]
        return prosePrefixes.contains { lowered.hasPrefix($0) }
    }

    private static func isApplyPatchEnvelopeLine(_ line: String) -> Bool {
        line == "*** Begin Patch"
            || line == "*** End Patch"
            || line == "*** End of File"
            || line.hasPrefix("*** Update File:")
            || line.hasPrefix("*** Add File:")
            || line.hasPrefix("*** Delete File:")
            || line.hasPrefix("*** Move to:")
    }

    private static func parseUnifiedDiff(_ diff: String) throws -> [UnifiedDiffHunk] {
        let lines = diff.components(separatedBy: .newlines)
        try validateFileHeaders(in: lines)

        var hunks: [UnifiedDiffHunk] = []
        var current: [String] = []
        for line in lines {
            if line.hasPrefix("@@") {
                if !current.isEmpty {
                    hunks.append(UnifiedDiffHunk(lines: current))
                }
                current = [line]
                continue
            }
            guard !current.isEmpty else {
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                continue
            }
            if line.hasPrefix("\\ No newline") {
                continue
            }
            current.append(line)
        }
        if !current.isEmpty {
            hunks.append(UnifiedDiffHunk(lines: current))
        }
        return hunks
    }

    private static func validateFileHeaders(in lines: [String]) throws {
        let fileHeaderLines = lines.filter { $0.hasPrefix("--- ") || $0.hasPrefix("+++ ") }
        guard !fileHeaderLines.isEmpty else {
            return
        }
        for line in fileHeaderLines {
            let path = line.dropFirst(4).split(separator: "\t", maxSplits: 1).first.map(String.init) ?? ""
            guard path == "/dev/null" || path.hasSuffix("ContentView.swift") else {
                throw invalidRepairDiff(reason: "diff edits a file other than ContentView.swift")
            }
        }
    }

    private static func apply(_ hunk: UnifiedDiffHunk, to source: String) throws -> String {
        var oldLines: [String] = []
        var newLines: [String] = []

        for line in hunk.lines.dropFirst() {
            guard let marker = line.first else {
                oldLines.append("")
                newLines.append("")
                continue
            }
            let content = String(line.dropFirst())
            switch marker {
            case " ":
                oldLines.append(content)
                newLines.append(content)
            case "-":
                oldLines.append(content)
            case "+":
                newLines.append(content)
            default:
                throw invalidRepairDiff(reason: "diff hunk contains an invalid line marker")
            }
        }

        guard !oldLines.isEmpty else {
            throw invalidRepairDiff(reason: "diff hunk has no removable or context lines")
        }
        guard oldLines != newLines else {
            throw invalidRepairDiff(reason: "diff hunk does not change source")
        }

        var sourceLines = source.components(separatedBy: .newlines)
        let matches = matchingRanges(for: oldLines, in: sourceLines)
        guard matches.count == 1, let range = matches.first else {
            throw invalidRepairDiff(reason: "diff hunk matches \(matches.count) source regions; expected exactly 1")
        }

        sourceLines.replaceSubrange(range, with: newLines)
        return sourceLines.joined(separator: "\n")
    }

    private static func invalidRepairDiff(reason: String) -> ToolGenerationError {
        AgentDiagnosticsLog.append(
            """
            Invalid model repair diff.
            reason: \(reason)
            """
        )
#if DEBUG
        print("[Ironsmith][Repair] Invalid model repair diff reason: \(reason)")
#endif
        return .invalidRepairPatch
    }

    private static func matchingRanges(for oldLines: [String], in sourceLines: [String]) -> [ClosedRange<Int>] {
        guard oldLines.count <= sourceLines.count else { return [] }
        let lastStart = sourceLines.count - oldLines.count
        guard lastStart >= 0 else { return [] }
        return (0...lastStart).compactMap { start in
            let end = start + oldLines.count - 1
            let candidate = Array(sourceLines[start...end])
            guard equivalentDiffBlock(candidate, oldLines) else { return nil }
            return start...end
        }
    }

    private static func equivalentDiffBlock(_ candidate: [String], _ target: [String]) -> Bool {
        guard candidate.count == target.count else { return false }
        if zip(candidate, target).allSatisfy({ $0.0 == $0.1 }) {
            return true
        }
        return zip(candidate, target).allSatisfy { lhs, rhs in
            lhs.trimmingCharacters(in: .whitespaces) == rhs.trimmingCharacters(in: .whitespaces)
        }
    }
}
