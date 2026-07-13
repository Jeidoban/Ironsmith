import Foundation

nonisolated struct CodexPluginInstaller: Sendable {
    var install: @Sendable () async -> Void
}

extension CodexPluginInstaller {
    nonisolated static func live(
        cliClient: CodexCLIClient = .live(),
        appendDiagnostics: @escaping @Sendable (String) -> Void = {
            AgentDiagnosticsLog.append($0)
        }
    ) -> Self {
        Self {
            do {
                let result = try await cliClient.run([
                    "plugin",
                    "add",
                    "build-macos-apps@openai-curated",
                    "--json",
                ])
                guard result.terminationStatus != 0 else { return }

                appendDiagnostics(
                    """
                    Build macOS Apps plugin installation failed.
                    status: \(result.terminationStatus)
                    output: \(AgentDiagnosticsLog.compact(result.combinedOutput, limit: 800))
                    """
                )
            } catch {
                appendDiagnostics(
                    """
                    Build macOS Apps plugin installation failed.
                    \(AgentDiagnosticsLog.renderError(error, limit: 800))
                    """
                )
            }
        }
    }
}
