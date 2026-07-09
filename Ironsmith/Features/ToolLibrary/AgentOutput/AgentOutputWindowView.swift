import AppKit
import SwiftData
import SwiftUI

struct AgentOutputWindowView: View {
    let toolID: UUID

    @Query(sort: \Tool.updatedAt, order: .reverse) private var tools: [Tool]
    @State private var snapshot = CodexAgentTranscriptSnapshot.empty
    @State private var loadError: String?

    private var tool: Tool? {
        tools.first { $0.id == toolID }
    }

    private var isWorking: Bool {
        tool?.generationState == .generating
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if let tool {
                timeline(for: tool)
            } else {
                emptyState("App not found")
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task(id: reloadTaskID) {
            await reloadLoop()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let tool {
                AgentOutputToolIconView(tool: tool)
                    .frame(width: 34, height: 34)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(tool?.name ?? "Agent Output")
                    .font(.headline)
                    .lineLimit(1)

                Text(isWorking ? "Codex is working" : "Codex output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Codex is working")
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private func timeline(for tool: Tool) -> some View {
        if let loadError {
            emptyState(loadError)
        } else if snapshot.entries.isEmpty {
            VStack(spacing: 12) {
                emptyState(isWorking ? "Waiting for Codex output" : "No Codex output")
                if isWorking {
                    workingRow
                        .padding(.horizontal, 18)
                        .padding(.bottom, 18)
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(snapshot.entries) { entry in
                            AgentOutputEventRow(
                                entry: entry,
                                packageRootURL: tool.packageRootURL
                            )
                            .id(entry.id)
                        }

                        if isWorking {
                            workingRow
                                .padding(.bottom, 22)
                                .id("working")
                        }
                    }
                    .padding(18)
                }
                .background(.quaternary.opacity(0.18))
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: snapshot.entries.count) { _, _ in
                    scrollToBottom(proxy)
                }
            }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.18))
    }

    private var workingRow: some View {
        AgentOutputWorkingRow()
            .padding(.leading, 34)
    }

    private var reloadTaskID: String {
        [
            toolID.uuidString,
            tool?.packageRootPath ?? "",
            tool?.generationState.rawValue ?? "",
        ].joined(separator: "|")
    }

    private func reloadLoop() async {
        reloadTranscript()
        while !Task.isCancelled && isWorking {
            try? await Task.sleep(nanoseconds: 750_000_000)
            reloadTranscript()
        }
    }

    private func reloadTranscript() {
        guard let tool else {
            snapshot = .empty
            loadError = nil
            return
        }

        do {
            snapshot = try CodexAgentTranscriptReader.snapshot(for: tool.packageRootURL)
            loadError = nil
        } catch {
            snapshot = .empty
            loadError = error.localizedDescription
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard isWorking else { return }
        Task { @MainActor in
            if snapshot.entries.isEmpty {
                proxy.scrollTo("working", anchor: .bottom)
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("working", anchor: .bottom)
                }
            }
        }
    }
}

private struct AgentOutputToolIconView: View {
    let tool: Tool
    @State private var iconImage: NSImage?

    var body: some View {
        ZStack {
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 34, height: 34)
                    .clipped()
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(.tint.opacity(0.12))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary.opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .task(id: loadKey) {
            await loadIcon()
        }
    }

    private var loadKey: AgentOutputToolIconLoadKey {
        AgentOutputToolIconLoadKey(
            path: tool.packageLayout.cachedAppIconPNGURL.path,
            updatedAt: tool.updatedAt
        )
    }

    private func loadIcon() async {
        let key = loadKey.cacheKey
        if let cachedImage = AgentOutputToolIconImageCache.image(for: key) {
            iconImage = cachedImage
            return
        }

        let path = loadKey.path
        let data = await Task.detached(priority: .utility) {
            Self.loadIconData(atPath: path)
        }.value
        guard !Task.isCancelled else { return }
        guard let data, let image = NSImage(data: data) else {
            iconImage = nil
            return
        }

        AgentOutputToolIconImageCache.insert(image, for: key)
        iconImage = image
    }

    nonisolated private static func loadIconData(atPath path: String) -> Data? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }
}

private struct AgentOutputToolIconLoadKey: Hashable {
    let path: String
    let updatedAt: Date

    var cacheKey: String {
        "\(path)#\(updatedAt.timeIntervalSinceReferenceDate)"
    }
}

@MainActor
private enum AgentOutputToolIconImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    static func insert(_ image: NSImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

private struct AgentOutputEventRow: View {
    let entry: CodexAgentTranscriptEntry
    let packageRootURL: URL

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 24, height: 24)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 6) {
                switch entry.kind {
                case .threadStarted(let id):
                    compactText(
                        id.map { "Codex session started: \($0)" } ?? "Codex session started")
                case .turnStarted:
                    compactText("Codex turn started")
                case .turnCompleted:
                    compactText("Codex turn completed")
                case .agentMessage(let message):
                    Text(markdownAttributedString(message, packageRootURL: packageRootURL))
                        .font(.callout)
                        .environment(
                            \.openURL,
                            OpenURLAction { url in
                                AgentOutputLinkOpener.open(url)
                                return .handled
                            })
                case .commandExecution(let command, let status, let exitCode):
                    commandRow(command: command, status: status, exitCode: exitCode)
                case .fileChange(let changes, let status):
                    fileChangeRow(changes: changes, status: status)
                case .error(let message):
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private var icon: some View {
        Image(systemName: iconName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(iconStyle)
            .frame(width: 24, height: 24)
            .background(iconStyle.opacity(0.12), in: Circle())
    }

    private var iconName: String {
        switch entry.kind {
        case .agentMessage:
            return "sparkles"
        case .commandExecution:
            return "terminal"
        case .fileChange:
            return "doc.text"
        case .error:
            return "exclamationmark.triangle.fill"
        case .threadStarted, .turnStarted, .turnCompleted:
            return "circle.fill"
        }
    }

    private var iconStyle: Color {
        switch entry.kind {
        case .agentMessage:
            return .accentColor
        case .commandExecution(_, let status, let exitCode):
            if let exitCode, exitCode != 0 { return .red }
            if status == "failed" { return .red }
            if status == "completed" { return .green }
            return .secondary
        case .fileChange(_, let status):
            if status == "failed" { return .red }
            if status == "completed" { return .green }
            return .secondary
        case .error:
            return .red
        case .threadStarted, .turnStarted, .turnCompleted:
            return .secondary
        }
    }

    private func compactText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private func commandRow(command: String, status: String?, exitCode: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let statusText = commandStatusText(status: status, exitCode: exitCode) {
                    Text(statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(commandStatusStyle(status: status, exitCode: exitCode))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            commandStatusStyle(status: status, exitCode: exitCode).opacity(0.12),
                            in: Capsule()
                        )
                        .help(commandStatusHelpText(status: status, exitCode: exitCode))
                }
            }

            Text(command)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(5)
        }
    }

    private func fileChangeRow(changes: [CodexAgentFileChange], status: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("File change")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let statusText = CodexAgentStatusFormatter.displayText(status) {
                    Text(statusText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusStyle(status: status, exitCode: nil))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            statusStyle(status: status, exitCode: nil).opacity(0.12),
                            in: Capsule()
                        )
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        if let kind = CodexAgentStatusFormatter.displayText(change.kind) {
                            Text(kind)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.12), in: Capsule())
                        }

                        Text(CodexAgentPathDisplay.compact(change.path))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func commandStatusText(status: String?, exitCode: Int?) -> String? {
        if let exitCode {
            return exitCode == 0 ? "Completed" : "Completed with issues"
        }
        return CodexAgentStatusFormatter.displayText(status)
    }

    private func commandStatusHelpText(status: String?, exitCode: Int?) -> String {
        if let exitCode, exitCode != 0 {
            return "The command did not do exactly what it was supposed to."
        }
        if status == "failed" {
            return "The command did not do exactly what it was supposed to."
        }
        return ""
    }

    private func commandStatusStyle(status: String?, exitCode: Int?) -> Color {
        statusStyle(status: status, exitCode: exitCode)
    }

    private func statusStyle(status: String?, exitCode: Int?) -> Color {
        if let exitCode {
            return exitCode == 0 ? .green : .red
        }
        switch status {
        case "completed":
            return .green
        case "failed":
            return .red
        default:
            return .secondary
        }
    }

    private func markdownAttributedString(_ message: String, packageRootURL: URL)
        -> AttributedString
    {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var attributedString =
            (try? AttributedString(
                markdown: trimmed,
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace
                )
            )) ?? AttributedString(trimmed)
        attributedString.resolveFileLinks(relativeTo: packageRootURL)
        return attributedString
    }
}

private struct AgentOutputWorkingRow: View {
    @State private var isBright = false

    var body: some View {
        Text("Codex is working...")
            .font(.callout)
            .foregroundStyle(.secondary)
            .opacity(isBright ? 1 : 0.45)
            .padding(.vertical, 6)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    isBright = true
                }
            }
    }
}

extension AttributedString {
    fileprivate mutating func resolveFileLinks(relativeTo packageRootURL: URL) {
        for run in runs {
            guard let link = run.link,
                let resolvedURL = AgentOutputFileLinkResolver.resolvedURL(
                    for: link,
                    relativeTo: packageRootURL
                )
            else { continue }
            self[run.range].link = resolvedURL
        }
    }
}

private enum AgentOutputFileLinkResolver {
    nonisolated static func resolvedURL(for link: URL, relativeTo packageRootURL: URL) -> URL? {
        if link.isFileURL {
            return link
        }

        guard link.scheme == nil else {
            return nil
        }

        let rawPath = link.relativeString.removingPercentEncoding ?? link.relativeString
        guard !rawPath.isEmpty else { return nil }

        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath)
        }

        return packageRootURL.appendingPathComponent(rawPath)
    }
}

private enum AgentOutputLinkOpener {
    @MainActor
    static func open(_ url: URL) {
        if url.isFileURL {
            if !NSWorkspace.shared.open(url) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}
