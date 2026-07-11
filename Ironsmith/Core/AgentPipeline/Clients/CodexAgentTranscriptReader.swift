import Foundation

nonisolated struct CodexAgentTranscriptSnapshot: Equatable, Sendable {
    let url: URL?
    let entries: [CodexAgentTranscriptEntry]

    static let empty = Self(url: nil, entries: [])
}

nonisolated struct CodexAgentSessionMetadata: Codable, Equatable, Sendable {
    let providerIdentifier: String
    let toolCompatibility: CodexAgentToolCompatibility
    let transcriptFileName: String
}

nonisolated struct CodexAgentTranscriptEntry: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case threadStarted(String?)
        case turnStarted
        case turnCompleted
        case agentMessage(String)
        case commandExecution(command: String, status: String?, exitCode: Int?)
        case fileChange(changes: [CodexAgentFileChange], status: String?)
        case webSearch(search: CodexAgentWebSearch, status: String?)
        case error(String)
    }

    let id: Int
    let kind: Kind
}

enum CodexAgentTranscriptReader {
    nonisolated static func transcriptDirectoryURL(for packageRootURL: URL) -> URL {
        packageRootURL.appendingPathComponent(".codex", isDirectory: true)
    }

    nonisolated static func latestTranscriptURL(
        for packageRootURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        transcriptURLsByNewest(for: packageRootURL, fileManager: fileManager).first
    }

    nonisolated private static func transcriptURLsByNewest(
        for packageRootURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        let directoryURL = transcriptDirectoryURL(for: packageRootURL)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { url in
                url.lastPathComponent.hasPrefix("agent-") && url.pathExtension == "jsonl"
            }
            .compactMap { url -> (url: URL, date: Date)? in
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    return nil
                }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (url, date)
            }
            .sorted { lhs, rhs in lhs.date > rhs.date }
            .map(\.url)
    }

    nonisolated static func hasTranscript(
        for packageRootURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        latestTranscriptURL(for: packageRootURL, fileManager: fileManager) != nil
    }

    nonisolated static func snapshot(
        for packageRootURL: URL,
        fileManager: FileManager = .default
    ) throws -> CodexAgentTranscriptSnapshot {
        guard let url = latestTranscriptURL(for: packageRootURL, fileManager: fileManager) else {
            return .empty
        }
        return try snapshot(from: url)
    }

    nonisolated static func snapshot(from url: URL) throws -> CodexAgentTranscriptSnapshot {
        let text = try String(contentsOf: url, encoding: .utf8)
        let entries = text
            .split(whereSeparator: \.isNewline)
            .compactMap { CodexAgentEvent.parse(jsonLine: String($0)) }
            .timelineEntries()
        return CodexAgentTranscriptSnapshot(url: url, entries: entries)
    }

    nonisolated static func latestThreadID(
        for packageRootURL: URL,
        providerIdentifier: String,
        toolCompatibility: CodexAgentToolCompatibility,
        fileManager: FileManager = .default
    ) -> String? {
        for transcriptURL in transcriptURLsByNewest(
            for: packageRootURL,
            fileManager: fileManager
        ) {
            guard let metadata = try? metadata(for: transcriptURL),
                  metadata.providerIdentifier == providerIdentifier,
                  metadata.toolCompatibility == toolCompatibility,
                  metadata.transcriptFileName == transcriptURL.lastPathComponent
            else {
                continue
            }

            if let resolvedThreadID = try? threadID(from: transcriptURL) {
                return resolvedThreadID
            }
        }
        return nil
    }

    nonisolated static func metadataURL(for transcriptURL: URL) -> URL {
        transcriptURL
            .deletingPathExtension()
            .appendingPathExtension("metadata.json")
    }

    nonisolated static func writeMetadata(
        _ metadata: CodexAgentSessionMetadata,
        for transcriptURL: URL
    ) throws {
        let data = try JSONEncoder().encode(metadata)
        try data.write(to: metadataURL(for: transcriptURL), options: .atomic)
    }

    nonisolated static func metadata(
        for transcriptURL: URL
    ) throws -> CodexAgentSessionMetadata {
        let data = try Data(contentsOf: metadataURL(for: transcriptURL))
        return try JSONDecoder().decode(CodexAgentSessionMetadata.self, from: data)
    }

    nonisolated static func threadID(from url: URL) throws -> String? {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { CodexAgentEvent.parse(jsonLine: String($0)) }
            .compactMap { event -> String? in
                guard case .threadStarted(let id) = event else { return nil }
                return id?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .last { !$0.isEmpty }
    }
}

private extension Array where Element == CodexAgentEvent {
    nonisolated func timelineEntries() -> [CodexAgentTranscriptEntry] {
        var entries: [CodexAgentTranscriptEntry] = []
        var entryIndexByEventKey: [String: Int] = [:]

        for (lineIndex, event) in enumerated() {
            guard let kind = CodexAgentTranscriptEntry.Kind(event) else { continue }
            if let eventKey = event.timelineMergeKey,
               let entryIndex = entryIndexByEventKey[eventKey] {
                entries[entryIndex] = CodexAgentTranscriptEntry(
                    id: entries[entryIndex].id,
                    kind: kind
                )
            } else {
                if let eventKey = event.timelineMergeKey {
                    entryIndexByEventKey[eventKey] = entries.count
                }
                entries.append(CodexAgentTranscriptEntry(id: lineIndex, kind: kind))
            }
        }

        return entries
    }
}

private extension CodexAgentEvent {
    nonisolated var timelineMergeKey: String? {
        switch self {
        case .commandExecution(let id, let command, _, _):
            return id.map { "command:\($0)" } ?? "command:\(command)"
        case .fileChange(let id, let changes, _):
            let fallbackKey = changes.map { "\($0.kind ?? ""):\($0.path)" }.joined(separator: "|")
            return id.map { "file:\($0)" } ?? "file:\(fallbackKey)"
        case .webSearch(let id, let search, _):
            return id.map { "web-search:\($0)" } ?? "web-search:\(search.displayText)"
        case .threadStarted, .turnStarted, .turnCompleted, .agentMessage, .error:
            return nil
        }
    }
}

private extension CodexAgentTranscriptEntry.Kind {
    nonisolated init?(_ event: CodexAgentEvent) {
        switch event {
        case .threadStarted(let id):
            self = .threadStarted(id)
        case .turnStarted:
            self = .turnStarted
        case .turnCompleted:
            self = .turnCompleted
        case .agentMessage(let message):
            self = .agentMessage(message)
        case .commandExecution(_, let command, let status, let exitCode):
            self = .commandExecution(command: command, status: status, exitCode: exitCode)
        case .fileChange(_, let changes, let status):
            self = .fileChange(changes: changes, status: status)
        case .webSearch(_, let search, let status):
            self = .webSearch(search: search, status: status)
        case .error(let message):
            self = .error(message)
        }
    }
}
