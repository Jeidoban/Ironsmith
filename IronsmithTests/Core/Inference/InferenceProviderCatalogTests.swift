import AnyLanguageModel
import Foundation
import Security
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension InferenceTests {
    @Test
    func attachmentSupportFollowsCodexProviderAndManagedModelCapability() throws {
        let ironsmith = try #require(ProviderCatalog.makeProvider(for: .ironsmith))
        let managedModel = ModelConfig(
            identifier: "openai/gpt-5.6",
            displayName: "GPT-5.6",
            providerIdentifier: ironsmith.identifier,
            source: .remote,
            installState: .installed,
            supportsImageInput: true
        )
        let textOnlyModel = ModelConfig(
            identifier: "deepseek/deepseek-v4-flash",
            displayName: "DeepSeek V4 Flash",
            providerIdentifier: ironsmith.identifier,
            source: .remote,
            installState: .installed
        )

        #expect(
            ToolAttachmentSupport.isSupported(
                model: managedModel,
                provider: ironsmith,
                codingAgent: .codex
            ))
        #expect(
            !ToolAttachmentSupport.isSupported(
                model: textOnlyModel,
                provider: ironsmith,
                codingAgent: .codex
            ))
        #expect(
            !ToolAttachmentSupport.isSupported(
                model: managedModel,
                provider: ironsmith,
                codingAgent: .ironsmithFlame
            ))
        #expect(
            ToolAttachmentSupport.canUseCodexAttachments(
                model: managedModel,
                provider: ironsmith
            ))
        #expect(
            !ToolAttachmentSupport.canUseCodexAttachments(
                model: textOnlyModel,
                provider: ironsmith
            ))
        #expect(
            ToolAttachmentSupport.preferenceAfterAddingAttachments(.automatic) == .automatic
        )
        #expect(
            ToolAttachmentSupport.preferenceAfterAddingAttachments(.ironsmithSpark) == .codex
        )
        #expect(
            ToolAttachmentSupport.preferenceAfterAddingAttachments(.ironsmithFlame) == .codex
        )
    }

    @Test
    func providerCatalogUsesConfiguredDisplayOrder() {
        let expectedOrder: [ProviderKind] = [
            .local,
            .ollama,
            .ironsmith,
            .openAI,
            .anthropic,
            .gemini,
            .customOpenAICompatible,
        ]

        let sortedKinds = ProviderCatalog.descriptors
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder {
                    return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
                }
                return lhs.sortOrder < rhs.sortOrder
            }
            .map(\.kind)

        #expect(sortedKinds == expectedOrder)
    }

    @Test
    func addableProviderChoicesUseConfiguredDisplayOrder() {
        #expect(ProviderCatalog.addableBuiltInDescriptors.map(\.kind) == [
            .ollama,
            .ironsmith,
            .openAI,
            .anthropic,
            .gemini,
        ])
    }

    @Test
    func providerCatalogBuildsProviderSpecificModelRequests() throws {
        let openAIProvider = ProviderCatalog.makeProvider(for: .openAI)!
        let openAIRequest = try RemoteModelClient.makeModelListRequest(
            for: openAIProvider,
            apiKey: "openai-key"
        )

        let anthropicProvider = ProviderCatalog.makeProvider(for: .anthropic)!
        let anthropicRequest = try RemoteModelClient.makeModelListRequest(
            for: anthropicProvider,
            apiKey: "anthropic-key"
        )
        let geminiProvider = ProviderCatalog.makeProvider(for: .gemini)!
        let geminiRequest = try RemoteModelClient.makeModelListRequest(
            for: geminiProvider,
            apiKey: "gemini-key"
        )
        let ollamaProvider = ProviderCatalog.makeProvider(for: .ollama)!
        let ollamaRequest = try RemoteModelClient.makeModelListRequest(
            for: ollamaProvider,
            apiKey: "ollama-key"
        )
        let customProvider = ProviderConfig(
            identifier: "custom.local",
            displayName: "Local Ollama",
            baseURLString: "http://localhost:11434/v1",
            authMode: .apiKey,
            origin: .custom
        )
        let customRequest = try RemoteModelClient.makeModelListRequest(
            for: customProvider,
            apiKey: nil
        )

        #expect(ProviderCatalog.descriptor(for: .local)?.sortOrder == 0)
        #expect(openAIRequest.url?.lastPathComponent == "models")
        #expect(openAIRequest.value(forHTTPHeaderField: "Authorization") == "Bearer openai-key")
        #expect(anthropicRequest.url?.absoluteString == "https://api.anthropic.com/v1/models")
        #expect(anthropicRequest.value(forHTTPHeaderField: "x-api-key") == "anthropic-key")
        #expect(anthropicRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(geminiRequest.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models")
        #expect(geminiRequest.value(forHTTPHeaderField: "x-goog-api-key") == "gemini-key")
        #expect(geminiRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(ollamaRequest.url?.absoluteString == "http://localhost:11434/api/tags")
        #expect(ollamaRequest.value(forHTTPHeaderField: "Authorization") == "Bearer ollama-key")
        #expect(customRequest.url?.absoluteString == "http://localhost:11434/v1/models")
        #expect(customRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(customRequest.timeoutInterval == RemoteModelClient.discoveryTimeout)
    }

    @Test
    func providerBaseURLValidationAllowsAnyHTTPOrHTTPSHost() throws {
        let acceptedURLs = [
            "https://api.example.com",
            "http://example.com",
            "http://203.0.113.10:8000/v1",
            "http://models.internal.example:8000/v1",
            "http://localhost",
            "http://127.0.0.1",
            "http://[::1]",
            "http://studio.localhost:11434/v1",
            "http://10.0.0.2:8000/v1",
            "http://172.16.0.2:8000/v1",
            "http://172.31.255.254:8000/v1",
            "http://192.168.1.103:8000/v1",
            "http://169.254.10.20:8000/v1",
        ]
        for urlString in acceptedURLs {
            #expect(try ProviderBaseURLValidator.validatedURL(from: urlString).absoluteString == urlString)
        }

        let rejectedURLs = [
            "file:///tmp/model",
            "data:text/plain,hello",
            "ftp://example.com",
            "javascript:alert(1)",
            "not a url",
        ]
        for urlString in rejectedURLs {
            #expect(throws: ProviderBaseURLValidationError.self) {
                try ProviderBaseURLValidator.validatedURL(from: urlString)
            }
        }
    }

    @Test
    func providerRequestBuildersAllowHTTPAndRejectUnsupportedSchemes() throws {
        let remoteProvider = ProviderConfig(
            identifier: "custom.remote-http",
            displayName: "Remote HTTP",
            baseURLString: "http://example.com/v1",
            authMode: .apiKey,
            origin: .custom
        )
        #expect(try RemoteModelClient.makeModelListRequest(
            for: remoteProvider,
            apiKey: nil
        ).url?.absoluteString == "http://example.com/v1/models")
        #expect(try OllamaClient.makeTagsRequest(
            baseURLString: "http://example.com",
            apiKey: nil
        ).url?.absoluteString == "http://example.com/api/tags")
        #expect(try OllamaClient.makeTagsRequest(baseURLString: "http://127.0.0.1:11434", apiKey: nil).url?.absoluteString == "http://127.0.0.1:11434/api/tags")
        #expect(try RemoteModelClient.makeModelListRequest(
            for: ProviderConfig(
                identifier: "custom.lan",
                displayName: "LAN Server",
                baseURLString: "http://192.168.1.103:8000/v1",
                authMode: .apiKey,
                origin: .custom
            ),
            apiKey: nil
        ).url?.absoluteString == "http://192.168.1.103:8000/v1/models")
        #expect(throws: RemoteModelDiscoveryError.self) {
            try RemoteModelClient.makeModelListRequest(
                for: ProviderConfig(
                    identifier: "custom.file",
                    displayName: "File",
                    baseURLString: "file:///tmp/model",
                    authMode: .apiKey,
                    origin: .custom
                ),
                apiKey: nil
            )
        }
    }

    @Test
    func providerCredentialStoreUsesExplicitAPIKeyAccessibilityPolicy() {
        #expect(ProviderCredentialStore.apiKeyAccessibility as String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    }

    @Test
    func ironsmithBackendConfigurationUsesSeparateAPIBaseURL() throws {
        let configuration = try #require(IronsmithBackendConfiguration.make(environment: [
            IronsmithBackendConfiguration.supabaseURLEnvironmentKey: "https://project.supabase.co",
            IronsmithBackendConfiguration.publishableKeyEnvironmentKey: "sb_publishable_key",
            IronsmithBackendConfiguration.apiBaseURLEnvironmentKey: "http://localhost:8000",
        ]))

        #expect(configuration.supabaseURL.absoluteString == "https://project.supabase.co")
        #expect(configuration.apiBaseURL.absoluteString == "http://localhost:8000")
        #expect(configuration.openAICompatibleBaseURL.absoluteString == "http://localhost:8000/api/v1")
    }

    @Test
    func ironsmithBackendConfigurationReadsInfoPlistFallbacks() throws {
        let configuration = try #require(IronsmithBackendConfiguration.make(
            environment: [:],
            infoValue: { key in
                [
                    IronsmithBackendConfiguration.supabaseURLInfoKey: "https://project.supabase.co",
                    IronsmithBackendConfiguration.publishableKeyInfoKey: "sb_publishable_key",
                    IronsmithBackendConfiguration.apiBaseURLInfoKey: "https://api.ironsmith.example",
                ][key]
            }
        ))

        #expect(configuration.supabaseURL.absoluteString == "https://project.supabase.co")
        #expect(configuration.apiBaseURL.absoluteString == "https://api.ironsmith.example")
    }

    @Test
    func ironsmithBackendConfigurationEnvironmentOverridesInfoPlist() throws {
        let configuration = try #require(IronsmithBackendConfiguration.make(
            environment: [
                IronsmithBackendConfiguration.supabaseURLEnvironmentKey: "https://env.supabase.co",
                IronsmithBackendConfiguration.publishableKeyEnvironmentKey: "env_publishable_key",
                IronsmithBackendConfiguration.apiBaseURLEnvironmentKey: "https://env-api.ironsmith.example",
            ],
            infoValue: { key in
                [
                    IronsmithBackendConfiguration.supabaseURLInfoKey: "https://info.supabase.co",
                    IronsmithBackendConfiguration.publishableKeyInfoKey: "info_publishable_key",
                    IronsmithBackendConfiguration.apiBaseURLInfoKey: "https://info-api.ironsmith.example",
                ][key]
            }
        ))

        #expect(configuration.supabaseURL.absoluteString == "https://env.supabase.co")
        #expect(configuration.publishableKey == "env_publishable_key")
        #expect(configuration.apiBaseURL.absoluteString == "https://env-api.ironsmith.example")
    }

    @Test
    func ironsmithBackendConfigurationRequiresAPIBaseURL() {
        let configuration = IronsmithBackendConfiguration.make(environment: [
            IronsmithBackendConfiguration.supabaseURLEnvironmentKey: "https://project.supabase.co",
            IronsmithBackendConfiguration.publishableKeyEnvironmentKey: "sb_publishable_key",
        ])

        #expect(configuration == nil)
    }

    @Test
    func ironsmithAccountNotConfiguredErrorNamesRequiredKeysOnly() {
        let message = IronsmithAccountClientError.notConfigured.localizedDescription

        #expect(message.contains("Missing configuration keys"))
        #expect(message.contains(IronsmithBackendConfiguration.supabaseURLEnvironmentKey))
        #expect(message.contains(IronsmithBackendConfiguration.publishableKeyEnvironmentKey))
        #expect(message.contains(IronsmithBackendConfiguration.apiBaseURLEnvironmentKey))
        #expect(!(message.contains("https://project.supabase.co")))
        #expect(!(message.contains("sb_publishable_key")))
        #expect(!(message.contains("http://localhost:8000")))
    }

    @Test
    func ironsmithAPIRequestsUseConfiguredBaseURLAndBearerToken() throws {
        let request = IronsmithAccountClient.makeAuthenticatedAPIRequest(
            baseURL: try #require(URL(string: "http://localhost:8000")),
            path: "api/v1/models",
            method: .get,
            accessToken: "access-token"
        )

        #expect(request.url?.absoluteString == "http://localhost:8000/api/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    }

    @Test
    func ironsmithAPIRequestsAttachJSONBodyWhenProvided() throws {
        let body = try #require(#"{"creditPackId":"tier_1"}"#.data(using: .utf8))
        let request = IronsmithAccountClient.makeAuthenticatedAPIRequest(
            baseURL: try #require(URL(string: "http://localhost:8000")),
            path: "api/v1/billing/checkout-sessions",
            method: .post,
            accessToken: "access-token",
            body: body
        )

        #expect(request.url?.absoluteString == "http://localhost:8000/api/v1/billing/checkout-sessions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpBody == body)
    }

    @Test
    func ollamaModelManagementRequestsAppendAPIPathAndAuthorization() throws {
        let pullRequest = try OllamaClient.makePullRequest(
            baseURLString: "http://localhost:11434",
            modelIdentifier: "gemma4:e2b",
            apiKey: "ollama-key"
        )
        let deleteRequest = try OllamaClient.makeDeleteRequest(
            baseURLString: "http://localhost:11434",
            modelIdentifier: "gemma4:e2b",
            apiKey: nil
        )

        #expect(pullRequest.url?.absoluteString == "http://localhost:11434/api/pull")
        #expect(pullRequest.httpMethod == "POST")
        #expect(pullRequest.value(forHTTPHeaderField: "Authorization") == "Bearer ollama-key")
        #expect(String(data: pullRequest.httpBody ?? Data(), encoding: .utf8) == #"{"model":"gemma4:e2b"}"#)
        #expect(deleteRequest.url?.absoluteString == "http://localhost:11434/api/delete")
        #expect(deleteRequest.httpMethod == "DELETE")
        #expect(deleteRequest.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(String(data: deleteRequest.httpBody ?? Data(), encoding: .utf8) == #"{"model":"gemma4:e2b"}"#)
    }

    @MainActor
    @Test
    func providerCatalogDecodesProviderSpecificResponses() throws {
        let openAIProvider = ProviderCatalog.makeProvider(for: .openAI)!
        let openAIData = """
        {
          "data": [
            {"id": "gpt-test"},
            {"id": "gpt-test-2025-08-07"},
            {"id": "gpt-4o-audio-preview"},
            {"id": "gpt-image-1"},
            {"id": "text-embedding-3-small"}
          ]
        }
        """.data(using: .utf8)!
        let openAIModels = try RemoteModelClient.decodeModels(openAIData, for: openAIProvider)

        let anthropicProvider = ProviderCatalog.makeProvider(for: .anthropic)!
        let anthropicData = #"{"data":[{"id":"claude-test","display_name":"Claude Test"}]}"#.data(using: .utf8)!
        let anthropicModels = try RemoteModelClient.decodeModels(anthropicData, for: anthropicProvider)
        let geminiProvider = ProviderCatalog.makeProvider(for: .gemini)!
        let geminiData = """
        {
          "models": [
            {
              "name": "models/gemini-test",
              "baseModelId": "gemini-test",
              "displayName": "Gemini Test",
              "supportedGenerationMethods": ["generateContent"]
            },
            {
              "name": "models/gemini-test-2025-08-07",
              "baseModelId": "gemini-test-2025-08-07",
              "displayName": "Gemini Test 2025 08 07",
              "supportedGenerationMethods": ["generateContent"]
            },
            {
              "name": "models/text-embedding-test",
              "baseModelId": "text-embedding-test",
              "displayName": "Embedding Test",
              "supportedGenerationMethods": ["embedContent"]
            },
            {
              "name": "models/gemini-tts-preview",
              "baseModelId": "gemini-tts-preview",
              "displayName": "Gemini TTS Preview",
              "supportedGenerationMethods": ["generateContent"]
            },
            {
              "name": "models/nano-banana",
              "baseModelId": "nano-banana",
              "displayName": "Nano Banana",
              "supportedGenerationMethods": ["generateContent"]
            }
          ]
        }
        """.data(using: .utf8)!
        let geminiModels = try RemoteModelClient.decodeModels(geminiData, for: geminiProvider)
        let ollamaProvider = ProviderCatalog.makeProvider(for: .ollama)!
        let ollamaData = """
        {
          "models": [
            {"name": "gemma4:e2b", "model": "gemma4:e2b"},
            {"name": "custom-model:latest", "model": "custom-model:latest"},
            {"name": "text-embedding-local", "model": "text-embedding-local"}
          ]
        }
        """.data(using: .utf8)!
        let ollamaModels = try RemoteModelClient.decodeModels(ollamaData, for: ollamaProvider)
        let ironsmithProvider = ProviderCatalog.makeProvider(for: .ironsmith)!
        let ironsmithData = #"{"data":[{"id":"openai.gpt-5","displayName":"GPT-5","estimatedToolCredits":157,"supportsImageInput":true}]}"#.data(using: .utf8)!
        let ironsmithModels = try RemoteModelClient.decodeModels(ironsmithData, for: ironsmithProvider)

        #expect(openAIModels.map(\.identifier) == ["gpt-test"])
        #expect(openAIModels.first?.isRemote == true)
        #expect(anthropicModels.first?.displayName == "Claude Test")
        #expect(anthropicModels.first?.selectionIdentifier == "anthropic::claude-test")
        #expect(geminiModels.map(\.identifier) == ["gemini-test"])
        #expect(geminiModels.first?.displayName == "Gemini Test")
        #expect(geminiModels.first?.selectionIdentifier == "gemini::gemini-test")
        #expect(ollamaModels.map(\.identifier) == ["custom-model:latest", "gemma4:e2b"])
        #expect(ollamaModels.first?.source == .remote)
        #expect(ironsmithModels.map(\.identifier) == ["openai.gpt-5"])
        #expect(ironsmithModels.first?.displayName == "GPT-5")
        #expect(ironsmithModels.first?.estimatedToolCredits == 157)
        #expect(ironsmithModels.first?.supportsImageInput == true)
    }

    @MainActor
    @Test
    func openAICodexModelDiscoveryLabelsModelsInsideOpenAIProvider() async throws {
        let provider = ProviderCatalog.makeProvider(for: .openAI)!
        let authClient = OpenAICodexAuthClient(
            credential: {
                OpenAICodexCredential(accessToken: "access-token")
            },
            signIn: {
                OpenAICodexCredential(accessToken: "access-token")
            },
            signOut: {},
            validCredential: {
                OpenAICodexCredential(accessToken: "access-token")
            },
            discoverModels: {
                [
                    OpenAICodexModel(identifier: "gpt-5.5", displayName: "GPT-5.5"),
                    OpenAICodexModel(identifier: "gpt-5.4-mini", displayName: "GPT-5.4 Mini"),
                ]
            }
        )
        let client = RemoteModelClient.live(openAICodexAuthClient: authClient)

        let models = try await client.discoverModels(provider, nil)

        #expect(models.map(\.identifier) == ["codex:gpt-5.4-mini", "codex:gpt-5.5"])
        #expect(models.map(\.displayName) == ["GPT-5.4 Mini (Codex)", "GPT-5.5 (Codex)"])
        #expect(models.allSatisfy { $0.providerIdentifier == provider.identifier })
    }

    @Test
    func openAICodexModelDecoderHandlesCatalogShapes() throws {
        let data = """
        {
          "models": [
            {"id": "gpt-5.5", "display_name": "GPT-5.5", "use_responses_lite": true},
            {"slug": "o4-mini", "title": "o4 mini", "use_responses_lite": false},
            {"id": "codex-auto-review", "display_name": "Codex Auto Review"},
            {"id": "gpt-image-1", "display_name": "GPT Image"},
            {"id": "text-embedding-3-small", "display_name": "Embedding"},
            {"id": "gpt-5.5", "display_name": "Duplicate"}
          ]
        }
        """.data(using: .utf8)!

        let models = try OpenAICodexAuthClient.decodeModels(data)

        #expect(models.map(\.identifier) == ["gpt-5.5", "o4-mini"])
        #expect(models.map(\.displayName) == ["GPT-5.5", "o4 mini"])
        #expect(models.map(\.usesResponsesLite) == [true, false])
    }

    @MainActor
    @Test
    func customOpenAICompatibleDiscoveryAllowsNonOpenAIPrefixes() throws {
        let customProvider = ProviderConfig(
            identifier: "custom.test",
            displayName: "Custom",
            baseURLString: "http://localhost:11434/v1",
            authMode: .apiKey,
            origin: .custom
        )
        let data = """
        {
          "data": [
            {"id": "llama3.1:8b"},
            {"id": "qwen2.5-coder"},
            {"id": "text-embedding-local"},
            {"id": "gpt-image-local"}
          ]
        }
        """.data(using: .utf8)!

        let models = try RemoteModelClient.decodeModels(data, for: customProvider)

        #expect(models.map(\.identifier) == ["llama3.1:8b", "qwen2.5-coder"])
    }
}
