import Foundation

extension ContentViewRepairSupport {
    static let maximumPatchCharacters = ToolGenerationRepairPolicy.maximumPatchCharacters

    static func applyValidatedSearchReplacePatch(
        _ rawPatch: String,
        to source: String,
        maximumPatchBlocks: Int,
        maximumPatchCharacters: Int = maximumPatchCharacters
    ) throws -> String {
        let patch = sanitizedSearchReplacePatchSummary(rawPatch)
        guard !patch.isEmpty else {
            throw invalidSearchReplacePatch(reason: "patch is empty")
        }
        guard patch.count <= maximumPatchCharacters else {
            throw invalidSearchReplacePatch(
                reason: "patch exceeds maximum length of \(maximumPatchCharacters) characters"
            )
        }

        let blocks = try parseSearchReplacePatch(patch)
        let boundedMaximumBlocks = max(1, maximumPatchBlocks)
        guard blocks.count <= boundedMaximumBlocks else {
            throw invalidSearchReplacePatch(
                reason: "patch contains \(blocks.count) block(s); expected 1...\(boundedMaximumBlocks)"
            )
        }

        var updatedSource = source
        for block in blocks {
            updatedSource = try apply(block, to: updatedSource)
        }
        return updatedSource
    }

    static func sanitizedSearchReplacePatchSummary(_ rawPatch: String) -> String {
        stripVisibleThinking(from: rawPatch.trimmingCharacters(in: .whitespacesAndNewlines))
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.hasPrefix("```")
                    && !isPatchProseLine(trimmed)
                    && !isApplyPatchEnvelopeLine(trimmed)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct SearchReplaceBlock: Equatable {
        let search: String
        let replacement: String
    }

    private static let searchMarker = "<<<<<<< SEARCH"
    private static let separatorMarker = "======="
    private static let replaceMarker = ">>>>>>> REPLACE"

    private static func parseSearchReplacePatch(_ patch: String) throws -> [SearchReplaceBlock] {
        let lines = patch.components(separatedBy: .newlines)
        var blocks: [SearchReplaceBlock] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == searchMarker else {
                index += 1
                continue
            }

            index += 1
            var searchLines: [String] = []
            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespacesAndNewlines) != separatorMarker {
                searchLines.append(lines[index])
                index += 1
            }
            guard index < lines.count else {
                throw invalidSearchReplacePatch(reason: "patch block is missing the ======= separator")
            }

            index += 1
            var replacementLines: [String] = []
            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespacesAndNewlines) != replaceMarker {
                replacementLines.append(lines[index])
                index += 1
            }
            guard index < lines.count else {
                throw invalidSearchReplacePatch(reason: "patch block is missing the >>>>>>> REPLACE marker")
            }

            let search = trimEdgeBlankLines(searchLines).joined(separator: "\n")
            let replacement = trimEdgeBlankLines(replacementLines).joined(separator: "\n")
            guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalidSearchReplacePatch(reason: "patch block has an empty SEARCH section")
            }
            blocks.append(SearchReplaceBlock(search: search, replacement: replacement))
            index += 1
        }

        guard !blocks.isEmpty else {
            throw ToolGenerationError.noRepairPatchCandidate
        }
        return blocks
    }

    private static func trimEdgeBlankLines(_ lines: [String]) -> [String] {
        var trimmed = lines
        while trimmed.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            trimmed.removeFirst()
        }
        while trimmed.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            trimmed.removeLast()
        }
        return trimmed
    }

    private static func apply(_ block: SearchReplaceBlock, to source: String) throws -> String {
        let exactMatches = source.ranges(of: block.search)
        if exactMatches.count == 1, let range = exactMatches.first {
            var updated = source
            updated.replaceSubrange(range, with: block.replacement)
            return updated
        }
        if exactMatches.count > 1 {
            throw invalidSearchReplacePatch(reason: "SEARCH block matches \(exactMatches.count) source regions; expected exactly 1")
        }

        return try applyWhitespaceNormalized(block, to: source)
    }

    private static func applyWhitespaceNormalized(
        _ block: SearchReplaceBlock,
        to source: String
    ) throws -> String {
        let sourceLines = source.components(separatedBy: .newlines)
        let searchLines = block.search.components(separatedBy: .newlines)
        guard !searchLines.isEmpty, searchLines.count <= sourceLines.count else {
            throw invalidSearchReplacePatch(reason: "SEARCH block does not appear in source")
        }

        let normalizedSearch = searchLines.map(normalizedPatchLine)
        let lastStart = sourceLines.count - searchLines.count
        let matches = (0...lastStart).compactMap { start -> ClosedRange<Int>? in
            let end = start + searchLines.count - 1
            let candidate = sourceLines[start...end].map(normalizedPatchLine)
            guard candidate == normalizedSearch else { return nil }
            return start...end
        }

        guard matches.count == 1, let range = matches.first else {
            throw invalidSearchReplacePatch(
                reason: "normalized SEARCH block matches \(matches.count) source regions; expected exactly 1"
            )
        }

        var updatedLines = sourceLines
        let replacementLines = block.replacement.isEmpty
            ? []
            : block.replacement.components(separatedBy: .newlines)
        updatedLines.replaceSubrange(range, with: replacementLines)
        return updatedLines.joined(separator: "\n")
    }

    private static func normalizedPatchLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
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

    private static func isPatchProseLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return false }
        let lowered = line.lowercased()
        let prosePrefixes = [
            "here is",
            "here's",
            "the patch",
            "patch:",
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

    private static func invalidSearchReplacePatch(reason: String) -> ToolGenerationError {
        AgentDiagnosticsLog.append(
            """
            Invalid model repair patch.
            reason: \(reason)
            """
        )
#if DEBUG
        print("[Ironsmith][Repair] Invalid model repair patch reason: \(reason)")
#endif
        return .invalidRepairPatch
    }
}
