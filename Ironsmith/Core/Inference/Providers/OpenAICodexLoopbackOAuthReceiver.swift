/*
 Legacy PKCE loopback OAuth receiver, commented out for reference only. The live
 ChatGPT/Codex sign-in path invokes Codex CLI and reads auth.json from
 Ironsmith's CODEX_HOME.

import Foundation
@preconcurrency import Network

// Commented-out legacy implementation: Codex CLI now owns ChatGPT browser login and
// writes auth.json under Ironsmith's CODEX_HOME. This receiver is not used by
// the live OpenAICodexAuthClient path.
nonisolated final class OpenAICodexLoopbackOAuthReceiver {
    private let port: UInt16
    private let path: String
    private let expectedState: String
    private let timeout: TimeInterval

    init(
        port: UInt16,
        path: String,
        expectedState: String,
        timeout: TimeInterval = 5 * 60
    ) {
        self.port = port
        self.path = path
        self.expectedState = expectedState
        self.timeout = timeout
    }

    func receiveCode(
        launchAuthorizationURL: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        let listener = try makeListener()
        let callback = OpenAICodexCallbackContinuation()
        let readiness = OpenAICodexListenerReadiness()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readiness.resume()
            case .failed(let error), .waiting(let error):
                readiness.resume(throwing: error)
            default:
                break
            }
        }
        listener.newConnectionHandler = { [path, expectedState] connection in
            connection.start(queue: .global(qos: .userInitiated))
            Self.receiveCallback(
                connection: connection,
                expectedPath: path,
                expectedState: expectedState,
                callback: callback
            )
        }
        listener.start(queue: .global(qos: .userInitiated))

        do {
            try await readiness.wait()
            try await launchAuthorizationURL()
            return try await waitForCallback(callback, listener: listener)
        } catch {
            listener.cancel()
            throw error
        }
    }

    private func makeListener() throws -> NWListener {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw OpenAICodexAuthClientError.invalidCallback
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        return try NWListener(using: parameters, on: nwPort)
    }

    private func waitForCallback(
        _ callback: OpenAICodexCallbackContinuation,
        listener: NWListener
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await callback.value()
            }
            group.addTask { [timeout] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw OpenAICodexAuthClientError.callbackTimedOut
            }

            guard let result = try await group.next() else {
                throw OpenAICodexAuthClientError.invalidCallback
            }
            group.cancelAll()
            listener.cancel()
            return result
        }
    }

    private static func receiveCallback(
        connection: NWConnection,
        expectedPath: String,
        expectedState: String,
        callback: OpenAICodexCallbackContinuation
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, error in
            if let error {
                callback.resume(throwing: error)
                connection.cancel()
                return
            }

            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let result = parseCallback(
                    request: request,
                    expectedPath: expectedPath,
                    expectedState: expectedState
                  )
            else {
                sendResponse("Invalid ChatGPT sign-in callback.", status: 400, connection: connection)
                callback.resume(throwing: OpenAICodexAuthClientError.invalidCallback)
                return
            }

            switch result {
            case .success(let code):
                sendResponse("ChatGPT sign-in complete. You can close this window.", status: 200, connection: connection)
                callback.resume(returning: code)
            case .failure(let error):
                sendResponse("ChatGPT sign-in failed.", status: 400, connection: connection)
                callback.resume(throwing: error)
            }
        }
    }

    private static func parseCallback(
        request: String,
        expectedPath: String,
        expectedState: String
    ) -> Result<String, Error>? {
        guard let requestLine = request.components(separatedBy: "\r\n").first else {
            return nil
        }
        let pieces = requestLine.split(separator: " ")
        guard pieces.count >= 2 else {
            return nil
        }

        let rawPath = String(pieces[1])
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.percentEncodedPath = rawPath.components(separatedBy: "?").first ?? rawPath
        if let queryStart = rawPath.firstIndex(of: "?") {
            components.percentEncodedQuery = String(rawPath[rawPath.index(after: queryStart)...])
        }

        guard components.path == expectedPath else {
            return .failure(OpenAICodexAuthClientError.invalidCallback)
        }

        let queryItems = components.queryItems ?? []
        let state = queryItems.first { $0.name == "state" }?.value
        guard state == expectedState else {
            return .failure(OpenAICodexAuthClientError.stateMismatch)
        }

        if let error = queryItems.first(where: { $0.name == "error" })?.value {
            let description = queryItems.first(where: { $0.name == "error_description" })?.value
            return .failure(OpenAICodexAuthClientError.oauthFailed(description ?? error))
        }

        guard let code = queryItems.first(where: { $0.name == "code" })?.value,
              !code.isEmpty
        else {
            return .failure(OpenAICodexAuthClientError.invalidCallback)
        }
        return .success(code)
    }

    private static func sendResponse(_ message: String, status: Int, connection: NWConnection) {
        let statusText = status == 200 ? "OK" : "Bad Request"
        let body = """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>Ironsmith</title></head>
        <body><p>\(message)</p><script>setTimeout(() => window.close(), 1200)</script></body>
        </html>
        """
        let response = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(Data(body.utf8).count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private actor OpenAICodexCallbackContinuation {
    private var continuation: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?

    func value() async throws -> String {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    nonisolated func resume(returning value: String) {
        Task {
            await complete(.success(value))
        }
    }

    nonisolated func resume(throwing error: Error) {
        Task {
            await complete(.failure(error))
        }
    }

    private func complete(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}

private actor OpenAICodexListenerReadiness {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    nonisolated func resume() {
        Task {
            await complete(.success(()))
        }
    }

    nonisolated func resume(throwing error: Error) {
        Task {
            await complete(.failure(error))
        }
    }

    private func complete(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
*/
