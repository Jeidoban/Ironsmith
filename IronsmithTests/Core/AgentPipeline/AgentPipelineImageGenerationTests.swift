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
        #expect(openAIRequest.timeoutInterval == 300)
        #expect(openAIRequest.value(forHTTPHeaderField: "Authorization") == "Bearer openai-key")
        let openAIBody = try #require(jsonObject(openAIRequest) as? [String: Any])
        #expect(openAIBody["model"] as? String == "gpt-image-2")
        #expect(openAIBody["quality"] as? String == "low")
        #expect(openAIBody["size"] as? String == "1024x1024")

        let geminiRequest = try #require(requests.dropFirst().first)
        #expect(geminiRequest.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/interactions")
        #expect(geminiRequest.timeoutInterval == 300)
        #expect(geminiRequest.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-key")
        let geminiBody = try #require(jsonObject(geminiRequest) as? [String: Any])
        #expect(geminiBody["model"] as? String == "gemini-3.1-flash-lite-image")
        let responseFormat = try #require(geminiBody["response_format"] as? [String: Any])
        #expect(responseFormat["aspect_ratio"] as? String == "1:1")
        #expect(responseFormat["image_size"] as? String == "1K")
        #expect(responseFormat["mime_type"] == nil)

        let codexRequest = try #require(requests.last)
        #expect(codexRequest.url?.absoluteString == "https://chatgpt.com/backend-api/codex/images/generations")
        #expect(codexRequest.timeoutInterval == 300)
        #expect(codexRequest.value(forHTTPHeaderField: "Authorization") == "Bearer codex-token")
        #expect(codexRequest.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-id")
    }

    @Test
    func hostedIconPromptLocksHouseStyleButPlaygroundKeepsCompactConcept() {
        let layout = ToolPackageLayout(
            packageRootURL: URL(fileURLWithPath: "/tmp/IconPrompt", isDirectory: true),
            executableName: "IconPrompt"
        )
        let concept = "A brass house calculator with blue glass buttons"

        let hostedPrompt = ToolIconClient.iconPrompt(
            for: ToolIconRequest(
                displayName: "Mortgage Calc",
                iconPrompt: concept,
                layout: layout,
                imageProvider: .gemini
            )
        )
        let playgroundPrompt = ToolIconClient.iconPrompt(
            for: ToolIconRequest(
                displayName: "Mortgage Calc",
                iconPrompt: concept,
                layout: layout,
                imageProvider: .imagePlayground
            )
        )

        #expect(hostedPrompt.contains("native macOS application icon"))
        #expect(hostedPrompt.contains("exact Ironsmith house style"))
        #expect(hostedPrompt.contains("subject matter only"))
        #expect(hostedPrompt.contains("softly dimensional vector-like illustration"))
        #expect(hostedPrompt.contains("never photorealistic"))
        #expect(hostedPrompt.contains("Do not create a miniature scene, diorama"))
        #expect(hostedPrompt.contains("nearly front-facing orthographic view"))
        #expect(hostedPrompt.contains("one broad soft source from the upper left"))
        #expect(hostedPrompt.contains("full-bleed two-tone gradient background"))
        #expect(hostedPrompt.contains("Mandatory palette:"))
        #expect(hostedPrompt.contains(ToolIconClient.hostedIconPalette(for: "Mortgage Calc")))
        #expect(hostedPrompt.contains("do not replace it with generic blue"))
        #expect(hostedPrompt.contains("Do not draw a rounded-square or squircle icon boundary"))
        #expect(hostedPrompt.contains("Ironsmith applies the final app-icon shape separately"))
        #expect(hostedPrompt.contains("Visual concept: \(concept)"))
        #expect(playgroundPrompt == concept)
    }

    @Test
    func hostedIconPaletteVariesDeterministicallyAcrossAppNames() {
        let names = [
            "Mortgage Calc", "Notes", "Timer", "Recipe Box", "Budget", "Weather",
            "Habit Tracker", "Clipboard", "Converter", "Calendar", "Sketch", "Inventory",
        ]
        let palettes = names.map(ToolIconClient.hostedIconPalette(for:))

        #expect(ToolIconClient.hostedIconPalettes.count >= 20)
        #expect(Set(palettes).count >= 6)
        #expect(
            ToolIconClient.hostedIconPalette(for: "Mortgage Calc")
                == ToolIconClient.hostedIconPalette(for: "Mortgage Calc")
        )
    }

    @Test
    func hostedIconPaletteExcludesTenRecentSelectionsAcrossStoreInstances() async {
        let suiteName = "IronsmithTests.HostedIconPalette.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let sineTonePalette = ToolIconClient.hostedIconPalette(for: "Sine Tone")

        let firstStore = ToolHostedIconPaletteStore(userDefaults: userDefaults)
        var selections: [String] = []
        for _ in 0..<5 {
            selections.append(await firstStore.palette(for: "Sine Tone"))
        }
        let reloadedStore = ToolHostedIconPaletteStore(userDefaults: userDefaults)
        for _ in 0..<6 {
            selections.append(await reloadedStore.palette(for: "Sine Tone"))
        }

        #expect(selections.first == sineTonePalette)
        #expect(Set(selections.prefix(10)).count == 10)
        #expect(Set(selections.suffix(10)).count == 10)
        #expect(
            userDefaults.array(forKey: IronsmithPreferenceKeys.recentHostedIconPaletteIndices)?.count
                == ToolHostedIconPaletteStore.recentPaletteLimit
        )
    }

    @MainActor
    @Test
    func imageProviderErrorsIncludeStructuredProviderMessage() async throws {
        let httpClient = ToolImageHTTPClient { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "error": ["message": "Image size is not supported for this model."],
            ])
            return (
                data,
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        let client = ToolImageGenerationClient.make(
            httpClient: httpClient,
            credentialClient: CredentialClient(
                loadAPIKey: { _ in "gemini-key" },
                saveAPIKey: { _, _ in },
                deleteAPIKey: { _ in }
            ),
            codexAuthClient: .unconfigured,
            accountClient: .unconfigured,
            backendConfiguration: nil,
            imagePlayground: ImagePlaygroundSheetCoordinator()
        )

        do {
            _ = try await client.generate(.gemini, "A calculator and house")
            Issue.record("Expected Gemini request to fail.")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 400"))
            #expect(error.localizedDescription.contains("Image size is not supported"))
        }
    }

    @MainActor
    @Test
    func codexImageRequestDoesNotRetryUnauthorizedResponse() async throws {
        let capture = ToolImageRequestCapture()
        let httpClient = ToolImageHTTPClient { request in
            await capture.record(request)
            return (
                Data(),
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        }
        let rejectedCredential = OpenAICodexCredential(accessToken: "rejected-token")
        var authClient = OpenAICodexAuthClient.unconfigured
        authClient.credential = { rejectedCredential }
        authClient.validCredential = { rejectedCredential }
        let client = ToolImageGenerationClient.make(
            httpClient: httpClient,
            credentialClient: CredentialClient(
                loadAPIKey: { _ in nil },
                saveAPIKey: { _, _ in },
                deleteAPIKey: { _ in }
            ),
            codexAuthClient: authClient,
            accountClient: .unconfigured,
            backendConfiguration: nil,
            imagePlayground: ImagePlaygroundSheetCoordinator()
        )

        do {
            _ = try await client.generate(.openAI, "A calculator and house")
            Issue.record("Expected the rejected Codex image request to fail.")
        } catch {
            #expect(error.localizedDescription.contains("HTTP 401"))
        }

        #expect(await capture.requests.count == 1)
        #expect(
            await capture.requests.first?.value(forHTTPHeaderField: "Authorization")
                == "Bearer rejected-token"
        )
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
