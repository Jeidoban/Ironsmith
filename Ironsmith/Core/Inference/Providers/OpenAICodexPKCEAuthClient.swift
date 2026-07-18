import AppKit
import CryptoKit
import Foundation
import Network
import Security

nonisolated struct OpenAICodexPKCEAuthClient: Sendable {
    var signIn: @Sendable () async throws -> OpenAICodexCredential
}

extension OpenAICodexPKCEAuthClient {
    nonisolated static func live(
        generatePKCE: @escaping @Sendable () throws -> OpenAICodexPKCE = {
            try OpenAICodexPKCE.generate()
        },
        stateGenerator: @escaping @Sendable () -> String = {
            OpenAICodexPKCE.randomBase64URL(byteCount: 16)
        },
        launchAuthorizationURL: @escaping @MainActor @Sendable (URL) async throws -> Void = { url in
            guard NSWorkspace.shared.open(url) else {
                throw OpenAICodexAuthClientError.oauthSignInFailed("Could not open the ChatGPT sign-in page.")
            }
        },
        callbackServer: OpenAICodexOAuthCallbackServer = .live(),
        exchangeAuthorizationCode: @escaping @Sendable (_ code: String, _ verifier: String) async throws -> OpenAICodexCredential = { code, verifier in
            try await Self.exchangeAuthorizationCode(code: code, verifier: verifier)
        }
    ) -> Self {
        let signInCoordinator = OpenAICodexPKCESignInCoordinator()
        return Self(
            signIn: {
                try await signInCoordinator.replaceActiveSignIn {
                    let pkce = try generatePKCE()
                    let state = stateGenerator()
                    let authorizationURL = try authorizationURL(pkce: pkce, state: state)
                    let code = try await callbackServer.authorizationCode(state) {
                        try await launchAuthorizationURL(authorizationURL)
                    }
                    return try await exchangeAuthorizationCode(code, pkce.verifier)
                }
            }
        )
    }

    nonisolated static var unconfigured: Self {
        Self(signIn: { throw OpenAICodexAuthClientError.missingCredential })
    }

    nonisolated static func authorizationURL(pkce: OpenAICodexPKCE, state: String) throws -> URL {
        var components = URLComponents(url: OpenAICodexBackend.authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: OpenAICodexBackend.clientID),
            URLQueryItem(name: "redirect_uri", value: OpenAICodexBackend.redirectURI),
            URLQueryItem(name: "scope", value: OpenAICodexBackend.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: OpenAICodexBackend.originator),
        ]
        guard let url = components?.url else {
            throw OpenAICodexAuthClientError.invalidOAuthAuthorizationURL
        }
        return url
    }

    nonisolated static func exchangeAuthorizationCode(
        code: String,
        verifier: String
    ) async throws -> OpenAICodexCredential {
        let response: OpenAICodexTokenResponse = try await OpenAICodexAuthClient.tokenRequest(
            form: [
                "grant_type": "authorization_code",
                "client_id": OpenAICodexBackend.clientID,
                "code": code,
                "code_verifier": verifier,
                "redirect_uri": OpenAICodexBackend.redirectURI,
            ]
        )
        return OpenAICodexAuthClient.credential(from: response)
    }
}

private actor OpenAICodexPKCESignInCoordinator {
    private struct ActiveSignIn {
        let id: UUID
        let task: Task<OpenAICodexCredential, Error>
    }

    private var activeSignIn: ActiveSignIn?

    func replaceActiveSignIn(
        operation: @escaping @Sendable () async throws -> OpenAICodexCredential
    ) async throws -> OpenAICodexCredential {
        while let previousSignIn = activeSignIn {
            previousSignIn.task.cancel()
            _ = await previousSignIn.task.result
            if activeSignIn?.id == previousSignIn.id {
                activeSignIn = nil
            }
        }

        try Task.checkCancellation()
        let id = UUID()
        let task = Task {
            try await operation()
        }
        activeSignIn = ActiveSignIn(id: id, task: task)

        do {
            let credential = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            clearActiveSignIn(id: id)
            return credential
        } catch {
            clearActiveSignIn(id: id)
            throw error
        }
    }

    private func clearActiveSignIn(id: UUID) {
        guard activeSignIn?.id == id else { return }
        activeSignIn = nil
    }
}

nonisolated struct OpenAICodexPKCE: Equatable, Sendable {
    var verifier: String
    var challenge: String

    nonisolated static func generate() throws -> Self {
        let verifier = randomBase64URL(byteCount: 32)
        guard let verifierData = verifier.data(using: .ascii) else {
            throw OpenAICodexAuthClientError.invalidOAuthAuthorizationURL
        }
        let digest = SHA256.hash(data: verifierData)
        return Self(
            verifier: verifier,
            challenge: Data(digest).base64URLEncodedString()
        )
    }

    nonisolated static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...UInt8.max) }
        }
        return Data(bytes).base64URLEncodedString()
    }
}

nonisolated struct OpenAICodexOAuthCallbackServer: Sendable {
    var authorizationCode:
        @Sendable (_ expectedState: String, _ launchAuthorizationURL: @escaping @Sendable () async throws -> Void) async throws -> String
}

extension OpenAICodexOAuthCallbackServer {
    nonisolated static func live(timeout: TimeInterval = 5 * 60) -> Self {
        Self(
            authorizationCode: { expectedState, launchAuthorizationURL in
                try await OpenAICodexLoopbackOAuthServer.authorizationCode(
                    expectedState: expectedState,
                    timeout: timeout,
                    launchAuthorizationURL: launchAuthorizationURL
                )
            }
        )
    }
}

nonisolated private final class OpenAICodexLoopbackOAuthServer: @unchecked Sendable {
    private let expectedState: String
    private let listener: NWListener
    private var continuation: CheckedContinuation<String, Error>?
    private var didResume = false

    nonisolated private init(expectedState: String) throws {
        self.expectedState = expectedState
        self.listener = try NWListener(
            using: .tcp,
            on: NWEndpoint.Port(integerLiteral: 1455)
        )
    }

    nonisolated static func authorizationCode(
        expectedState: String,
        timeout: TimeInterval,
        launchAuthorizationURL: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        let server = try OpenAICodexLoopbackOAuthServer(expectedState: expectedState)
        return try await server.run(timeout: timeout, launchAuthorizationURL: launchAuthorizationURL)
    }

    nonisolated private func run(
        timeout: TimeInterval,
        launchAuthorizationURL: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await self.waitForAuthorizationCode(launchAuthorizationURL: launchAuthorizationURL)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    let error = OpenAICodexAuthClientError.oauthSignInFailed(
                        "Timed out waiting for ChatGPT sign-in."
                    )
                    self.resume(throwing: error)
                    throw error
                }

                guard let code = try await group.next() else {
                    throw OpenAICodexAuthClientError.oauthSignInFailed("ChatGPT sign-in was interrupted.")
                }
                group.cancelAll()
                return code
            }
        } onCancel: {
            // Let Network.framework deliver `.cancelled` before resuming the
            // sign-in task. The replacement coordinator waits for that task,
            // so this guarantees port 1455 is released before it starts again.
            self.stop()
        }
    }

    nonisolated private func waitForAuthorizationCode(
        launchAuthorizationURL: @escaping @Sendable () async throws -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    Task {
                        do {
                            try await launchAuthorizationURL()
                        } catch {
                            self.resume(throwing: error)
                        }
                    }
                case .failed(let error):
                    self.resume(throwing: OpenAICodexAuthClientError.oauthSignInFailed(error.localizedDescription))
                case .cancelled:
                    self.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: .main)
        }
    }

    nonisolated private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: .main)
        receiveRequest(on: connection, accumulatedData: Data())
    }

    nonisolated private func receiveRequest(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.respond(
                    on: connection,
                    status: "500 Internal Server Error",
                    body: "ChatGPT sign-in failed.",
                    completion: {
                        self.resume(throwing: OpenAICodexAuthClientError.oauthSignInFailed(error.localizedDescription))
                    }
                )
                return
            }

            var requestData = accumulatedData
            if let data {
                requestData.append(data)
            }
            if let request = String(data: requestData, encoding: .utf8),
               request.contains("\r\n\r\n") || isComplete {
                self.handleRequest(request, connection: connection)
                return
            }

            self.receiveRequest(on: connection, accumulatedData: requestData)
        }
    }

    nonisolated private func handleRequest(_ request: String, connection: NWConnection) {
        let firstLine = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2,
              let url = URL(string: "http://localhost:1455\(parts[1])"),
              url.path == "/auth/callback"
        else {
            respond(on: connection, status: "404 Not Found", body: "Not found.")
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let code = queryItems.first { $0.name == "code" }?.value
        let state = queryItems.first { $0.name == "state" }?.value
        let error = queryItems.first { $0.name == "error" }?.value

        if let error {
            respond(
                on: connection,
                status: "400 Bad Request",
                body: "ChatGPT sign-in failed. You can close this window.",
                completion: {
                    self.resume(throwing: OpenAICodexAuthClientError.oauthSignInFailed(error))
                }
            )
            return
        }

        guard state == expectedState else {
            respond(
                on: connection,
                status: "400 Bad Request",
                body: "Invalid sign-in state. You can close this window.",
                completion: {
                    self.resume(throwing: OpenAICodexAuthClientError.invalidOAuthState)
                }
            )
            return
        }

        guard let code, !code.isEmpty else {
            respond(
                on: connection,
                status: "400 Bad Request",
                body: "Missing authorization code. You can close this window.",
                completion: {
                    self.resume(throwing: OpenAICodexAuthClientError.missingOAuthCode)
                }
            )
            return
        }

        respond(
            on: connection,
            status: "200 OK",
            body: "ChatGPT sign-in complete. You can close this window.",
            completion: {
                self.resume(returning: code)
            }
        )
    }

    nonisolated private func respond(
        on connection: NWConnection,
        status: String,
        body: String,
        completion: @escaping @Sendable () -> Void = {}
    ) {
        let response = [
            "HTTP/1.1 \(status)",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Length: \(Data(body.utf8).count)",
            "Connection: close",
            "",
            body,
        ].joined(separator: "\r\n")
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
            completion()
        })
    }

    nonisolated private func resume(returning code: String) {
        guard !didResume else { return }
        didResume = true
        stop()
        continuation?.resume(returning: code)
        continuation = nil
    }

    nonisolated private func resume(throwing error: Error) {
        guard !didResume else { return }
        didResume = true
        stop()
        continuation?.resume(throwing: error)
        continuation = nil
    }

    nonisolated private func stop() {
        listener.cancel()
    }
}

nonisolated private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
