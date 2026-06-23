import AnyLanguageModel
import Foundation

nonisolated struct AgentLanguageModelContext {
    let languageModel: any LanguageModel
    let metadataLanguageModel: any LanguageModel
    let options: GenerationOptions
    let repairStrategy: ToolRepairStrategy
    let promptRefinementEnabled: Bool
    let afterLanguageModelInvocation: @MainActor @Sendable () async -> Void

    init(
        languageModel: any LanguageModel,
        metadataLanguageModel: (any LanguageModel)?,
        options: GenerationOptions,
        repairStrategy: ToolRepairStrategy,
        promptRefinementEnabled: Bool = true,
        afterLanguageModelInvocation: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.languageModel = languageModel
        self.metadataLanguageModel = metadataLanguageModel ?? AnyLanguageModel.SystemLanguageModel.default
        self.options = options
        self.repairStrategy = repairStrategy
        self.promptRefinementEnabled = promptRefinementEnabled
        self.afterLanguageModelInvocation = afterLanguageModelInvocation
    }

    init(
        languageModel: any LanguageModel,
        options: GenerationOptions,
        repairStrategy: ToolRepairStrategy,
        promptRefinementEnabled: Bool = true,
        afterLanguageModelInvocation: @escaping @MainActor @Sendable () async -> Void = {}
    ) {
        self.init(
            languageModel: languageModel,
            metadataLanguageModel: nil,
            options: options,
            repairStrategy: repairStrategy,
            promptRefinementEnabled: promptRefinementEnabled,
            afterLanguageModelInvocation: afterLanguageModelInvocation
        )
    }
}

struct ToolManifest: Codable, Equatable, Sendable {
    var displayName: String
    var executableName: String
    var files: [ToolManifestFile]
}

struct ToolManifestFile: Codable, Equatable, Sendable {
    var path: String
    var description: String
}

enum ToolAppKind: String, Codable, CaseIterable, Equatable, Sendable {
    case window
    case menuBar = "menu_bar"

    var displayName: String {
        switch self {
        case .window: return "Window App"
        case .menuBar: return "Menu Bar App"
        }
    }
}

enum ToolMenuBarSymbol {
    nonisolated static let fallback = "hammer"

    nonisolated static let allowedSymbols = [
        "hammer",
        "wrench.and.screwdriver",
        "sparkles",
        "bolt",
        "clock",
        "timer",
        "calendar",
        "checkmark.circle",
        "list.bullet",
        "note.text",
        "tray",
        "folder",
        "doc.text",
        "magnifyingglass",
        "camera",
        "mic",
        "map",
        "location",
        "person.crop.circle",
        "chart.bar",
        "house",
        "dollarsign.circle",
        "cart",
        "gamecontroller",
        "paintbrush",
        "pencil",
        "book",
        "bell",
        "cloud",
        "globe",
        "link",
        "lock",
        "shield",
        "terminal",
    ]

    nonisolated static func validated(_ symbol: String?) -> String {
        guard let symbol = symbol?.trimmingCharacters(in: .whitespacesAndNewlines),
              allowedSymbols.contains(symbol)
        else {
            return fallback
        }
        return symbol
    }

}

struct ToolGenerationSettings: Equatable, Sendable {
    var appKind: ToolAppKind
    var menuBarSystemImage: String
    var sandboxEnabled: Bool
    var sandboxPermissions: GeneratedAppSandboxPermissions
    var resourcePermissions: GeneratedAppResourcePermissions

    nonisolated init(
        appKind: ToolAppKind = .window,
        menuBarSystemImage: String = ToolMenuBarSymbol.fallback,
        sandboxEnabled: Bool = true,
        sandboxPermissions: GeneratedAppSandboxPermissions = .default,
        resourcePermissions: GeneratedAppResourcePermissions = .none
    ) {
        self.appKind = appKind
        self.menuBarSystemImage = ToolMenuBarSymbol.validated(menuBarSystemImage)
        self.sandboxEnabled = sandboxEnabled
        self.sandboxPermissions = sandboxPermissions
        self.resourcePermissions = resourcePermissions
    }

    nonisolated static var `default`: ToolGenerationSettings {
        ToolGenerationSettings()
    }

    nonisolated func withMenuBarSystemImage(_ symbol: String) -> ToolGenerationSettings {
        ToolGenerationSettings(
            appKind: appKind,
            menuBarSystemImage: symbol,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions
        )
    }
}

enum ContentViewDeterministicEditOperation: String, Codable, CaseIterable, Equatable, Sendable {
    case addImport
    case addStateProperty
    case replaceLine
    case replaceSection
    case addHelperFunction
    case renameIdentifierInSection
}

struct ContentViewDeterministicEdit: Codable, Equatable, Sendable {
    let operation: ContentViewDeterministicEditOperation
    let target: String
    let replacement: String
    let section: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.operation == rhs.operation
            && lhs.target == rhs.target
            && lhs.replacement == rhs.replacement
            && lhs.section == rhs.section
    }
}

struct ToolGenerationResult: Equatable, Sendable {
    let toolName: String
    let executableName: String
    let bundleIdentifier: String
    let settings: ToolGenerationSettings
    let packageRootURL: URL
    let manifest: ToolManifest

    init(
        toolName: String,
        executableName: String,
        bundleIdentifier: String? = nil,
        settings: ToolGenerationSettings,
        packageRootURL: URL,
        manifest: ToolManifest
    ) {
        self.toolName = toolName
        self.executableName = executableName
        self.bundleIdentifier = bundleIdentifier ?? ToolBundleIdentifier.make(executableName: executableName)
        self.settings = settings
        self.packageRootURL = packageRootURL
        self.manifest = manifest
    }
}

enum ToolNameSanitizer {
    nonisolated static func displayName(fromPrompt prompt: String) -> String {
        let cleaned = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(5)
            .joined(separator: " ")

        return cleaned.isEmpty ? "Generated App" : cleaned.capitalized
    }

    nonisolated static func executableName(from displayName: String) -> String {
        let parts = displayName
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        var name = parts
            .map { part in
                let lowercased = part.lowercased()
                return lowercased.prefix(1).uppercased() + lowercased.dropFirst()
            }
            .joined()

        if name.isEmpty {
            name = "GeneratedTool"
        }

        if name.first?.isNumber == true {
            name = "Tool\(name)"
        }

        return String(name.prefix(48))
    }

    nonisolated static func slug(from displayName: String) -> String {
        let words = displayName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "generated-tool" : String(slug.prefix(64))
    }

    nonisolated static func appBundleName(from displayName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let name = displayName
            .components(separatedBy: invalidCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Ironsmith App" : String(name.prefix(80))
    }
}

struct ToolPackageLayout: Equatable, Sendable {
    nonisolated static let agentManifestFilename = "ironsmith-manifest.json"
    nonisolated static let packageMetadataDirectoryName = ".ironsmith"
    nonisolated static let versionsDirectoryName = "versions"
    nonisolated static let pendingContentViewDraftFilename = "pending-ContentView.swift"
    nonisolated static let pendingContentViewDraftPath = "\(packageMetadataDirectoryName)/\(pendingContentViewDraftFilename)"
    nonisolated static let pendingContentViewVersionFilename = "pending-ContentView.swift"
    nonisolated static let previousContentViewVersionFilename = "previous-ContentView.swift"
    nonisolated static let pendingBuildSettingsVersionFilename = "pending-build-settings.json"
    nonisolated static let previousBuildSettingsVersionFilename = "previous-build-settings.json"

    let packageRootURL: URL
    let executableName: String

    nonisolated var packageManifestURL: URL {
        packageRootURL.appendingPathComponent("Package.swift")
    }

    nonisolated var agentManifestURL: URL {
        packageRootURL.appendingPathComponent(Self.agentManifestFilename)
    }

    nonisolated var packageMetadataDirectoryURL: URL {
        Self.packageMetadataDirectoryURL(for: packageRootURL)
    }

    nonisolated var versionsDirectoryURL: URL {
        Self.versionsDirectoryURL(for: packageRootURL)
    }

    nonisolated var pendingContentViewDraftURL: URL {
        Self.pendingContentViewDraftURL(for: packageRootURL)
    }

    nonisolated var pendingContentViewVersionURL: URL {
        Self.pendingContentViewVersionURL(for: packageRootURL)
    }

    nonisolated var previousContentViewVersionURL: URL {
        Self.previousContentViewVersionURL(for: packageRootURL)
    }

    nonisolated var pendingBuildSettingsVersionURL: URL {
        Self.pendingBuildSettingsVersionURL(for: packageRootURL)
    }

    nonisolated var previousBuildSettingsVersionURL: URL {
        Self.previousBuildSettingsVersionURL(for: packageRootURL)
    }

    nonisolated var sourceDirectoryURL: URL {
        packageRootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: true)
    }

    nonisolated var appEntryFileName: String {
        "\(executableName).swift"
    }

    nonisolated var appEntrySourcePath: String {
        sourcePath(for: appEntryFileName)
    }

    nonisolated var appBundleURL: URL {
        packageRootURL.appendingPathComponent("\(executableName).app", isDirectory: true)
    }

    nonisolated var cachedAppIconPNGURL: URL {
        packageMetadataDirectoryURL.appendingPathComponent("AppIcon.png")
    }

    nonisolated var cachedAppIconICNSURL: URL {
        packageMetadataDirectoryURL.appendingPathComponent("AppIcon.icns")
    }

    nonisolated var sandboxEntitlementsURL: URL {
        Self.sandboxEntitlementsURL(for: packageRootURL)
    }

    nonisolated var defaultContentViewFileName: String {
        "ContentView.swift"
    }

    nonisolated func sourcePath(for fileName: String) -> String {
        "Sources/\(executableName)/\(fileName)"
    }

    nonisolated func packageFileURL(for path: String) throws -> URL {
        try Self.packageFileURL(for: path, packageRootURL: packageRootURL)
    }

    nonisolated static func packageMetadataDirectoryURL(for packageRootURL: URL) -> URL {
        packageRootURL.appendingPathComponent(packageMetadataDirectoryName, isDirectory: true)
    }

    nonisolated static func packageFileURL(for path: String, packageRootURL: URL) throws -> URL {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            throw AgentFileError.emptyPath
        }

        let root = packageRootURL.standardizedFileURL
        let candidate = trimmedPath.hasPrefix("/")
            ? URL(fileURLWithPath: trimmedPath)
            : root.appendingPathComponent(trimmedPath)
        let resolved = candidate.standardizedFileURL

        guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else {
            throw AgentFileError.pathEscapesPackage(path)
        }
        guard resolved.path != root.path else {
            throw AgentFileError.pathIsPackageRoot
        }
        return resolved
    }

    nonisolated static func versionsDirectoryURL(for packageRootURL: URL) -> URL {
        packageMetadataDirectoryURL(for: packageRootURL)
            .appendingPathComponent(versionsDirectoryName, isDirectory: true)
    }

    nonisolated static func pendingContentViewDraftURL(for packageRootURL: URL) -> URL {
        packageMetadataDirectoryURL(for: packageRootURL)
            .appendingPathComponent(pendingContentViewDraftFilename)
    }

    nonisolated static func pendingContentViewVersionURL(for packageRootURL: URL) -> URL {
        versionsDirectoryURL(for: packageRootURL)
            .appendingPathComponent(pendingContentViewVersionFilename)
    }

    nonisolated static func previousContentViewVersionURL(for packageRootURL: URL) -> URL {
        versionsDirectoryURL(for: packageRootURL)
            .appendingPathComponent(previousContentViewVersionFilename)
    }

    nonisolated static func pendingBuildSettingsVersionURL(for packageRootURL: URL) -> URL {
        versionsDirectoryURL(for: packageRootURL)
            .appendingPathComponent(pendingBuildSettingsVersionFilename)
    }

    nonisolated static func previousBuildSettingsVersionURL(for packageRootURL: URL) -> URL {
        versionsDirectoryURL(for: packageRootURL)
            .appendingPathComponent(previousBuildSettingsVersionFilename)
    }

    nonisolated static func sandboxEntitlementsURL(for packageRootURL: URL) -> URL {
        packageMetadataDirectoryURL(for: packageRootURL)
            .appendingPathComponent("sandbox.entitlements")
    }

    nonisolated func packageManifestContent() -> String {
        """
        // swift-tools-version: 6.2

        import PackageDescription

        let package = Package(
            name: "\(executableName)",
            platforms: [.macOS(.v26)],
            targets: [
                .executableTarget(
                    name: "\(executableName)"
                ),
            ],
            swiftLanguageModes: [.v6]
        )
        """
    }

    nonisolated func fixedAppEntrySource(
        displayName: String? = nil,
        settings: ToolGenerationSettings = .default
    ) -> String {
        switch settings.appKind {
        case .window:
            """
            import AppKit
            import SwiftUI

            @MainActor
            private final class IronsmithGeneratedAppDelegate: NSObject, NSApplicationDelegate {
                func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
                    Bundle.main.object(forInfoDictionaryKey: "IronsmithQuitOnLastWindowClose") as? Bool == true
                }
            }

            @main
            struct \(executableName): App {
                @NSApplicationDelegateAdaptor(IronsmithGeneratedAppDelegate.self) private var appDelegate

                var body: some Scene {
                    WindowGroup {
                        ContentView()
                    }
                }
            }
            """
        case .menuBar:
            """
            import AppKit
            import SwiftUI

            @main
            struct \(executableName): App {
                var body: some Scene {
                    MenuBarExtra(\(Self.swiftStringLiteral(displayName ?? executableName)), systemImage: \(Self.swiftStringLiteral(settings.menuBarSystemImage))) {
                        VStack(spacing: 0) {
                            HStack {
                                Text(\(Self.swiftStringLiteral(displayName ?? executableName)))
                                    .font(.headline)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer()

                                Button {
                                    NSApplication.shared.terminate(nil)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .imageScale(.medium)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Quit")
                                .accessibilityLabel("Quit")
                            }
                            .padding(.top, 10)
                            .padding(.bottom, 12)
                            .padding(.horizontal, 12)

                            ContentView()
                        }
                    }
                    .menuBarExtraStyle(.window)
                }
            }
            """
        }
    }

    nonisolated private static func swiftStringLiteral(_ value: String) -> String {
        String(reflecting: value)
    }
}
