//
//  Tool.swift
//  Ironsmith
//

import Foundation

enum StoreAppNameComparison {
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCompatibilityMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

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
    case searchingStore
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

typealias Tool = IronsmithSchemaV9.Tool
typealias ToolStoreMetadata = IronsmithSchemaV9.StoreMetadata
typealias StorePublication = IronsmithSchemaV9.StorePublication
typealias StoreProvenance = IronsmithSchemaV9.StoreProvenance
typealias StoreVersionReference = IronsmithSchemaV9.StoreVersionReference

extension Tool {
    var storeMetadata: ToolStoreMetadata? {
        get {
            guard let storeMetadataData else { return nil }
            return try? JSONDecoder().decode(
                ToolStoreMetadata.self,
                from: storeMetadataData
            )
        }
        set {
            storeMetadataData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    var appVersionNumber: Int {
        max(1, storeMetadata?.publication?.versionNumber ?? 1)
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

    var storePublication: StorePublication? {
        get { storeMetadata?.publication }
        set {
            var metadata = storeMetadata ?? ToolStoreMetadata()
            metadata.publication = newValue
            storeMetadata = metadata.isEmpty ? nil : metadata
        }
    }

    var storeProvenance: StoreProvenance? {
        get { storeMetadata?.provenance }
        set {
            var metadata = storeMetadata ?? ToolStoreMetadata()
            metadata.provenance = newValue?.normalized
            storeMetadata = metadata.isEmpty ? nil : metadata
        }
    }

    var storeRemixSource: StoreVersionReference? {
        storeMetadata?.provenance?.remixSource
    }

    var storeInspirations: [StoreVersionReference] {
        storeMetadata?.provenance?.inspirations ?? []
    }

    var storeInspirationLinks: [StoreVersionReference] {
        var seenAppKeys = Set<String>()
        return storeInspirations.filter {
            seenAppKeys.insert($0.appId ?? $0.versionId).inserted
        }
    }

    var storeAttributionVersionIds: [String] {
        storeInspirations.map(\.versionId)
    }

    var storeBaselineSourceSha256: String? {
        storePublication?.sourceSha256 ?? storeRemixSource?.sourceSha256
    }

    func replaceStoreProvenance(
        remixSource: StoreVersionReference?,
        inspirations: [StoreVersionReference]
    ) {
        storeProvenance = StoreProvenance(
            remixSource: remixSource,
            inspirations: inspirations
        )
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
        packageRootURL.appendingPathComponent(
            "\(ToolNameSanitizer.appBundleName(from: name)).app", isDirectory: true)
    }
}

extension ToolStoreMetadata {
    var isEmpty: Bool {
        publication == nil && provenance == nil
    }
}

extension StoreProvenance {
    var normalized: Self? {
        var seenVersionIDs = Set<String>()
        if let remixSource {
            seenVersionIDs.insert(remixSource.versionId)
        }
        let uniqueInspirations = inspirations.filter {
            seenVersionIDs.insert($0.versionId).inserted
        }
        guard remixSource != nil || !uniqueInspirations.isEmpty else { return nil }
        return Self(remixSource: remixSource, inspirations: uniqueInspirations)
    }
}

extension StoreVersionReference {
    var isRoutable: Bool {
        storeId != nil && appId != nil
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
    static let generatedPrefix = "com.ironsmith.generated."

    static func make(executableName: String, id: UUID = UUID()) -> String {
        let component = bundleComponent(from: executableName)
        let suffix = id.uuidString.lowercased()
        return "\(generatedPrefix)\(component).\(suffix)"
    }

    static func isGeneratedApp(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return bundleIdentifier.hasPrefix(generatedPrefix)
    }

    private static func bundleComponent(from value: String) -> String {
        let asciiValue =
            value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789")
        let words =
            asciiValue
            .components(separatedBy: allowedCharacters.inverted)
            .filter { !$0.isEmpty }
        let component = words.joined(separator: "-")
        return component.isEmpty ? "tool" : String(component.prefix(48))
    }
}
