//
//  ModelConfig.swift
//  Ironsmith
//

import Foundation

enum ModelSource: String, Codable, CaseIterable {
    case appleFoundation = "apple_foundation"
    // Legacy persisted value. V3 migration removes these rows and current app code no longer supports MLX.
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

typealias ModelConfig = IronsmithSchemaV3.ModelConfig

extension ModelConfig {
    static let appleFoundationIdentifier = "apple.foundation"

    var selectionIdentifier: String {
        "\(providerIdentifier)::\(identifier)"
    }

    var isRemote: Bool {
        source == .remote
    }

    var isPersistedLocalModel: Bool {
        providerIdentifier == ProviderConfig.localProviderIdentifier && source == .appleFoundation
    }
}
