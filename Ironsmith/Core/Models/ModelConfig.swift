//
//  ModelConfig.swift
//  Ironsmith
//

import Foundation
import SwiftData

enum ModelSource: String, Codable, CaseIterable {
    case appleFoundation = "apple_foundation"
    case mlx
    case remote
}

enum ModelInstallState: String, Codable, CaseIterable {
    case builtIn = "built_in"
    case downloadable
    case downloading
    case installed
    case failed
}

@Model
final class ModelConfig {
    @Attribute(.unique) var id: UUID
    var identifier: String
    var displayName: String
    var providerIdentifier: String
    var source: ModelSource
    // For MLX models, identifier IS the HuggingFace Hub ID (e.g. "mlx-community/gemma-4-e4b-it-4bit")
    var localDirectoryPath: String? // Path to downloaded model directory
    var downloadProgress: Double?   // 0–1 during download, nil otherwise
    var installStateRaw: String
    var estimatedToolCredits: Int?

    init(
        id: UUID = UUID(),
        identifier: String,
        displayName: String,
        providerIdentifier: String,
        source: ModelSource,
        installState: ModelInstallState = .downloadable,
        localDirectoryPath: String? = nil,
        downloadProgress: Double? = nil,
        estimatedToolCredits: Int? = nil
    ) {
        self.id = id
        self.identifier = identifier
        self.displayName = displayName
        self.providerIdentifier = providerIdentifier
        self.source = source
        self.installStateRaw = installState.rawValue
        self.localDirectoryPath = localDirectoryPath
        self.downloadProgress = downloadProgress
        self.estimatedToolCredits = estimatedToolCredits
    }
}

extension ModelConfig {
    static let appleFoundationIdentifier = "apple.foundation"

    var installState: ModelInstallState {
        get {
            if source == .appleFoundation { return .builtIn }
            return ModelInstallState(rawValue: installStateRaw) ?? .downloadable
        }
        set { installStateRaw = newValue.rawValue }
    }

    var selectionIdentifier: String {
        "\(providerIdentifier)::\(identifier)"
    }

    var isMLX: Bool {
        source == .mlx
    }

    var isRemote: Bool {
        source == .remote
    }

    var isPersistedLocalModel: Bool {
        providerIdentifier == ProviderConfig.localProviderIdentifier && source != .remote
    }
}
