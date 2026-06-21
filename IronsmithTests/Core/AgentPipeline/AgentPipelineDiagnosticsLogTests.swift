import Foundation
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func diagnosticsLogWritesWhenPreferenceEnabled() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("diagnostics.log")
        let userDefaults = try Self.makeIsolatedUserDefaults()
        userDefaults.set(true, forKey: IronsmithPreferenceKeys.diagnosticsLoggingEnabled)

        AgentDiagnosticsLog.append("first entry", to: logURL, userDefaults: userDefaults)
        #expect(FileManager.default.fileExists(atPath: logURL.path))

        let afterFirst = try String(contentsOf: logURL, encoding: .utf8)
        #expect(afterFirst.contains("first entry"))

        AgentDiagnosticsLog.append("second entry", to: logURL, userDefaults: userDefaults)
        let afterSecond = try String(contentsOf: logURL, encoding: .utf8)
        #expect(afterSecond.contains("first entry"))
        #expect(afterSecond.contains("second entry"))
        #expect(afterSecond.count > afterFirst.count)
    }

    @Test
    func diagnosticsLogIsNoOpWhenPreferenceDisabled() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("diagnostics.log")
        let userDefaults = try Self.makeIsolatedUserDefaults()
        // Preference unset (default off).

        AgentDiagnosticsLog.append("ignored entry", to: logURL, userDefaults: userDefaults)

        #expect(!FileManager.default.fileExists(atPath: logURL.path))
    }

    @Test
    func diagnosticsLogSuppressesDefaultURLDuringTests() throws {
        let userDefaults = try Self.makeIsolatedUserDefaults()
        userDefaults.set(true, forKey: IronsmithPreferenceKeys.diagnosticsLoggingEnabled)

        let existedBefore = FileManager.default.fileExists(atPath: AgentDiagnosticsLog.defaultURL.path)

        // Default URL writes are suppressed under the test runtime even when enabled.
        AgentDiagnosticsLog.append("should not write to default URL", userDefaults: userDefaults)

        let existsAfter = FileManager.default.fileExists(atPath: AgentDiagnosticsLog.defaultURL.path)
        #expect(existsAfter == existedBefore)
    }

    @Test
    func diagnosticsLogCreatesMissingDirectory() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("diagnostics.log")
        let userDefaults = try Self.makeIsolatedUserDefaults()
        userDefaults.set(true, forKey: IronsmithPreferenceKeys.diagnosticsLoggingEnabled)

        AgentDiagnosticsLog.append("entry", to: logURL, userDefaults: userDefaults)

        #expect(FileManager.default.fileExists(atPath: logURL.path))
    }
}
