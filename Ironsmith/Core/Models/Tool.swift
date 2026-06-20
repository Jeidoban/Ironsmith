//
//  Tool.swift
//  Ironsmith
//

import Foundation
import SwiftData

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

@Model
final class Tool {
    @Attribute(.unique) var id: UUID
    var name: String
    var executableName: String
    var bundleIdentifier: String
    var sandboxEnabled: Bool
    var appKindRawValue: String = ToolAppKind.window.rawValue
    var menuBarSystemImage: String = ToolMenuBarSymbol.fallback
    var sandboxPermissionRawValues: String?
    var resourcePermissionRawValues: String?
    var packageRootPath: String
    var generationStateRawValue: String = ToolGenerationState.ready.rawValue
    var generationPhaseRawValue: String? = ToolGenerationPhase.completed.rawValue
    var generationModeRawValue: String?
    var pendingPrompt: String?
    var generationErrorSummary: String?
    var generationRepairErrorCount: Int? = nil
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        executableName: String? = nil,
        bundleIdentifier: String? = nil,
        sandboxEnabled: Bool = true,
        appKind: ToolAppKind = .window,
        menuBarSystemImage: String = ToolMenuBarSymbol.fallback,
        sandboxPermissions: GeneratedAppSandboxPermissions? = nil,
        resourcePermissions: GeneratedAppResourcePermissions? = nil,
        packageRootPath: String,
        generationState: ToolGenerationState = .ready,
        generationPhase: ToolGenerationPhase? = .completed,
        generationMode: ToolGenerationMode? = nil,
        pendingPrompt: String? = nil,
        generationErrorSummary: String? = nil,
        generationRepairErrorCount: Int? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        let resolvedExecutableName = executableName ?? ToolNameSanitizer.executableName(from: name)
        self.executableName = resolvedExecutableName
        self.bundleIdentifier = bundleIdentifier ?? ToolBundleIdentifier.make(executableName: resolvedExecutableName)
        self.sandboxEnabled = sandboxEnabled
        self.appKindRawValue = appKind.rawValue
        self.menuBarSystemImage = ToolMenuBarSymbol.validated(menuBarSystemImage)
        self.sandboxPermissionRawValues = sandboxPermissions?.rawValueList
        self.resourcePermissionRawValues = resourcePermissions?.rawValueList
        self.packageRootPath = packageRootPath
        self.generationStateRawValue = generationState.rawValue
        self.generationPhaseRawValue = generationPhase?.rawValue
        self.generationModeRawValue = generationMode?.rawValue
        self.pendingPrompt = pendingPrompt
        self.generationErrorSummary = generationErrorSummary
        self.generationRepairErrorCount = generationRepairErrorCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Tool {
    var generationState: ToolGenerationState {
        get { ToolGenerationState(rawValue: generationStateRawValue) ?? .ready }
        set { generationStateRawValue = newValue.rawValue }
    }

    var generationPhase: ToolGenerationPhase? {
        get {
            generationPhaseRawValue.flatMap(ToolGenerationPhase.init(rawValue:))
        }
        set {
            generationPhaseRawValue = newValue?.rawValue
        }
    }

    var generationMode: ToolGenerationMode? {
        get {
            generationModeRawValue.flatMap(ToolGenerationMode.init(rawValue:))
        }
        set {
            generationModeRawValue = newValue?.rawValue
        }
    }

    var appKind: ToolAppKind {
        get {
            ToolAppKind(rawValue: appKindRawValue) ?? .window
        }
        set {
            appKindRawValue = newValue.rawValue
        }
    }

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

    var packageRootURL: URL {
        URL(fileURLWithPath: packageRootPath, isDirectory: true)
    }

    var packageManifestURL: URL {
        packageRootURL.appendingPathComponent("Package.swift")
    }

    var agentManifestURL: URL {
        packageRootURL.appendingPathComponent(ToolPackageLayout.agentManifestFilename)
    }

    var manifestURL: URL {
        agentManifestURL
    }

    var protocolsDirectoryURL: URL {
        packageRootURL.appendingPathComponent("Protocols", isDirectory: true)
    }

    var appBundleURL: URL {
        packageRootURL.appendingPathComponent("\(ToolNameSanitizer.appBundleName(from: name)).app", isDirectory: true)
    }
}

extension GeneratedAppResourcePermissions {
    init(rawValueList: String) {
        let rawValues = Self.rawValues(from: rawValueList)
        self.init(
            GeneratedAppResourcePermission.allCases.filter { rawValues.contains($0.rawValue) }
        )
    }

    var rawValueList: String {
        enabledPermissions.map(\.rawValue).joined(separator: ",")
    }

    private static func rawValues(from rawValueList: String) -> Set<String> {
        Set(
            rawValueList
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }
}

extension GeneratedAppSandboxPermissions {
    init(rawValueList: String) {
        let rawValues = Self.rawValues(from: rawValueList)
        self.init(
            GeneratedAppSandboxPermission.allCases.filter { rawValues.contains($0.rawValue) }
        )
    }

    var rawValueList: String {
        enabledPermissions.map(\.rawValue).joined(separator: ",")
    }

    private static func rawValues(from rawValueList: String) -> Set<String> {
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
