import Foundation

extension ContentViewRepairSupport {
    static let maximumPatchCharacters = ToolGenerationRepairPolicy.maximumPatchCharacters

    struct SearchReplacePatchValidationError: LocalizedError, Equatable {
        enum Kind: Equatable {
            case emptyPatch
            case tooLong
            case tooManyBlocks
            case malformedBlock
            case emptySearch
            case ambiguousSearch
            case missingSearch
        }

        let kind: Kind
        let reason: String

        var errorDescription: String? {
            "The repair model returned an invalid patch. \(reason)"
        }

        var isStaleSearchFailure: Bool {
            kind == .missingSearch
        }
    }

    struct SearchReplacePatchSkippedBlock: Equatable {
        let index: Int
        let reason: String
    }

    struct SearchReplacePatchApplicationResult: Equatable {
        let source: String
        let parsedBlockCount: Int
        let appliedBlockCount: Int
        let skippedBlocks: [SearchReplacePatchSkippedBlock]

        var logSummary: String {
            let skippedSummary = skippedBlocks.isEmpty
                ? "none"
                : skippedBlocks
                    .map { "#\($0.index): \($0.reason)" }
                    .joined(separator: "\n")
            return """
            parsedBlockCount: \(parsedBlockCount)
            appliedBlockCount: \(appliedBlockCount)
            skippedBlockCount: \(skippedBlocks.count)
            skippedBlocks:
            \(skippedSummary)
            """
        }
    }

    static func applyValidatedSearchReplacePatch(
        _ rawPatch: String,
        to source: String,
        maximumPatchBlocks: Int,
        maximumPatchCharacters: Int = maximumPatchCharacters
    ) throws -> String {
        let patch = sanitizedSearchReplacePatchSummary(rawPatch)
        guard !patch.isEmpty else {
            throw invalidSearchReplacePatch(kind: .emptyPatch, reason: "patch is empty")
        }
        guard patch.count <= maximumPatchCharacters else {
            throw invalidSearchReplacePatch(
                kind: .tooLong,
                reason: "patch exceeds maximum length of \(maximumPatchCharacters) characters"
            )
        }

        let blocks = try parseSearchReplacePatch(patch)
        let boundedMaximumBlocks = max(1, maximumPatchBlocks)
        guard blocks.count <= boundedMaximumBlocks else {
            throw invalidSearchReplacePatch(
                kind: .tooManyBlocks,
                reason: "patch contains \(blocks.count) block(s); expected 1...\(boundedMaximumBlocks)"
            )
        }

        var updatedSource = source
        for block in blocks {
            updatedSource = try apply(block, to: updatedSource)
        }
        return updatedSource
    }

    static func applySearchReplacePatchBestEffort(
        _ rawPatch: String,
        to source: String,
        maximumPatchBlocks: Int,
        maximumPatchCharacters: Int = maximumPatchCharacters
    ) throws -> SearchReplacePatchApplicationResult {
        let patch = sanitizedSearchReplacePatchSummary(rawPatch)
        guard !patch.isEmpty else {
            throw invalidSearchReplacePatch(kind: .emptyPatch, reason: "patch is empty")
        }
        guard patch.count <= maximumPatchCharacters else {
            throw invalidSearchReplacePatch(
                kind: .tooLong,
                reason: "patch exceeds maximum length of \(maximumPatchCharacters) characters"
            )
        }

        let parseResult = parseSearchReplacePatchLenient(patch)
        let boundedMaximumBlocks = max(1, maximumPatchBlocks)
        let blocksToApply = Array(parseResult.blocks.prefix(boundedMaximumBlocks))
        var skippedBlocks = parseResult.skippedBlocks
        if parseResult.blocks.count > boundedMaximumBlocks {
            for parsedBlock in parseResult.blocks.dropFirst(boundedMaximumBlocks) {
                skippedBlocks.append(
                    SearchReplacePatchSkippedBlock(
                        index: parsedBlock.index,
                        reason: "patch block exceeds maximum block count of \(boundedMaximumBlocks)"
                    )
                )
            }
        }

        var updatedSource = source
        var appliedBlockCount = 0
        for parsedBlock in blocksToApply {
            do {
                updatedSource = try apply(parsedBlock.block, to: updatedSource)
                appliedBlockCount += 1
            } catch {
                let reason: String
                if let validationError = error as? SearchReplacePatchValidationError {
                    reason = validationError.reason
                } else {
                    reason = error.localizedDescription
                }
                skippedBlocks.append(SearchReplacePatchSkippedBlock(index: parsedBlock.index, reason: reason))
            }
        }

        guard appliedBlockCount > 0 else {
            let skippedSummary = skippedBlocks
                .prefix(3)
                .map { "#\($0.index): \($0.reason)" }
                .joined(separator: "; ")
            let reason = skippedSummary.isEmpty
                ? "no valid patch blocks were found"
                : "no patch blocks applied; \(skippedSummary)"
            throw invalidSearchReplacePatch(kind: .missingSearch, reason: reason)
        }

        return SearchReplacePatchApplicationResult(
            source: updatedSource,
            parsedBlockCount: parseResult.totalBlockCount,
            appliedBlockCount: appliedBlockCount,
            skippedBlocks: skippedBlocks.sorted { $0.index < $1.index }
        )
    }

    struct CompletedPatchApplication: Equatable {
        let source: String
        let appliedBlockCount: Int
    }

    static func applyCompletedSearchReplacePatchBlocks(
        _ rawPatch: String,
        to source: String,
        maximumPatchBlocks: Int,
        maximumPatchCharacters: Int = maximumPatchCharacters
    ) throws -> CompletedPatchApplication? {
        let patch = sanitizedSearchReplacePatchSummary(rawPatch)
        guard !patch.isEmpty else { return nil }
        guard patch.count <= maximumPatchCharacters else {
            throw invalidSearchReplacePatch(
                kind: .tooLong,
                reason: "patch exceeds maximum length of \(maximumPatchCharacters) characters"
            )
        }

        let blocks = try parseCompletedSearchReplacePatchBlocks(patch)
        guard !blocks.isEmpty else { return nil }

        let boundedMaximumBlocks = max(1, maximumPatchBlocks)
        guard blocks.count <= boundedMaximumBlocks else {
            throw invalidSearchReplacePatch(
                kind: .tooManyBlocks,
                reason: "patch contains \(blocks.count) completed block(s); expected 1...\(boundedMaximumBlocks)"
            )
        }

        var updatedSource = source
        for block in blocks {
            updatedSource = try apply(block, to: updatedSource)
        }
        return CompletedPatchApplication(source: updatedSource, appliedBlockCount: blocks.count)
    }

    static func sanitizedSearchReplacePatchSummary(_ rawPatch: String) -> String {
        var sanitizedLines: [String] = []
        var currentBlockKind: SearchReplaceBlock.Kind?

        for line in stripVisibleThinking(from: rawPatch.trimmingCharacters(in: .whitespacesAndNewlines))
            .components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let blockKind = currentBlockKind {
                sanitizedLines.append(line)
                if trimmed == closingMarker(for: blockKind) {
                    currentBlockKind = nil
                }
                continue
            }

            if let blockKind = blockKind(forOpeningMarker: trimmed) {
                currentBlockKind = blockKind
                sanitizedLines.append(line)
                continue
            }

            guard !trimmed.hasPrefix("```"),
                  !isPatchProseLine(trimmed),
                  !isApplyPatchEnvelopeLine(trimmed)
            else {
                continue
            }
            sanitizedLines.append(line)
        }

        return sanitizedLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct SearchReplaceBlock: Equatable {
        enum Kind: Equatable {
            case replace
            case insertBefore
            case insertAfter
        }

        let kind: Kind
        let search: String
        let replacement: String
    }

    private static let searchMarker = "<<<<<<< SEARCH"
    private static let insertBeforeMarker = "<<<<<<< INSERT_BEFORE"
    private static let insertAfterMarker = "<<<<<<< INSERT_AFTER"
    private static let separatorMarker = "======="
    private static let replaceMarker = ">>>>>>> REPLACE"
    private static let insertMarker = ">>>>>>> INSERT"

    private static func parseSearchReplacePatch(_ patch: String) throws -> [SearchReplaceBlock] {
        let lines = patch.components(separatedBy: .newlines)
        var blocks: [SearchReplaceBlock] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = blockKind(forOpeningMarker: trimmed) else {
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
                throw invalidSearchReplacePatch(
                    kind: .malformedBlock,
                    reason: "patch block is missing the ======= separator"
                )
            }

            index += 1
            var replacementLines: [String] = []
            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespacesAndNewlines) != closingMarker(for: kind) {
                replacementLines.append(lines[index])
                index += 1
            }
            guard index < lines.count else {
                throw invalidSearchReplacePatch(
                    kind: .malformedBlock,
                    reason: "patch block is missing the \(closingMarker(for: kind)) marker"
                )
            }

            let search = trimEdgeBlankLines(searchLines).joined(separator: "\n")
            let replacement = trimEdgeBlankLines(replacementLines).joined(separator: "\n")
            guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalidSearchReplacePatch(
                    kind: .emptySearch,
                    reason: "patch block has an empty SEARCH section"
                )
            }
            blocks.append(SearchReplaceBlock(kind: kind, search: search, replacement: replacement))
            index += 1
        }

        guard !blocks.isEmpty else {
            throw ToolGenerationError.noRepairPatchCandidate
        }
        return blocks
    }

    private struct LenientParseResult {
        let blocks: [IndexedSearchReplaceBlock]
        let skippedBlocks: [SearchReplacePatchSkippedBlock]
        let totalBlockCount: Int
    }

    private struct IndexedSearchReplaceBlock {
        let index: Int
        let block: SearchReplaceBlock
    }

    private static func parseSearchReplacePatchLenient(_ patch: String) -> LenientParseResult {
        let lines = patch.components(separatedBy: .newlines)
        var blocks: [IndexedSearchReplaceBlock] = []
        var skippedBlocks: [SearchReplacePatchSkippedBlock] = []
        var index = 0
        var blockIndex = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = blockKind(forOpeningMarker: trimmed) else {
                index += 1
                continue
            }

            blockIndex += 1
            index += 1
            var searchLines: [String] = []
            while index < lines.count {
                let current = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if current == separatorMarker || blockKind(forOpeningMarker: current) != nil {
                    break
                }
                searchLines.append(lines[index])
                index += 1
            }
            guard index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == separatorMarker
            else {
                skippedBlocks.append(
                    SearchReplacePatchSkippedBlock(
                        index: blockIndex,
                        reason: "patch block is missing the ======= separator"
                    )
                )
                continue
            }

            index += 1
            var replacementLines: [String] = []
            while index < lines.count {
                let current = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                if current == closingMarker(for: kind) || blockKind(forOpeningMarker: current) != nil {
                    break
                }
                replacementLines.append(lines[index])
                index += 1
            }
            guard index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespacesAndNewlines) == closingMarker(for: kind)
            else {
                skippedBlocks.append(
                    SearchReplacePatchSkippedBlock(
                        index: blockIndex,
                        reason: "patch block is missing the \(closingMarker(for: kind)) marker"
                    )
                )
                continue
            }

            let search = trimEdgeBlankLines(searchLines).joined(separator: "\n")
            let replacement = trimEdgeBlankLines(replacementLines).joined(separator: "\n")
            guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skippedBlocks.append(
                    SearchReplacePatchSkippedBlock(
                        index: blockIndex,
                        reason: "patch block has an empty SEARCH section"
                    )
                )
                index += 1
                continue
            }
            blocks.append(
                IndexedSearchReplaceBlock(
                    index: blockIndex,
                    block: SearchReplaceBlock(kind: kind, search: search, replacement: replacement)
                )
            )
            index += 1
        }

        return LenientParseResult(
            blocks: blocks,
            skippedBlocks: skippedBlocks,
            totalBlockCount: blockIndex
        )
    }

    private static func parseCompletedSearchReplacePatchBlocks(_ patch: String) throws -> [SearchReplaceBlock] {
        let lines = patch.components(separatedBy: .newlines)
        var blocks: [SearchReplaceBlock] = []
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let kind = blockKind(forOpeningMarker: trimmed) else {
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
                break
            }

            index += 1
            var replacementLines: [String] = []
            while index < lines.count,
                  lines[index].trimmingCharacters(in: .whitespacesAndNewlines) != closingMarker(for: kind) {
                replacementLines.append(lines[index])
                index += 1
            }
            guard index < lines.count else {
                break
            }

            let search = trimEdgeBlankLines(searchLines).joined(separator: "\n")
            let replacement = trimEdgeBlankLines(replacementLines).joined(separator: "\n")
            guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalidSearchReplacePatch(
                    kind: .emptySearch,
                    reason: "patch block has an empty SEARCH section"
                )
            }
            blocks.append(SearchReplaceBlock(kind: kind, search: search, replacement: replacement))
            index += 1
        }

        return blocks
    }

    private static func blockKind(forOpeningMarker marker: String) -> SearchReplaceBlock.Kind? {
        switch marker {
        case searchMarker:
            return .replace
        case insertBeforeMarker:
            return .insertBefore
        case insertAfterMarker:
            return .insertAfter
        default:
            return nil
        }
    }

    private static func closingMarker(for kind: SearchReplaceBlock.Kind) -> String {
        switch kind {
        case .replace:
            return replaceMarker
        case .insertBefore, .insertAfter:
            return insertMarker
        }
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
        switch block.kind {
        case .replace:
            return try applyReplacement(block, to: source)
        case .insertBefore:
            let range = try lineRange(for: block.search, in: source)
            return source.insertingLines(block.replacement, before: range.lowerBound)
        case .insertAfter:
            let range = try lineRange(for: block.search, in: source)
            return source.insertingLines(block.replacement, after: range.upperBound)
        }
    }

    private static func applyReplacement(_ block: SearchReplaceBlock, to source: String) throws -> String {
        let exactMatches = source.ranges(of: block.search)
        if exactMatches.count == 1, let range = exactMatches.first {
            var updated = source
            updated.replaceSubrange(range, with: block.replacement)
            return updated
        }
        if exactMatches.count > 1 {
            throw invalidSearchReplacePatch(
                kind: .ambiguousSearch,
                reason: "SEARCH block matches \(exactMatches.count) source regions; expected exactly 1"
            )
        }

        return try applyWhitespaceNormalized(block, to: source)
    }

    private static func applyWhitespaceNormalized(
        _ block: SearchReplaceBlock,
        to source: String
    ) throws -> String {
        let range = try lineRange(for: block.search, in: source)
        return source.replacingLines(in: range, with: block.replacement)
    }

    private static func lineRange(for search: String, in source: String) throws -> ClosedRange<Int> {
        let sourceLines = source.components(separatedBy: .newlines)
        let searchLines = search.components(separatedBy: .newlines)
        guard !searchLines.isEmpty, searchLines.count <= sourceLines.count else {
            throw invalidSearchReplacePatch(
                kind: .missingSearch,
                reason: "SEARCH block does not appear in source"
            )
        }

        let exactLineMatches = lineBlockMatches(
            sourceLines: sourceLines,
            searchLines: searchLines
        ) { sourceLine, searchLine in
            sourceLine == searchLine
        }
        if exactLineMatches.count == 1, let range = exactLineMatches.first {
            return range
        }
        if exactLineMatches.count > 1 {
            throw invalidSearchReplacePatch(
                kind: .ambiguousSearch,
                reason: "line SEARCH block matches \(exactLineMatches.count) source regions; expected exactly 1"
            )
        }

        let normalizedSearch = searchLines.map(normalizedPatchLine)
        let normalizedMatches = lineBlockMatches(
            sourceLines: sourceLines,
            searchLines: normalizedSearch
        ) { sourceLine, normalizedSearchLine in
            normalizedPatchLine(sourceLine) == normalizedSearchLine
        }
        if normalizedMatches.count == 1, let range = normalizedMatches.first {
            return range
        }
        if normalizedMatches.count > 1 {
            throw invalidSearchReplacePatch(
                kind: .ambiguousSearch,
                reason: "normalized SEARCH block matches \(normalizedMatches.count) source regions; expected exactly 1"
            )
        }

        let minimumLineCount = 4
        guard searchLines.count >= minimumLineCount, searchLines.count <= sourceLines.count else {
            throw invalidSearchReplacePatch(
                kind: .missingSearch,
                reason: "normalized SEARCH block matches 0 source regions; expected exactly 1"
            )
        }

        let maximumMismatches = max(1, min(2, searchLines.count / 4))
        let minimumMatches = searchLines.count - maximumMismatches
        let nearMatches = lineBlockMatches(
            sourceLines: sourceLines,
            searchLines: normalizedSearch
        ) { sourceLine, normalizedSearchLine in
            normalizedPatchLine(sourceLine) == normalizedSearchLine
        } threshold: { matchCount in
            matchCount >= minimumMatches
        }

        guard nearMatches.count == 1, let range = nearMatches.first else {
            throw invalidSearchReplacePatch(
                kind: nearMatches.isEmpty ? .missingSearch : .ambiguousSearch,
                reason: "near-normalized SEARCH block matches \(nearMatches.count) source regions; expected exactly 1"
            )
        }

        AgentDiagnosticsLog.append(
            """
            Applied near-normalized search/replace patch match.
            matchedLineCount: \(searchLines.count)
            maximumMismatches: \(maximumMismatches)
            """
        )
        return range
    }

    private static func lineBlockMatches(
        sourceLines: [String],
        searchLines: [String],
        matchesLine: (String, String) -> Bool
    ) -> [ClosedRange<Int>] {
        lineBlockMatches(
            sourceLines: sourceLines,
            searchLines: searchLines,
            matchesLine: matchesLine
        ) { matchCount in
            matchCount == searchLines.count
        }
    }

    private static func lineBlockMatches(
        sourceLines: [String],
        searchLines: [String],
        matchesLine: (String, String) -> Bool,
        threshold: (Int) -> Bool
    ) -> [ClosedRange<Int>] {
        guard !searchLines.isEmpty, searchLines.count <= sourceLines.count else {
            return []
        }
        let lastStart = sourceLines.count - searchLines.count
        return (0...lastStart).compactMap { start -> ClosedRange<Int>? in
            let end = start + searchLines.count - 1
            let candidate = sourceLines[start...end]
            let matchCount = zip(candidate, searchLines)
                .filter { sourceLine, searchLine in
                    matchesLine(sourceLine, searchLine)
                }
                .count
            guard threshold(matchCount) else { return nil }
            return start...end
        }
    }

    private static func normalizedPatchLine(_ line: String) -> String {
        line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

private extension String {
    func replacingLines(in range: ClosedRange<Int>, with replacement: String) -> String {
        let sourceLines = components(separatedBy: .newlines)
        var updatedLines = sourceLines
        let replacementLines = replacement.isEmpty
            ? []
            : replacement.components(separatedBy: .newlines)
        updatedLines.replaceSubrange(range, with: replacementLines)
        return updatedLines.joined(separator: "\n")
    }

    func insertingLines(_ insertion: String, before lineIndex: Int) -> String {
        insertingLines(insertion, at: lineIndex)
    }

    func insertingLines(_ insertion: String, after lineIndex: Int) -> String {
        insertingLines(insertion, at: lineIndex + 1)
    }

    private func insertingLines(_ insertion: String, at lineIndex: Int) -> String {
        guard !insertion.isEmpty else { return self }
        let sourceLines = components(separatedBy: .newlines)
        var updatedLines = sourceLines
        let insertionLines = insertion.components(separatedBy: .newlines)
        let boundedIndex = min(max(0, lineIndex), updatedLines.count)
        updatedLines.insert(contentsOf: insertionLines, at: boundedIndex)
        return updatedLines.joined(separator: "\n")
    }
}

extension ContentViewRepairSupport {
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

    private static func invalidSearchReplacePatch(
        kind: SearchReplacePatchValidationError.Kind,
        reason: String
    ) -> SearchReplacePatchValidationError {
        AgentDiagnosticsLog.append(
            """
            Invalid model repair patch.
            reason: \(reason)
            """
        )
#if DEBUG
        print("[Ironsmith][Repair] Invalid model repair patch reason: \(reason)")
#endif
        return SearchReplacePatchValidationError(kind: kind, reason: reason)
    }
}
