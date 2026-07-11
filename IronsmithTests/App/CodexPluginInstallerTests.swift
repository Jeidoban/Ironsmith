import Foundation
import Testing
@testable import Ironsmith

struct CodexPluginInstallerTests {
    @Test
    func installsBuildMacOSAppsFromOfficialMarketplace() async {
        let capture = CodexPluginInstallerCapture()
        let installer = CodexPluginInstaller.live(
            cliClient: CodexCLIClient { arguments in
                capture.record(arguments)
                return CodexCLIProcessResult(stdout: "{}", stderr: "", terminationStatus: 0)
            },
            appendDiagnostics: { message in
                capture.recordDiagnostic(message)
            }
        )

        await installer.install()

        #expect(capture.arguments == [
            "plugin",
            "add",
            "build-macos-apps@openai-curated",
            "--json",
        ])
        #expect(capture.diagnostic == nil)
    }

    @Test
    func logsCommandFailureWithoutThrowing() async {
        let capture = CodexPluginInstallerCapture()
        let installer = CodexPluginInstaller.live(
            cliClient: CodexCLIClient { _ in
                CodexCLIProcessResult(
                    stdout: "",
                    stderr: "marketplace unavailable",
                    terminationStatus: 1
                )
            },
            appendDiagnostics: { message in
                capture.recordDiagnostic(message)
            }
        )

        await installer.install()

        let diagnostic = capture.diagnostic
        #expect(diagnostic?.contains("plugin installation failed") == true)
        #expect(diagnostic?.contains("marketplace unavailable") == true)
    }
}

nonisolated private final class CodexPluginInstallerCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedArguments: [String]?
    private var recordedDiagnostic: String?

    var arguments: [String]? {
        lock.withLock { recordedArguments }
    }

    var diagnostic: String? {
        lock.withLock { recordedDiagnostic }
    }

    func record(_ arguments: [String]) {
        lock.withLock {
            recordedArguments = arguments
        }
    }

    func recordDiagnostic(_ diagnostic: String) {
        lock.withLock {
            recordedDiagnostic = diagnostic
        }
    }
}
