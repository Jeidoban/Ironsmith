import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

struct ToolLibraryTests {}

extension ToolLibraryTests {
    static func inferenceDependencies(
        accountClient: IronsmithAccountClient = .unconfigured
    ) -> InferenceDependencies {
        InferenceDependencies(
            credentialClient: CredentialClient(
                loadAPIKey: { _ in nil },
                saveAPIKey: { _, _ in },
                deleteAPIKey: { _ in }
            ),
            accountClient: accountClient,
            remoteModelClient: RemoteModelClient { _, _ in [] },
            localModelClient: LocalModelClient(
                makeHubAPI: {
                    fatalError("makeHubAPI should not be used by these tests")
                },
                downloadModel: { _, _ in URL(fileURLWithPath: "/tmp/model", isDirectory: true) },
                deleteModel: { _ in }
            ),
            ollamaClient: .noOp(),
            languageModelClient: LanguageModelClient(
                makeLanguageModel: { _, _ in ToolLibraryTestLanguageModel() }
            )
        )
    }

    static func ironsmithAccountClient(balanceCredits: Int) -> IronsmithAccountClient {
        IronsmithAccountClient(
            supabase: nil,
            currentSession: {
                Self.ironsmithSession()
            },
            validAccessToken: {
                "access-token"
            },
            generationAccessToken: {
                "access-token"
            },
            signInWithAppleOAuth: { _ in
                Self.ironsmithSession()
            },
            signOut: {},
            fetchAccountSummary: {
                IronsmithAccountSummary(
                    user: IronsmithAccountUser(
                        id: "00000000-0000-4000-8000-000000000001",
                        email: "jade@example.com"
                    ),
                    profile: nil,
                    credits: IronsmithCreditSummary(
                        userId: "00000000-0000-4000-8000-000000000001",
                        balanceCredits: balanceCredits
                    ),
                    recentLedger: []
                )
            },
            updateProfile: { _ in
                IronsmithAccountProfile(
                    id: "00000000-0000-4000-8000-000000000001",
                    email: "jade@example.com",
                    displayName: nil
                )
            },
            fetchCreditPacks: { [] },
            createCheckoutSession: { _ in
                throw IronsmithAccountClientError.notConfigured
            },
            deleteAccount: {},
            invokeAPIData: { _, _ in
                throw IronsmithAccountClientError.notConfigured
            }
        )
    }

    static func ironsmithAccountClient(fetchCapture: IronsmithAccountFetchCapture) -> IronsmithAccountClient {
        IronsmithAccountClient(
            supabase: nil,
            currentSession: {
                Self.ironsmithSession()
            },
            validAccessToken: {
                "access-token"
            },
            generationAccessToken: {
                "access-token"
            },
            signInWithAppleOAuth: { _ in
                Self.ironsmithSession()
            },
            signOut: {},
            fetchAccountSummary: {
                await fetchCapture.fetch()
            },
            updateProfile: { _ in
                IronsmithAccountProfile(
                    id: "00000000-0000-4000-8000-000000000001",
                    email: "jade@example.com",
                    displayName: nil
                )
            },
            fetchCreditPacks: { [] },
            createCheckoutSession: { _ in
                throw IronsmithAccountClientError.notConfigured
            },
            deleteAccount: {},
            invokeAPIData: { _, _ in
                throw IronsmithAccountClientError.notConfigured
            }
        )
    }

    static func ironsmithSession() -> Session {
        let userID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        return Session(
            accessToken: "access-token",
            tokenType: "bearer",
            expiresIn: 3600,
            expiresAt: Date().addingTimeInterval(3600).timeIntervalSince1970,
            refreshToken: "refresh-token",
            user: User(
                id: userID,
                appMetadata: [:],
                userMetadata: [:],
                aud: "authenticated",
                email: "jade@example.com",
                createdAt: Date(),
                role: "authenticated",
                updatedAt: Date()
            )
        )
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ironsmith-tool-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func makeIsolatedUserDefaults() throws -> UserDefaults {
        let suiteName = "ironsmith-tool-library-tests-\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }

    static func appleFoundationModelPreferenceStore(
        isEnabled: Bool = true
    ) throws -> AppleFoundationModelPreferenceStore {
        let store = AppleFoundationModelPreferenceStore(userDefaults: try makeIsolatedUserDefaults())
        store.isEnabled = isEnabled
        return store
    }

    static func remoteModel(
        provider: ProviderConfig,
        estimatedToolCredits: Int?
    ) -> ModelConfig {
        ModelConfig(
            identifier: "test/model",
            displayName: "Test Model",
            providerIdentifier: provider.identifier,
            source: .remote,
            installState: .installed,
            estimatedToolCredits: estimatedToolCredits
        )
    }
}

enum AppUpdateFetchError: Error {
    case failed
}

actor AppUpdateFetchCapture {
    private let result: Result<AppUpdateRelease, Error>
    private(set) var fetchCount = 0

    init(result: Result<AppUpdateRelease, Error>) {
        self.result = result
    }

    func fetch() throws -> AppUpdateRelease {
        fetchCount += 1
        return try result.get()
    }
}

actor IronsmithAccountFetchCapture {
    private let balances: [Int]
    private(set) var fetchCount = 0

    init(balances: [Int]) {
        self.balances = balances
    }

    func fetch() -> IronsmithAccountSummary {
        let balance = balances.isEmpty ? 0 : balances[min(fetchCount, balances.count - 1)]
        fetchCount += 1
        return IronsmithAccountSummary(
            user: IronsmithAccountUser(
                id: "00000000-0000-4000-8000-000000000001",
                email: "jade@example.com"
            ),
            profile: nil,
            credits: IronsmithCreditSummary(
                userId: "00000000-0000-4000-8000-000000000001",
                balanceCredits: balance
            ),
            recentLedger: []
        )
    }
}

actor ToolBuildCapture {
    private(set) var builtPackageRoot: URL?
    private(set) var builtSettings: ToolGenerationSettings?

    func record(_ url: URL) {
        builtPackageRoot = url
    }

    func record(_ tool: Ironsmith.Tool) {
        builtPackageRoot = tool.packageRootURL
        builtSettings = tool.generationSettings(defaults: .default)
    }
}

actor ToolExportCapture {
    private(set) var exportedToolID: UUID?

    func record(_ tool: Ironsmith.Tool) {
        exportedToolID = tool.id
    }
}

actor ToolFinderCapture {
    private(set) var openedURL: URL?

    func record(_ url: URL) {
        openedURL = url
    }
}

struct ToolLibraryTestLanguageModel: LanguageModel {
    typealias UnavailableReason = Never

    func respond<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) async throws -> LanguageModelSession.Response<Content> where Content: Generable {
        throw ToolLibraryTestLanguageModelError.unused
    }

    func streamResponse<Content>(
        within session: LanguageModelSession,
        to prompt: Prompt,
        generating type: Content.Type,
        includeSchemaInPrompt: Bool,
        options: GenerationOptions
    ) -> sending LanguageModelSession.ResponseStream<Content> where Content: Generable {
        LanguageModelSession.ResponseStream(
            stream: AsyncThrowingStream { continuation in
                continuation.finish(throwing: ToolLibraryTestLanguageModelError.unused)
            }
        )
    }
}

enum ToolLibraryTestLanguageModelError: Error {
    case unused
}
