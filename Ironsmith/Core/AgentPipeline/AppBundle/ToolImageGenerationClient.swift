import CoreGraphics
import Foundation
import ImageIO

nonisolated struct ToolImageHTTPClient: Sendable {
    var data: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    static let live = ToolImageHTTPClient { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ToolImageGenerationError.invalidResponse
        }
        return (data, httpResponse)
    }
}

nonisolated enum ToolImageGenerationError: LocalizedError {
    case missingCredential(ToolImageGenerationProvider)
    case serviceNotConfigured
    case invalidResponse
    case requestFailed(Int)
    case invalidImage
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .missingCredential(let provider):
            return "No \(provider.displayName) credential is available."
        case .serviceNotConfigured:
            return "The image generation service is not configured."
        case .invalidResponse:
            return "The image provider returned an invalid response."
        case .requestFailed(let statusCode):
            return "The image provider returned HTTP \(statusCode)."
        case .invalidImage:
            return "The image provider did not return a valid image."
        case .imageTooLarge:
            return "The generated image was too large."
        }
    }
}

nonisolated struct ToolImageGenerationClient: Sendable {
    var generate: @Sendable (ToolImageGenerationProvider, String) async throws -> CGImage

    @MainActor
    static func live() -> Self {
        make(
            httpClient: .live,
            credentialClient: .live,
            codexAuthClient: .live(),
            accountClient: .live,
            backendConfiguration: .live,
            imagePlayground: .shared
        )
    }

    @MainActor
    static func make(
        httpClient: ToolImageHTTPClient,
        credentialClient: CredentialClient,
        codexAuthClient: OpenAICodexAuthClient,
        accountClient: IronsmithAccountClient,
        backendConfiguration: IronsmithBackendConfiguration?,
        imagePlayground: ImagePlaygroundSheetCoordinator
    ) -> Self {
        Self { provider, prompt in
            switch provider {
            case .imagePlayground:
                let url = try await imagePlayground.generate(prompt: prompt)
                return try decodeImage(try Data(contentsOf: url))
            case .gemini:
                let apiKey = try apiKey(
                    provider: .gemini,
                    credentialClient: credentialClient
                )
                return try await generateGemini(prompt: prompt, apiKey: apiKey, httpClient: httpClient)
            case .openAI:
                if (try? codexAuthClient.credential()) != nil {
                    return try await generateCodex(
                        prompt: prompt,
                        authClient: codexAuthClient,
                        httpClient: httpClient
                    )
                }
                let apiKey = try apiKey(
                    provider: .openAI,
                    credentialClient: credentialClient
                )
                return try await generateOpenAI(
                    prompt: prompt,
                    apiKey: apiKey,
                    httpClient: httpClient
                )
            case .ironsmith:
                guard let backendConfiguration else {
                    throw ToolImageGenerationError.serviceNotConfigured
                }
                return try await generateIronsmith(
                    prompt: prompt,
                    configuration: backendConfiguration,
                    accountClient: accountClient,
                    httpClient: httpClient
                )
            case .disabled:
                throw ToolImageGenerationError.invalidResponse
            }
        }
    }

    private static func apiKey(
        provider: ProviderKind,
        credentialClient: CredentialClient
    ) throws -> String {
        let reference = "provider.\(provider.rawValue)"
        guard let value = try credentialClient.loadAPIKey(reference), !value.isEmpty else {
            let imageProvider: ToolImageGenerationProvider = provider == .gemini ? .gemini : .openAI
            throw ToolImageGenerationError.missingCredential(imageProvider)
        }
        return value
    }

    private static func generateOpenAI(
        prompt: String,
        apiKey: String,
        httpClient: ToolImageHTTPClient
    ) async throws -> CGImage {
        var request = imageRequest(
            url: URL(string: "https://api.openai.com/v1/images/generations")!,
            prompt: prompt
        )
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request, httpClient: httpClient)
        return try decodeOpenAIImage(data)
    }

    private static func generateCodex(
        prompt: String,
        authClient: OpenAICodexAuthClient,
        httpClient: ToolImageHTTPClient
    ) async throws -> CGImage {
        var credential = try await authClient.validCredential()
        var response = try await performCodex(
            prompt: prompt,
            credential: credential,
            httpClient: httpClient
        )
        if response.1.statusCode == 401 {
            credential = try await authClient.forceRefreshCredential()
            response = try await performCodex(
                prompt: prompt,
                credential: credential,
                httpClient: httpClient
            )
        }
        guard (200...299).contains(response.1.statusCode) else {
            throw ToolImageGenerationError.requestFailed(response.1.statusCode)
        }
        return try decodeOpenAIImage(response.0)
    }

    private static func performCodex(
        prompt: String,
        credential: OpenAICodexCredential,
        httpClient: ToolImageHTTPClient
    ) async throws -> (Data, HTTPURLResponse) {
        let url = OpenAICodexBackend.backendBaseURL.appendingPathComponent("images/generations")
        var request = imageRequest(url: url, prompt: prompt)
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(OpenAICodexBackend.userAgent, forHTTPHeaderField: "User-Agent")
        if let accountID = credential.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        return try await httpClient.data(request)
    }

    private static func imageRequest(url: URL, prompt: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(
            OpenAIImageRequest(
                model: "gpt-image-2",
                prompt: prompt,
                background: "auto",
                n: 1,
                quality: "low",
                size: "1024x1024"
            )
        )
        return request
    }

    private static func generateGemini(
        prompt: String,
        apiKey: String,
        httpClient: ToolImageHTTPClient
    ) async throws -> CGImage {
        var request = URLRequest(
            url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!
        )
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GeminiImageRequest(
                model: "gemini-3.1-flash-lite-image",
                input: prompt,
                responseFormat: .init(
                    type: "image",
                    mimeType: "image/png",
                    aspectRatio: "1:1",
                    imageSize: "1K"
                )
            )
        )
        let data = try await perform(request, httpClient: httpClient)
        let response = try JSONDecoder().decode(GeminiImageResponse.self, from: data)
        guard let imageData = Data(base64Encoded: response.outputImage.data) else {
            throw ToolImageGenerationError.invalidImage
        }
        return try decodeImage(imageData)
    }

    private static func generateIronsmith(
        prompt: String,
        configuration: IronsmithBackendConfiguration,
        accountClient: IronsmithAccountClient,
        httpClient: ToolImageHTTPClient
    ) async throws -> CGImage {
        let token = try await accountClient.generationAccessToken()
        let body = try JSONEncoder().encode(IronsmithImageRequest(prompt: prompt))
        let url = configuration.apiBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("images")
            .appendingPathComponent("generations")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 180
        let data = try await perform(request, httpClient: httpClient)
        return try decodeOpenAIImage(data)
    }

    private static func perform(
        _ request: URLRequest,
        httpClient: ToolImageHTTPClient
    ) async throws -> Data {
        let (data, response) = try await httpClient.data(request)
        guard (200...299).contains(response.statusCode) else {
            throw ToolImageGenerationError.requestFailed(response.statusCode)
        }
        return data
    }

    private static func decodeOpenAIImage(_ data: Data) throws -> CGImage {
        let response = try JSONDecoder().decode(OpenAIImageResponse.self, from: data)
        guard let encoded = response.data.first?.b64JSON,
              let imageData = Data(base64Encoded: encoded)
        else {
            throw ToolImageGenerationError.invalidImage
        }
        return try decodeImage(imageData)
    }

    private static func decodeImage(_ data: Data) throws -> CGImage {
        guard data.count <= 25 * 1024 * 1024 else {
            throw ToolImageGenerationError.imageTooLarge
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0,
              image.height > 0
        else {
            throw ToolImageGenerationError.invalidImage
        }
        return image
    }
}

nonisolated private struct OpenAIImageRequest: Encodable {
    let model: String
    let prompt: String
    let background: String
    let n: Int
    let quality: String
    let size: String
}

nonisolated private struct OpenAIImageResponse: Decodable {
    struct Image: Decodable {
        let b64JSON: String?

        enum CodingKeys: String, CodingKey {
            case b64JSON = "b64_json"
        }
    }

    let data: [Image]
}

nonisolated private struct GeminiImageRequest: Encodable {
    struct ResponseFormat: Encodable {
        let type: String
        let mimeType: String
        let aspectRatio: String
        let imageSize: String

        enum CodingKeys: String, CodingKey {
            case type
            case mimeType = "mime_type"
            case aspectRatio = "aspect_ratio"
            case imageSize = "image_size"
        }
    }

    let model: String
    let input: String
    let responseFormat: ResponseFormat

    enum CodingKeys: String, CodingKey {
        case model, input
        case responseFormat = "response_format"
    }
}

nonisolated private struct GeminiImageResponse: Decodable {
    struct Image: Decodable {
        let data: String
    }

    let outputImage: Image

    enum CodingKeys: String, CodingKey {
        case outputImage = "output_image"
    }
}

nonisolated private struct IronsmithImageRequest: Encodable {
    let prompt: String
}
