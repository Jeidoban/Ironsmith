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
    var packageRootPath: String
    var lastPromptSummary: String?
    var generationStateRawValue: String = ToolGenerationState.ready.rawValue
    var generationPhaseRawValue: String? = ToolGenerationPhase.completed.rawValue
    var generationModeRawValue: String?
    var pendingPrompt: String?
    var pendingRefinedPrompt: String?
    var generationErrorSummary: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        executableName: String? = nil,
        bundleIdentifier: String? = nil,
        sandboxEnabled: Bool = true,
        packageRootPath: String,
        lastPromptSummary: String? = nil,
        generationState: ToolGenerationState = .ready,
        generationPhase: ToolGenerationPhase? = .completed,
        generationMode: ToolGenerationMode? = nil,
        pendingPrompt: String? = nil,
        pendingRefinedPrompt: String? = nil,
        generationErrorSummary: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        let resolvedExecutableName = executableName ?? ToolNameSanitizer.executableName(from: name)
        self.executableName = resolvedExecutableName
        self.bundleIdentifier = bundleIdentifier ?? ToolBundleIdentifier.make(executableName: resolvedExecutableName)
        self.sandboxEnabled = sandboxEnabled
        self.packageRootPath = packageRootPath
        self.lastPromptSummary = lastPromptSummary
        self.generationStateRawValue = generationState.rawValue
        self.generationPhaseRawValue = generationPhase?.rawValue
        self.generationModeRawValue = generationMode?.rawValue
        self.pendingPrompt = pendingPrompt
        self.pendingRefinedPrompt = pendingRefinedPrompt
        self.generationErrorSummary = generationErrorSummary
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
