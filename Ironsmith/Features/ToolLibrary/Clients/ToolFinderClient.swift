import AppKit

struct ToolFinderClient {
    var showToolDirectory: (_ tool: Tool) async throws -> Void
    var revealURL: (_ url: URL) async throws -> Void
    var openURL: (_ url: URL) async throws -> Void

    init(
        showToolDirectory: @escaping (_ tool: Tool) async throws -> Void,
        revealURL: @escaping (_ url: URL) async throws -> Void,
        openURL: @escaping (_ url: URL) async throws -> Void = { _ in }
    ) {
        self.showToolDirectory = showToolDirectory
        self.revealURL = revealURL
        self.openURL = openURL
    }

    static let live = ToolFinderClient(
        showToolDirectory: { tool in
            let packageRootURL = tool.packageRootURL
            await MainActor.run {
                _ = NSWorkspace.shared.open(packageRootURL)
            }
        },
        revealURL: { url in
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        },
        openURL: { url in
            await MainActor.run {
                _ = NSWorkspace.shared.open(url)
            }
        }
    )
}
