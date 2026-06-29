import Foundation
import Supabase

typealias IronsmithOAuthLaunchFlow = @MainActor @Sendable (_ url: URL) async throws -> URL

enum IronsmithOAuthRedirect {
    static let appCallbackScheme = "com.jeidoban.ironsmith"
    static let appRedirectURL = URL(string: "\(appCallbackScheme)://auth/callback")!
}

nonisolated struct IronsmithBackendConfiguration: Equatable {
    static let supabaseURLEnvironmentKey = "IRONSMITH_SUPABASE_URL"
    static let publishableKeyEnvironmentKey = "IRONSMITH_SUPABASE_PUBLISHABLE_KEY"
    static let apiBaseURLEnvironmentKey = "IRONSMITH_API_BASE_URL"
    static let supabaseURLInfoKey = "IronsmithSupabaseURL"
    static let publishableKeyInfoKey = "IronsmithSupabasePublishableKey"
    static let apiBaseURLInfoKey = "IronsmithAPIBaseURL"

    let supabaseURL: URL
    let publishableKey: String
    let apiBaseURL: URL

    var openAICompatibleBaseURL: URL {
        apiBaseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
    }

    static var live: Self? {
        let bundle = Bundle.main
        return make(
            environment: ProcessInfo.processInfo.environment,
            infoValue: { bundle.object(forInfoDictionaryKey: $0) as? String }
        )
    }

    static func make(
        environment: [String: String],
        infoValue: (String) -> String? = { _ in nil }
    ) -> Self? {
        let urlString =
            environment[supabaseURLEnvironmentKey]
            ?? infoValue(supabaseURLInfoKey)
        let publishableKey =
            environment[publishableKeyEnvironmentKey]
            ?? infoValue(publishableKeyInfoKey)
        let apiBaseURLString =
            environment[apiBaseURLEnvironmentKey]
            ?? infoValue(apiBaseURLInfoKey)

        guard let urlString,
            let supabaseURL = URL(string: urlString),
            supabaseURL.scheme != nil,
            let publishableKey,
            !publishableKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let apiBaseURLString,
            let apiBaseURL = URL(string: apiBaseURLString),
            apiBaseURL.scheme != nil
        else {
            return nil
        }

        return Self(
            supabaseURL: supabaseURL,
            publishableKey: publishableKey,
            apiBaseURL: apiBaseURL
        )
    }

    static var liveOpenAICompatibleBaseURLString: String {
        live?.openAICompatibleBaseURL.absoluteString ?? ""
    }
}

nonisolated struct IronsmithAccountSummary: Decodable, Equatable, Sendable {
    let user: IronsmithAccountUser
    let profile: IronsmithAccountProfile?
    let credits: IronsmithCreditSummary
    let recentLedger: [IronsmithCreditLedgerEvent]
}

nonisolated struct IronsmithAccountUser: Decodable, Equatable, Sendable {
    let id: String
    let email: String?
}

nonisolated struct IronsmithAccountProfile: Decodable, Equatable, Sendable {
    let id: String
    let email: String?
    let displayName: String?
}

nonisolated struct IronsmithCreditSummary: Decodable, Equatable, Sendable {
    let userId: String
    let balanceCredits: Int
}

nonisolated struct IronsmithCreditLedgerEvent: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let amountCredits: Int
    let balanceAfterCredits: Int?
    let reason: String
    let createdAt: String
}

nonisolated struct IronsmithCreditPack: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let credits: Int
    let amountCents: Int
    let currency: String

    var priceText: String {
        let amount = Double(amountCents) / 100
        return amount.formatted(
            .currency(code: currency.uppercased())
                .precision(.fractionLength(0...2))
        )
    }

    var creditsText: String {
        credits == 1 ? "1 credit" : "\(credits.formatted()) credits"
    }
}

nonisolated struct IronsmithCheckoutSession: Decodable, Equatable, Sendable {
    let id: String
    let url: URL
}

nonisolated enum IronsmithAPIRequestMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

nonisolated enum IronsmithAccountClientError: LocalizedError, Equatable {
    case notConfigured
    case missingSession
    case invalidResponse
    case requestFailed(statusCode: Int, message: String)
    case refundRequired(balanceCredits: Int)

    private static let requiredConfigurationKeyNames = [
        IronsmithBackendConfiguration.supabaseURLEnvironmentKey,
        IronsmithBackendConfiguration.publishableKeyEnvironmentKey,
        IronsmithBackendConfiguration.apiBaseURLEnvironmentKey,
    ]

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return
                "Ironsmith service is not configured. Missing configuration keys: \(Self.requiredConfigurationKeyNames.joined(separator: ", "))."
        case .missingSession:
            return "Sign in with Ironsmith before using Ironsmith credits."
        case .invalidResponse:
            return "The Ironsmith service returned an invalid response."
        case .requestFailed(let statusCode, let message):
            return "The Ironsmith service returned HTTP \(statusCode): \(message)"
        case .refundRequired(let balanceCredits):
            return
                "This account still has \(balanceCredits) credits. Refund handling must complete before account deletion."
        }
    }
}

nonisolated struct IronsmithAccountClient {
    private static let generationAccessTokenRefreshWindow: TimeInterval = 10 * 60

    let supabase: SupabaseClient?
    var currentSession: @Sendable () -> Session?
    var validAccessToken: @Sendable () async throws -> String
    var generationAccessToken: @Sendable () async throws -> String
    var signInWithAppleOAuth:
        @Sendable (_ launchFlow: @escaping IronsmithOAuthLaunchFlow) async throws -> Session
    var signOut: @Sendable () async throws -> Void
    var fetchAccountSummary: @Sendable () async throws -> IronsmithAccountSummary
    var fetchCreditPacks: @Sendable () async throws -> [IronsmithCreditPack]
    var createCheckoutSession:
        @Sendable (_ creditPackID: String) async throws -> IronsmithCheckoutSession
    var deleteAccount: @Sendable () async throws -> Void
    var invokeAPIData:
        @Sendable (_ path: String, _ method: IronsmithAPIRequestMethod) async throws -> Data
}

extension IronsmithAccountClient {
    static var live: Self {
        guard let configuration = IronsmithBackendConfiguration.live else {
            return .unconfigured
        }

        let supabase = SupabaseClient(
            supabaseURL: configuration.supabaseURL,
            supabaseKey: configuration.publishableKey
        )
        let validAccessToken: @Sendable () async throws -> String = {
            try await supabase.auth.session.accessToken
        }
        let generationAccessToken: @Sendable () async throws -> String = {
            let session = try await supabase.auth.session
            let secondsUntilExpiration = session.expiresAt - Date().timeIntervalSince1970
            if secondsUntilExpiration < generationAccessTokenRefreshWindow {
                return try await supabase.auth.refreshSession().accessToken
            }
            return session.accessToken
        }

        return Self(
            supabase: supabase,
            currentSession: {
                supabase.auth.currentSession
            },
            validAccessToken: validAccessToken,
            generationAccessToken: generationAccessToken,
            signInWithAppleOAuth: { launchFlow in
                try await supabase.auth.signInWithOAuth(
                    provider: .apple,
                    redirectTo: IronsmithOAuthRedirect.appRedirectURL,
                    scopes: "email",
                    launchFlow: launchFlow,
                )
            },
            signOut: {
                try await supabase.auth.signOut()
            },
            fetchAccountSummary: {
                try await Self.invokeAPI(
                    configuration,
                    accessTokenProvider: validAccessToken,
                    path: "api/v1/account",
                    method: .get
                )
            },
            fetchCreditPacks: {
                let response: IronsmithCreditPacksResponse = try await Self.invokeAPI(
                    configuration,
                    accessTokenProvider: validAccessToken,
                    path: "api/v1/billing/credit-packs",
                    method: .get
                )
                return response.data
            },
            createCheckoutSession: { creditPackID in
                try await Self.invokeAPI(
                    configuration,
                    accessTokenProvider: validAccessToken,
                    path: "api/v1/billing/checkout-sessions",
                    method: .post,
                    body: IronsmithCheckoutSessionCreateRequest(creditPackId: creditPackID)
                )
            },
            deleteAccount: {
                let _: IronsmithAccountDeleteResponse = try await Self.invokeAPI(
                    configuration,
                    accessTokenProvider: validAccessToken,
                    path: "api/v1/account/delete",
                    method: .post
                )
            },
            invokeAPIData: { path, method in
                try await Self.invokeAPIData(
                    configuration,
                    accessTokenProvider: validAccessToken,
                    path: path,
                    method: method
                )
            }
        )
    }

    static var unconfigured: Self {
        Self(
            supabase: nil,
            currentSession: { nil },
            validAccessToken: { throw IronsmithAccountClientError.notConfigured },
            generationAccessToken: { throw IronsmithAccountClientError.notConfigured },
            signInWithAppleOAuth: { _ in throw IronsmithAccountClientError.notConfigured },
            signOut: {},
            fetchAccountSummary: { throw IronsmithAccountClientError.notConfigured },
            fetchCreditPacks: { throw IronsmithAccountClientError.notConfigured },
            createCheckoutSession: { _ in throw IronsmithAccountClientError.notConfigured },
            deleteAccount: { throw IronsmithAccountClientError.notConfigured },
            invokeAPIData: { _, _ in throw IronsmithAccountClientError.notConfigured }
        )
    }

    static func makeAuthenticatedAPIRequest(
        baseURL: URL,
        path: String,
        method: IronsmithAPIRequestMethod,
        accessToken: String,
        body: Data? = nil
    ) -> URLRequest {
        var url = baseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private static func invokeAPI<Response: Decodable>(
        _ configuration: IronsmithBackendConfiguration,
        accessTokenProvider: @Sendable () async throws -> String,
        path: String,
        method: IronsmithAPIRequestMethod
    ) async throws -> Response {
        try await invokeAPI(
            configuration,
            accessTokenProvider: accessTokenProvider,
            path: path,
            method: method,
            bodyData: nil
        )
    }

    private static func invokeAPI<Response: Decodable, RequestBody: Encodable>(
        _ configuration: IronsmithBackendConfiguration,
        accessTokenProvider: @Sendable () async throws -> String,
        path: String,
        method: IronsmithAPIRequestMethod,
        body: RequestBody
    ) async throws -> Response {
        let bodyData = try JSONEncoder().encode(body)
        return try await invokeAPI(
            configuration,
            accessTokenProvider: accessTokenProvider,
            path: path,
            method: method,
            bodyData: bodyData
        )
    }

    private static func invokeAPI<Response: Decodable>(
        _ configuration: IronsmithBackendConfiguration,
        accessTokenProvider: @Sendable () async throws -> String,
        path: String,
        method: IronsmithAPIRequestMethod,
        bodyData: Data?
    ) async throws -> Response {
        let data = try await invokeAPIData(
            configuration,
            accessTokenProvider: accessTokenProvider,
            path: path,
            method: method,
            body: bodyData
        )
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw IronsmithAccountClientError.invalidResponse
        }
    }

    private static func invokeAPIData(
        _ configuration: IronsmithBackendConfiguration,
        accessTokenProvider: @Sendable () async throws -> String,
        path: String,
        method: IronsmithAPIRequestMethod,
        body: Data? = nil
    ) async throws -> Data {
        let accessToken = try await accessTokenProvider()
        guard !accessToken.isEmpty else {
            throw IronsmithAccountClientError.missingSession
        }

        let request = makeAuthenticatedAPIRequest(
            baseURL: configuration.apiBaseURL,
            path: path,
            method: method,
            accessToken: accessToken,
            body: body
        )
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw IronsmithAccountClientError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw backendError(statusCode: httpResponse.statusCode, data: data)
        }

        return data
    }

    private static func backendError(statusCode: Int, data: Data) -> IronsmithAccountClientError {
        let decoder = JSONDecoder()
        let nestedError = try? decoder.decode(IronsmithBackendErrorEnvelope.self, from: data).error
        let topLevelError = try? decoder.decode(IronsmithBackendError.self, from: data)
        let backendError = nestedError ?? topLevelError

        if statusCode == 401 {
            return .missingSession
        }

        if statusCode == 409,
            backendError?.code == "refund_required"
        {
            return .refundRequired(balanceCredits: backendError?.balanceCredits ?? 0)
        }

        return .requestFailed(
            statusCode: statusCode,
            message: backendError?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        )
    }
}

nonisolated private struct IronsmithAccountDeleteResponse: Decodable {
    let deleted: Bool
}

nonisolated private struct IronsmithCreditPacksResponse: Decodable {
    let data: [IronsmithCreditPack]
}

nonisolated private struct IronsmithCheckoutSessionCreateRequest: Encodable {
    let creditPackId: String
}

nonisolated private struct IronsmithBackendErrorEnvelope: Decodable {
    let error: IronsmithBackendError
}

nonisolated private struct IronsmithBackendError: Decodable {
    let code: String
    let message: String
    let balanceCredits: Int?
}
