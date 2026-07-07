import Foundation

struct LocalModelClient {
    var makeHubAPI: () throws -> Any
    var downloadModel: (String, @escaping @Sendable (Double) -> Void) async throws -> URL
    var deleteModel: (String) throws -> Void
}

extension LocalModelClient {
    static var live: Self {
        return Self(
            makeHubAPI: {
                throw LocalModelClientError.unavailable
            },
            downloadModel: { _, _ in
                throw LocalModelClientError.unavailable
            },
            deleteModel: { _ in
                throw LocalModelClientError.unavailable
            }
        )
    }
}

enum LocalModelClientError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Direct local AI model downloads are unavailable in this build."
        }
    }
}
