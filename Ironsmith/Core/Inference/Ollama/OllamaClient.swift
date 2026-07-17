import Foundation

struct OllamaPullProgress: Equatable, Sendable {
    let status: String
    let completed: Int64?
    let total: Int64?

    var fractionCompleted: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

struct OllamaClient {
    var isInstalled: @Sendable () async -> Bool
    var startServer: @Sendable () async throws -> Void
    var pullModel: @Sendable (
        _ identifier: String,
        _ baseURLString: String,
        _ apiKey: String?,
        _ progress: @escaping @Sendable (OllamaPullProgress) async -> Void
    ) async throws -> Void
    var deleteModel: @Sendable (_ identifier: String, _ baseURLString: String, _ apiKey: String?) async throws -> Void

    nonisolated static let startCommand = """
    /usr/bin/open -g -a Ollama >/dev/null 2>&1 || (command -v ollama >/dev/null 2>&1 && nohup ollama serve >/dev/null 2>&1 &)
    """

    nonisolated static func noOp() -> Self {
        Self(
            isInstalled: { false },
            startServer: {},
            pullModel: { _, _, _, _ in },
            deleteModel: { _, _, _ in }
        )
    }

    nonisolated static var live: Self {
        Self(
            isInstalled: {
                (try? await runShellCommand("test -d /Applications/Ollama.app || command -v ollama >/dev/null 2>&1")) == true
            },
            startServer: {
                try await runThrowingShellCommand(Self.startCommand)
            },
            pullModel: { identifier, baseURLString, apiKey, progress in
                let request = try makePullRequest(baseURLString: baseURLString, modelIdentifier: identifier, apiKey: apiKey)
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OllamaClientError.invalidResponse
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw OllamaClientError.requestFailed(statusCode: httpResponse.statusCode)
                }

                for try await line in bytes.lines {
                    guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          let data = line.data(using: .utf8)
                    else {
                        continue
                    }
                    if let progressResponse = try? JSONDecoder().decode(PullResponse.self, from: data) {
                        await progress(
                            OllamaPullProgress(
                                status: progressResponse.status,
                                completed: progressResponse.completed,
                                total: progressResponse.total
                            )
                        )
                    }
                }
            },
            deleteModel: { identifier, baseURLString, apiKey in
                let request = try makeDeleteRequest(baseURLString: baseURLString, modelIdentifier: identifier, apiKey: apiKey)
                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OllamaClientError.invalidResponse
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    throw OllamaClientError.requestFailed(statusCode: httpResponse.statusCode)
                }
            }
        )
    }

    nonisolated static func makeTagsRequest(baseURLString: String, apiKey: String?) throws -> URLRequest {
        var request = URLRequest(url: try apiURL(baseURLString: baseURLString, path: "api/tags"))
        request.httpMethod = "GET"
        applyHeaders(to: &request, apiKey: apiKey)
        return request
    }

    nonisolated static func makePullRequest(baseURLString: String, modelIdentifier: String, apiKey: String?) throws -> URLRequest {
        var request = URLRequest(url: try apiURL(baseURLString: baseURLString, path: "api/pull"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(ModelRequest(model: modelIdentifier))
        applyHeaders(to: &request, apiKey: apiKey)
        return request
    }

    nonisolated static func makeDeleteRequest(baseURLString: String, modelIdentifier: String, apiKey: String?) throws -> URLRequest {
        var request = URLRequest(url: try apiURL(baseURLString: baseURLString, path: "api/delete"))
        request.httpMethod = "DELETE"
        request.httpBody = try JSONEncoder().encode(ModelRequest(model: modelIdentifier))
        applyHeaders(to: &request, apiKey: apiKey)
        return request
    }

    nonisolated private static func apiURL(baseURLString: String, path: String) throws -> URL {
        guard let baseURL = try? ProviderBaseURLValidator.validatedURL(from: baseURLString) else {
            throw OllamaClientError.invalidBaseURL
        }
        return baseURL.appendingPathComponent(path)
    }

    nonisolated private static func applyHeaders(to request: inout URLRequest, apiKey: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if request.httpBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    nonisolated private static func runShellCommand(_ command: String) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    nonisolated private static func runThrowingShellCommand(_ command: String) async throws {
        let succeeded = try await runShellCommand(command)
        guard succeeded else {
            throw OllamaClientError.startFailed
        }
    }
}

enum OllamaClientError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case requestFailed(statusCode: Int)
    case startFailed

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter a valid Ollama server URL."
        case .invalidResponse:
            return "Ollama did not return a valid response."
        case .requestFailed(let statusCode):
            return "Ollama returned HTTP \(statusCode)."
        case .startFailed:
            return "Could not start Ollama."
        }
    }
}

nonisolated private struct ModelRequest: Encodable {
    let model: String
}

nonisolated private struct PullResponse: Decodable, Sendable {
    let status: String
    let completed: Int64?
    let total: Int64?
}
