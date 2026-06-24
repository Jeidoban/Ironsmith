//
//  ModelConfig.swift
//  Ironsmith
//

import Foundation

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

typealias ModelConfig = IronsmithSchemaV1.ModelConfig

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
