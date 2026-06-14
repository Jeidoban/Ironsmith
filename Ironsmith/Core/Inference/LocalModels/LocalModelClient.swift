import Foundation
#if canImport(Hub)
import Hub
#endif

struct LocalModelClient {
    var makeHubAPI: () throws -> Any
    var downloadModel: (String, @escaping @Sendable (Double) -> Void) async throws -> URL
    var deleteModel: (String) throws -> Void
}

extension LocalModelClient {
    static var live: Self {
        let manager = MLXLocalModelManager()
        return Self(
            makeHubAPI: {
                try manager.makeHubAPI()
            },
            downloadModel: { hubID, progressHandler in
                try await manager.downloadModel(hubID: hubID, progressHandler: progressHandler)
            },
            deleteModel: { hubID in
                try manager.deleteModel(hubID: hubID)
            }
        )
    }
}

struct MLXLocalModelManager {
    #if canImport(Hub)
    func makeHubAPI() throws -> HubApi {
        try IronsmithPaths.ensureDirectoriesExist()
        return HubApi(
            downloadBase: IronsmithPaths.modelsDirectory,
            cache: nil
        )
    }
    #else
    func makeHubAPI() throws -> Any {
        throw LocalModelClientError.mlxUnavailable
    }
    #endif

    func downloadModel(
        hubID: String,
        progressHandler: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        #if canImport(Hub)
        let hub = try makeHubAPI()
        let repo = Hub.Repo(id: hubID)
        return try await hub.snapshot(
            from: repo,
            matching: ["*.safetensors", "*.json", "*.jinja"],
            progressHandler: { progress in
                progressHandler(progress.fractionCompleted)
            }
        )
        #else
        throw LocalModelClientError.mlxUnavailable
        #endif
    }

    func deleteModel(hubID: String) throws {
        #if canImport(Hub)
        let hub = try makeHubAPI()
        let repo = Hub.Repo(id: hubID)
        let fileManager = FileManager.default

        let localModelDirectory = hub.localRepoLocation(repo)
        if fileManager.fileExists(atPath: localModelDirectory.path) {
            try fileManager.removeItem(at: localModelDirectory)
        }
        #else
        throw LocalModelClientError.mlxUnavailable
        #endif
    }
}

enum LocalModelClientError: LocalizedError {
    case mlxUnavailable

    var errorDescription: String? {
        switch self {
        case .mlxUnavailable:
            return "MLX local AI models are unavailable in this build."
        }
    }
}
