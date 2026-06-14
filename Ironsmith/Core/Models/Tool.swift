//
//  Tool.swift
//  Ironsmith
//

import Foundation
import SwiftData

@Model
final class Tool {
    @Attribute(.unique) var id: UUID
    var name: String
    var executableName: String
    var bundleIdentifier: String
    var sandboxEnabled: Bool
    var packageRootPath: String
    var lastPromptSummary: String?
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
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension Tool {
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
