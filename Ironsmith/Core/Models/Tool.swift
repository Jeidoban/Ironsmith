//
//  Tool.swift
//  Ironsmith
//

import Foundation

enum ToolGenerationState: String, Codable, CaseIterable, Equatable, Sendable {
    case ready
    case generating
    case stopped
    case failed
}

enum ToolGenerationPhase: String, Codable, CaseIterable, Equatable, Sendable {
    case initializing
    case planning
    case generatingIcon
    case waitingForIcon
    case refiningPrompt
    case generatingSource
    case generatingEditDiff
    case generatingRepairDiff
    case repairing
    case packaging
    case completed
}

enum ToolGenerationMode: String, Codable, CaseIterable, Equatable, Sendable {
    case create
    case edit
}

typealias Tool = IronsmithSchemaV4.Tool

extension Tool {
    var validatedMenuBarSystemImage: String {
        get {
            ToolMenuBarSymbol.validated(menuBarSystemImage)
        }
        set {
            menuBarSystemImage = ToolMenuBarSymbol.validated(newValue)
        }
    }

    var storedSandboxPermissions: GeneratedAppSandboxPermissions? {
        get {
            guard let sandboxPermissionRawValues else { return nil }
            return GeneratedAppSandboxPermissions(rawValueList: sandboxPermissionRawValues)
        }
        set {
            sandboxPermissionRawValues = newValue?.rawValueList
        }
    }

    var storedResourcePermissions: GeneratedAppResourcePermissions? {
        get {
            guard let resourcePermissionRawValues else { return nil }
            return GeneratedAppResourcePermissions(rawValueList: resourcePermissionRawValues)
        }
        set {
            resourcePermissionRawValues = newValue?.rawValueList
        }
    }

    func generationSettings(
        defaultSandboxPermissions: GeneratedAppSandboxPermissions,
        defaultResourcePermissions: GeneratedAppResourcePermissions
    ) -> ToolGenerationSettings {
        ToolGenerationSettings(
            appKind: appKind,
            menuBarSystemImage: validatedMenuBarSystemImage,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: storedSandboxPermissions ?? defaultSandboxPermissions,
            resourcePermissions: storedResourcePermissions ?? defaultResourcePermissions
        )
    }

    func generationSettings(defaults: ToolGenerationSettings) -> ToolGenerationSettings {
        generationSettings(
            defaultSandboxPermissions: defaults.sandboxPermissions,
            defaultResourcePermissions: defaults.resourcePermissions
        )
    }

    func applyGenerationSettings(_ settings: ToolGenerationSettings) {
        appKind = settings.appKind
        validatedMenuBarSystemImage = settings.menuBarSystemImage
        sandboxEnabled = settings.sandboxEnabled
        storedSandboxPermissions = settings.sandboxPermissions
        storedResourcePermissions = settings.resourcePermissions
    }

    var isGenerationReady: Bool {
        generationState == .ready
    }

    var isRebuildable: Bool {
        generationState == .ready || generationState == .failed
    }

    var packageRootURL: URL {
        URL(fileURLWithPath: packageRootPath, isDirectory: true)
    }

    var packageManifestURL: URL {
        packageRootURL.appendingPathComponent("Package.swift")
    }

    var packageLayout: ToolPackageLayout {
        ToolPackageLayout(packageRootURL: packageRootURL, executableName: executableName)
    }

    var contentViewSourcePath: String {
        packageLayout.contentViewSourcePath
    }

    var protocolsDirectoryURL: URL {
        packageRootURL.appendingPathComponent("Protocols", isDirectory: true)
    }

    var appBundleURL: URL {
        packageRootURL.appendingPathComponent("\(ToolNameSanitizer.appBundleName(from: name)).app", isDirectory: true)
    }
}

extension GeneratedAppResourcePermissions {
    nonisolated init(rawValueList: String) {
        let rawValues = Self.rawValues(from: rawValueList)
        self.init(
            GeneratedAppResourcePermission.allCases.filter { rawValues.contains($0.rawValue) }
        )
    }

    nonisolated var rawValueList: String {
        enabledPermissions.map(\.rawValue).joined(separator: ",")
    }

    nonisolated private static func rawValues(from rawValueList: String) -> Set<String> {
        Set(
            rawValueList
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

extension GeneratedAppSandboxPermissions {
    nonisolated init(rawValueList: String) {
        let rawValues = Self.rawValues(from: rawValueList)
        self.init(
            GeneratedAppSandboxPermission.allCases.filter { rawValues.contains($0.rawValue) }
        )
    }

    nonisolated var rawValueList: String {
        enabledPermissions.map(\.rawValue).joined(separator: ",")
    }

    nonisolated private static func rawValues(from rawValueList: String) -> Set<String> {
        Set(
            rawValueList
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

enum ToolBundleIdentifier {
    static func make(executableName: String, id: UUID = UUID()) -> String {
        let component = bundleComponent(from: executableName)
        let suffix = id.uuidString.lowercased()
        return "com.ironsmith.generated.\(component).\(suffix)"
    }

    private static func bundleComponent(from value: String) -> String {
        let asciiValue = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let words = asciiValue
            .components(separatedBy: allowedCharacters.inverted)
            .filter { !$0.isEmpty }
        let component = words.joined(separator: "-")
        return component.isEmpty ? "tool" : String(component.prefix(48))
    }
}
