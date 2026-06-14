import Foundation

enum AgentDiagnosticsLog {
    nonisolated static let defaultURL = IronsmithPaths.agentDiagnosticsLogURL
    nonisolated static let repairRequestSupportingLineLimit = 3
    nonisolated static let buildFailureDiagnosticLimit = 8
    nonisolated static let deterministicEditSummaryFieldLimit = 140
    nonisolated static let deterministicEditDetailFieldLimit = 320
    nonisolated static let repairExcerptLimit = 1_200
    nonisolated static let repairDiffLimit = 1_200

    nonisolated static func append(
        _ message: String,
        to logURL: URL = defaultURL
    ) {
#if DEBUG
        guard shouldWrite(to: logURL) else {
            return
        }

        let entry = """

        ===== \(Self.timestamp()) =====
        \(message)
        """

        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = Data(entry.utf8)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            print("[Ironsmith][DiagnosticsLog] Failed to append diagnostics: \(error.localizedDescription)")
        }
#endif
    }

    nonisolated static func renderDiagnostics(
        _ diagnostics: [SwiftCompilerDiagnostic],
        limit: Int = 8,
        includeSupportingLines: Bool = false,
        supportingLineLimit: Int = 8
    ) -> String {
        guard !diagnostics.isEmpty else {
            return "No parsed diagnostics."
        }

        let uniqueDiagnostics = deduplicatedDiagnostics(diagnostics)
        let duplicateCount = diagnostics.count - uniqueDiagnostics.count
        let rendered = uniqueDiagnostics
            .prefix(limit)
            .map { diagnostic in
                var lines = [
                    "\(diagnostic.relativePath ?? "<unknown file>"):\(diagnostic.line):\(diagnostic.column): \(diagnostic.severity.rawValue): \(diagnostic.message)"
                ]
                if includeSupportingLines, !diagnostic.supportingLines.isEmpty {
                    lines.append(contentsOf: diagnostic.supportingLines.prefix(supportingLineLimit))
                    if diagnostic.supportingLines.count > supportingLineLimit {
                        lines.append("... \(diagnostic.supportingLines.count - supportingLineLimit) more context lines omitted")
                    }
                }
                return lines.joined(separator: "\n")
            }
        var output = rendered.joined(separator: "\n")
        if uniqueDiagnostics.count > limit {
            output += "\n... \(uniqueDiagnostics.count - limit) more diagnostics omitted"
        }
        if duplicateCount > 0 {
            output += "\n... \(duplicateCount) duplicate diagnostics omitted"
        }
        return output
    }

    nonisolated static func renderDeterministicEdit(
        _ edit: ContentViewDeterministicEdit,
        fieldLimit: Int = deterministicEditDetailFieldLimit
    ) -> String {
        """
        operation: \(edit.operation.rawValue)
        target: \(String(reflecting: compact(edit.target, limit: fieldLimit)))
        replacement: \(String(reflecting: compact(edit.replacement, limit: fieldLimit)))
        section: \(String(describing: edit.section))
        """
    }

    nonisolated static func renderDeterministicEditSummary(
        _ edit: ContentViewDeterministicEdit,
        fieldLimit: Int = deterministicEditSummaryFieldLimit
    ) -> String {
        """
        operation: \(edit.operation.rawValue)
        target: \(String(reflecting: compact(edit.target, limit: fieldLimit)))
        replacement: \(String(reflecting: compact(edit.replacement, limit: fieldLimit)))
        """
    }

    nonisolated static func renderRepairSnippets(
        _ snippets: [ContentViewRepairSnippet],
        limit: Int = repairExcerptLimit
    ) -> String {
        guard !snippets.isEmpty else {
            return "No repair excerpts."
        }

        let uniqueSnippets = deduplicatedSnippets(snippets)
        let rendered = uniqueSnippets
            .prefix(2)
            .map { snippet in
                """
                Lines \(snippet.startLine)-\(snippet.endLine):
                ```swift
                \(snippet.text)
                ```
                """
            }
            .joined(separator: "\n\n")
        var output = compactMultiline(rendered, limit: limit)
        if uniqueSnippets.count > 2 {
            output += "\n\n... \(uniqueSnippets.count - 2) more relevant excerpts omitted"
        }
        if snippets.count > uniqueSnippets.count {
            output += "\n... \(snippets.count - uniqueSnippets.count) duplicate excerpts omitted"
        }
        return output
    }

    nonisolated static func compact(
        _ text: String,
        limit: Int = 320
    ) -> String {
        let oneLine = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard oneLine.count > limit else {
            return oneLine
        }

        let endIndex = oneLine.index(oneLine.startIndex, offsetBy: max(0, limit))
        return "\(oneLine[..<endIndex])... [\(oneLine.count - limit) chars omitted]"
    }

    nonisolated static func compactMultiline(
        _ text: String,
        limit: Int
    ) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count > limit else {
            return normalized
        }

        let endIndex = normalized.index(normalized.startIndex, offsetBy: max(0, limit))
        return "\(normalized[..<endIndex])\n... [\(normalized.count - limit) chars omitted]"
    }

    nonisolated static func renderError(
        _ error: any Error,
        limit: Int = 4_000
    ) -> String {
        let rendered = renderErrorLines(error, depth: 0).joined(separator: "\n")
        guard rendered.count > limit else {
            return rendered
        }

        let endIndex = rendered.index(rendered.startIndex, offsetBy: max(0, limit))
        return "\(rendered[..<endIndex])... [\(rendered.count - limit) chars omitted]"
    }

    nonisolated private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    nonisolated private static func deduplicatedDiagnostics(
        _ diagnostics: [SwiftCompilerDiagnostic]
    ) -> [SwiftCompilerDiagnostic] {
        var seen = Set<String>()
        return diagnostics.filter { diagnostic in
            let key = [
                diagnostic.relativePath ?? "",
                "\(diagnostic.line)",
                "\(diagnostic.column)",
                diagnostic.severity.rawValue,
                diagnostic.message
            ].joined(separator: "\u{1f}")
            return seen.insert(key).inserted
        }
    }

    nonisolated private static func deduplicatedSnippets(
        _ snippets: [ContentViewRepairSnippet]
    ) -> [ContentViewRepairSnippet] {
        var seen = Set<String>()
        return snippets.filter { snippet in
            let key = "\(snippet.startLine)-\(snippet.endLine)::\(snippet.text)"
            return seen.insert(key).inserted
        }
    }

    nonisolated private static func renderErrorLines(
        _ error: any Error,
        depth: Int
    ) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        let nsError = error as NSError
        var lines = [
            "\(indent)- type: \(String(reflecting: Swift.type(of: error)))",
            "\(indent)  localizedDescription: \(error.localizedDescription)",
            "\(indent)  description: \(String(describing: error))",
            "\(indent)  debugDescription: \(String(reflecting: error))",
            "\(indent)  nsError: domain=\(nsError.domain) code=\(nsError.code)"
        ]

        if !nsError.userInfo.isEmpty {
            let userInfo = nsError.userInfo
                .sorted { "\($0.key)" < "\($1.key)" }
                .map { key, value in
                    "\(key)=\(compact(String(describing: value), limit: 500))"
                }
                .joined(separator: "; ")
            lines.append("\(indent)  userInfo: \(userInfo)")
        }

        guard depth < 4 else {
            return lines
        }

        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            lines.append("\(indent)  underlyingError:")
            lines.append(contentsOf: renderErrorLines(underlying, depth: depth + 1))
        }

        for child in Mirror(reflecting: error).children {
            guard let label = child.label,
                  label.localizedCaseInsensitiveContains("error")
                    || label.localizedCaseInsensitiveContains("underlying")
            else {
                continue
            }

            if let childError = child.value as? any Error {
                lines.append("\(indent)  \(label):")
                lines.append(contentsOf: renderErrorLines(childError, depth: depth + 1))
            } else {
                lines.append("\(indent)  \(label): \(compact(String(describing: child.value), limit: 500))")
            }
        }

        return lines
    }

    nonisolated private static func shouldWrite(to logURL: URL) -> Bool {
        if IronsmithRuntimeEnvironment.isRunningTests, logURL == defaultURL {
            return false
        }

        return true
    }
}
