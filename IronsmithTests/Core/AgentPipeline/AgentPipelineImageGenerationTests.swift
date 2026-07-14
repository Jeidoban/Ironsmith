import Foundation
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @MainActor
    @Test
    func cloudImageClientsSendFixedIconModelsAndSizes() async throws {
        let capture = ToolImageRequestCapture()
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZQmcAAAAASUVORK5CYII="
        ))
        let responseData = try JSONSerialization.data(withJSONObject: [
            "data": [["b64_json": png.base64EncodedString()]],
        ])
        let httpClient = ToolImageHTTPClient { request in
            await capture.record(request)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.url?.host == "generativelanguage.googleapis.com" {
                let geminiData = try JSONSerialization.data(withJSONObject: [
                    "output_image": ["data": png.base64EncodedString()],
                ])
                return (geminiData, response)
            }
            return (responseData, response)
        }
        let credentialClient = CredentialClient(
            loadAPIKey: { reference in
                switch reference {
                case "provider.openai": "openai-key"
                case "provider.gemini": "gemini-key"
                default: nil
                }
            },
            saveAPIKey: { _, _ in },
            deleteAPIKey: { _ in }
        )
        let client = ToolImageGenerationClient.make(
            httpClient: httpClient,
            credentialClient: credentialClient,
            codexAuthClient: .unconfigured,
            accountClient: .unconfigured,
            backendConfiguration: nil,
            imagePlayground: ImagePlaygroundSheetCoordinator()
        )

        _ = try await client.generate(.openAI, "A compact forge icon")
        _ = try await client.generate(.gemini, "A compact forge icon")

        let codexCredential = OpenAICodexCredential(
            accessToken: "codex-token",
            accountID: "account-id"
        )
        var codexAuthClient = OpenAICodexAuthClient.unconfigured
        codexAuthClient.credential = { codexCredential }
        codexAuthClient.validCredential = { codexCredential }
        codexAuthClient.forceRefreshCredential = { codexCredential }
        let codexClient = ToolImageGenerationClient.make(
            httpClient: httpClient,
            credentialClient: credentialClient,
            codexAuthClient: codexAuthClient,
            accountClient: .unconfigured,
            backendConfiguration: nil,
            imagePlayground: ImagePlaygroundSheetCoordinator()
        )
        _ = try await codexClient.generate(.openAI, "A compact forge icon")

        let requests = await capture.requests
        let openAIRequest = try #require(requests.first)
        #expect(openAIRequest.url?.absoluteString == "https://api.openai.com/v1/images/generations")
        #expect(openAIRequest.value(forHTTPHeaderField: "Authorization") == "Bearer openai-key")
        let openAIBody = try #require(jsonObject(openAIRequest) as? [String: Any])
        #expect(openAIBody["model"] as? String == "gpt-image-2")
        #expect(openAIBody["quality"] as? String == "low")
        #expect(openAIBody["size"] as? String == "1024x1024")

        let geminiRequest = try #require(requests.dropFirst().first)
        #expect(geminiRequest.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
        #expect(geminiRequest.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-key")
        let geminiBody = try #require(jsonObject(geminiRequest) as? [String: Any])
        #expect(geminiBody["model"] as? String == "gemini-3.1-flash-lite-image")
        let responseFormat = try #require(geminiBody["response_format"] as? [String: Any])
        #expect(responseFormat["aspect_ratio"] as? String == "1:1")
        #expect(responseFormat["image_size"] as? String == "1K")

        let codexRequest = try #require(requests.last)
        #expect(codexRequest.url?.absoluteString == "https://chatgpt.com/backend-api/codex/images/generations")
        #expect(codexRequest.value(forHTTPHeaderField: "Authorization") == "Bearer codex-token")
        #expect(codexRequest.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-id")
    }

    private func jsonObject(_ request: URLRequest) throws -> Any {
        try JSONSerialization.jsonObject(with: try #require(request.httpBody))
    }
}

private actor ToolImageRequestCapture {
    private(set) var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}
