import Foundation
import Testing
@testable import Ironsmith

extension InferenceTests {
    @Test
    func codexAuthFileClientParsesChatGPTAuthFileShape() throws {
        let expiration = Date(timeIntervalSince1970: 1_900_000_000)
        let accessToken = Self.testJWT(payload: [
            "exp": expiration.timeIntervalSince1970,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "claim-account",
            ],
        ])
        let idToken = Self.testJWT(payload: [
            "email": "jade@example.com",
            "chatgpt_account_id": "id-account",
        ])
        let data = """
        {
          "auth_mode": "chatgpt",
          "OPENAI_API_KEY": null,
          "tokens": {
            "id_token": "\(idToken)",
            "access_token": "\(accessToken)",
            "refresh_token": "rt.test",
            "account_id": "auth-file-account"
          },
          "last_refresh": "2026-07-05T05:40:41.597781Z"
        }
        """.data(using: .utf8)!

        let parsedCredential = try CodexAuthFileClient.credential(from: data)
        let credential = try #require(parsedCredential)

        #expect(credential.accessToken == accessToken)
        #expect(credential.refreshToken == "rt.test")
        #expect(credential.idToken == idToken)
        #expect(credential.accountID == "auth-file-account")
        #expect(credential.email == "jade@example.com")
        #expect(credential.expiresAt?.timeIntervalSince1970 == expiration.timeIntervalSince1970)
    }

    @Test
    func codexAuthFileClientReturnsNilForMissingOrNonChatGPTAuth() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("IronsmithTests.\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("auth.json")
        let missingCredential = try CodexAuthFileClient.credential(from: missingURL)
        #expect(missingCredential == nil)

        let apiKeyAuthData = """
        {
          "auth_mode": "api_key",
          "tokens": {
            "access_token": "ignored"
          }
        }
        """.data(using: .utf8)!
        let apiKeyCredential = try CodexAuthFileClient.credential(from: apiKeyAuthData)
        #expect(apiKeyCredential == nil)
    }

    @Test
    func codexAuthFileClientRejectsInvalidAuthFile() throws {
        do {
            _ = try CodexAuthFileClient.credential(from: #"{"auth_mode":"chatgpt"}"#.data(using: .utf8)!)
            Issue.record("Expected missing tokens to be rejected.")
        } catch let error as OpenAICodexAuthClientError {
            #expect(error == .invalidAuthFile)
        }

        do {
            _ = try CodexAuthFileClient.credential(from: #"{"auth_mode":"chatgpt","tokens":{}}"#.data(using: .utf8)!)
            Issue.record("Expected missing access token to be rejected.")
        } catch let error as OpenAICodexAuthClientError {
            #expect(error == .invalidAuthFile)
        }
    }

    @Test
    func openAICodexValidCredentialRefreshesStaleJWTAndRewritesAuthFile() async throws {
        let directory = try Self.temporaryDirectory()
        let authFileURL = directory.appendingPathComponent("auth.json")
        let staleAccessToken = Self.testJWT(payload: [
            "exp": Date().addingTimeInterval(-60).timeIntervalSince1970,
        ])
        let existingData = """
        {
          "auth_mode": "chatgpt",
          "preserved": {
            "value": true
          },
          "tokens": {
            "access_token": "\(staleAccessToken)",
            "refresh_token": "old-refresh",
            "id_token": "old-id",
            "account_id": "old-account"
          }
        }
        """.data(using: .utf8)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try existingData.write(to: authFileURL)

        let refreshedExpiration = Date().addingTimeInterval(60 * 60)
        let refreshedCredential = OpenAICodexCredential(
            accessToken: Self.testJWT(payload: ["exp": refreshedExpiration.timeIntervalSince1970]),
            refreshToken: "new-refresh",
            expiresAt: refreshedExpiration,
            idToken: "new-id",
            accountID: "new-account",
            email: "new@example.com"
        )
        let authClient = OpenAICodexAuthClient.live(
            codexCLIClient: .unconfigured,
            authFileClient: .live(authFileURL: authFileURL),
            refreshCredential: { oldCredential in
                #expect(oldCredential.accessToken == staleAccessToken)
                #expect(oldCredential.refreshToken == "old-refresh")
                return refreshedCredential
            }
        )

        let credential = try await authClient.validCredential()
        let rewrittenRoot = try Self.jsonObject(from: Data(contentsOf: authFileURL))
        let rewrittenTokens = try #require(rewrittenRoot["tokens"] as? [String: Any])
        let preserved = try #require(rewrittenRoot["preserved"] as? [String: Any])

        #expect(credential == refreshedCredential)
        #expect(rewrittenTokens["access_token"] as? String == refreshedCredential.accessToken)
        #expect(rewrittenTokens["refresh_token"] as? String == "new-refresh")
        #expect(rewrittenTokens["id_token"] as? String == "new-id")
        #expect(rewrittenTokens["account_id"] as? String == "new-account")
        #expect(preserved["value"] as? Bool == true)
        #expect(rewrittenRoot["last_refresh"] as? String != nil)

        let attributes = try FileManager.default.attributesOfItem(atPath: authFileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test
    func openAICodexValidCredentialRejectsStaleMalformedJWTWithoutRefreshToken() async throws {
        let authClient = OpenAICodexAuthClient.live(
            codexCLIClient: .unconfigured,
            authFileClient: CodexAuthFileClient(
                credential: {
                    OpenAICodexCredential(accessToken: "not-a-jwt")
                },
                saveCredential: { _ in
                    Issue.record("Missing refresh token should fail before saving.")
                }
            ),
            refreshCredential: { credential in
                try await OpenAICodexAuthClient.refreshCredential(credential)
            }
        )

        do {
            _ = try await authClient.validCredential()
            Issue.record("Expected malformed JWT without refresh token to require sign-in.")
        } catch let error as OpenAICodexAuthClientError {
            #expect(error == .missingRefreshToken)
        }
    }

    @Test
    func codexCLIClientBuildsCommandsWithBundledExecutableAndCodexHome() async throws {
        let directory = try Self.temporaryDirectory()
        let codexHomeDirectory = directory.appendingPathComponent(".codex", isDirectory: true)
        let executableURL = directory.appendingPathComponent("codex")
        let recorder = CodexCLIRequestRecorder()
        let client = CodexCLIClient.live(
            codexHomeDirectory: codexHomeDirectory,
            executableURL: executableURL,
            bundleResourceURL: nil,
            environment: ["PATH": "/usr/bin"],
            runProcess: { request in
                await recorder.record(request)
                return CodexCLIProcessResult(stdout: "", stderr: "", terminationStatus: 0)
            }
        )

        try await client.signIn()
        _ = try await client.loginStatus()
        try await client.signOut()

        let requests = await recorder.requests
        #expect(requests.map(\.executableURL) == [executableURL, executableURL, executableURL])
        #expect(requests.map(\.arguments) == [
            ["login"],
            ["login", "status"],
            ["logout"],
        ])
        #expect(requests.allSatisfy { $0.currentDirectoryURL == codexHomeDirectory })
        #expect(requests.allSatisfy { $0.environment["CODEX_HOME"] == codexHomeDirectory.path })
        #expect(FileManager.default.fileExists(atPath: codexHomeDirectory.path))
    }

    @Test
    func codexCLIClientRedactsTokenShapedCommandFailures() async throws {
        let directory = try Self.temporaryDirectory()
        let client = CodexCLIClient.live(
            codexHomeDirectory: directory.appendingPathComponent(".codex", isDirectory: true),
            executableURL: directory.appendingPathComponent("codex"),
            bundleResourceURL: nil,
            environment: [:],
            runProcess: { _ in
                CodexCLIProcessResult(
                    stdout: #""access_token": "eyJ.header.payload""#,
                    stderr: #"Bearer eyJ.access.payload and refresh_token: rt.1.secret"#,
                    terminationStatus: 1
                )
            }
        )

        do {
            try await client.signIn()
            Issue.record("Expected Codex command failure.")
        } catch let error as OpenAICodexAuthClientError {
            guard case .codexCommandFailed(let message) = error else {
                Issue.record("Expected codexCommandFailed, got \(error).")
                return
            }
            #expect(!message.contains("eyJ.header.payload"))
            #expect(!message.contains("eyJ.access.payload"))
            #expect(!message.contains("rt.1.secret"))
            #expect(message.contains("[redacted]") || message.contains("[jwt-redacted]"))
        }
    }

    @Test
    func codexCLIClientLocatesBundledVendorBinaryForCurrentArchitecture() throws {
        let resourcesURL = try Self.temporaryDirectory()
        let codexResourceURL = resourcesURL.appendingPathComponent("Codex", isDirectory: true)
        let vendorURL = resourcesURL
            .appendingPathComponent("Codex", isDirectory: true)
            .appendingPathComponent("vendor", isDirectory: true)
            .appendingPathComponent(Self.testCodexTargetTriple, isDirectory: true)
        let versionURL = codexResourceURL.appendingPathComponent("version.txt")
        let executableURL = vendorURL.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: vendorURL, withIntermediateDirectories: true)
        try Data().write(to: executableURL)
        try "0.200.0\n".write(to: versionURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableURL.path
        )

        let resolvedURL = try CodexCLIClient.bundledExecutableURL(resourceURL: resourcesURL)

        #expect(resolvedURL == executableURL)
        #expect(CodexCLIClient.bundledVersion(resourceURL: resourcesURL) == "0.200.0")
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("IronsmithTests.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func jsonObject(from data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private static func testJWT(payload: [String: Any]) -> String {
        let header = [
            "alg": "none",
            "typ": "JWT",
        ]
        let headerData = try! JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        let payloadData = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "\(Self.base64URL(headerData)).\(Self.base64URL(payloadData)).signature"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static var testCodexTargetTriple: String {
        #if arch(arm64)
        return "aarch64-apple-darwin"
        #elseif arch(x86_64)
        return "x86_64-apple-darwin"
        #else
        return "unsupported-apple-darwin"
        #endif
    }
}

private actor CodexCLIRequestRecorder {
    private(set) var requests: [CodexCLIProcessRequest] = []

    func record(_ request: CodexCLIProcessRequest) {
        requests.append(request)
    }
}
