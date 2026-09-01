import CryptoKit
import Foundation

nonisolated enum IronsmithStoreConstants {
    static let communityStoreId = "00000000-0000-4000-8000-000000000011"
    static let appListPageSize = 30

    static var runtimeVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let sanitized = version?
            .replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        return sanitized?.isEmpty == false ? "ironsmith-\(sanitized!)" : "ironsmith-macos-v1"
    }
}

nonisolated enum StoreAppListScope: String, Sendable {
    case discover
    case mine
}

nonisolated enum StoreAppStatus: String, Codable, Equatable, Sendable {
    case published
    case unlisted
}

nonisolated enum StoreAssetKind: String, Codable, Equatable, Sendable {
    case icon
    case iconMaster
    case screenshot
}

nonisolated enum StoreAppListSort: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case recent
    case trending

    var id: Self { self }

    var title: String {
        switch self {
        case .recent: "Recent"
        case .trending: "Trending"
        }
    }
}

nonisolated struct AppStoreDescriptor: Decodable, Identifiable, Equatable, Sendable {
    struct Organization: Decodable, Equatable, Sendable {
        let id: String
        let displayName: String
    }

    let id: String
    let organization: Organization
    let slug: String
    let displayName: String
    let description: String
    let visibility: String
    let status: String
    let createdAt: String
    let updatedAt: String
}

nonisolated struct StoreGenerationSettingsDTO: Codable, Equatable, Sendable {
    var appKind: ToolAppKind
    var menuBarSystemImage: String
    var sandboxEnabled: Bool
    var sandboxPermissions: String
    var resourcePermissions: String

    init(settings: ToolGenerationSettings) {
        appKind = settings.appKind
        menuBarSystemImage = settings.menuBarSystemImage
        sandboxEnabled = settings.sandboxEnabled
        sandboxPermissions = settings.sandboxPermissions.rawValueList
        resourcePermissions = settings.resourcePermissions.rawValueList
    }

    var toolSettings: ToolGenerationSettings {
        ToolGenerationSettings(
            appKind: appKind,
            menuBarSystemImage: menuBarSystemImage,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: GeneratedAppSandboxPermissions(rawValueList: sandboxPermissions),
            resourcePermissions: GeneratedAppResourcePermissions(rawValueList: resourcePermissions)
        )
    }

    var permissionChips: [String] {
        let sandbox =
            sandboxPermissions
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let resources =
            resourcePermissions
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return sandbox + resources
    }
}

nonisolated struct StoreAsset: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: StoreAssetKind
    let sortOrder: Int
    let width: Int
    let height: Int
    let byteSize: Int
    let url: URL?
}

nonisolated struct StoreVersionMetadata: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let appId: String
    let versionNumber: Int
    let sourceSha256: String
    let generationSettings: StoreGenerationSettingsDTO
    let runtimeVersion: String
    let license: StoreLicenseIdentifier
    let legalAttributions: [StoreLegalAttribution]
    let remixedFromVersionId: String?
    var inspiredByVersionIds: [String]? = nil
    let publishedAt: String
}

nonisolated struct StoreVersionDownload: Decodable, Equatable, Sendable {
    let id: String
    let storeId: String
    let storeVisibility: String
    let appId: String
    let versionNumber: Int
    let sourceSha256: String
    let generationSettings: StoreGenerationSettingsDTO
    let runtimeVersion: String
    let license: StoreLicenseIdentifier
    let legalAttributions: [StoreLegalAttribution]
    let remixedFromVersionId: String?
    var inspiredByVersionIds: [String]? = nil
    let publishedAt: String
    let sourceCode: String
}

nonisolated struct StoreRemixMetadata: Decodable, Equatable, Sendable {
    let storeId: String
    let appId: String
    let appName: String
    let versionId: String
    let versionNumber: Int
    let isDeleted: Bool

    init(
        storeId: String,
        appId: String,
        appName: String,
        versionId: String,
        versionNumber: Int,
        isDeleted: Bool = false
    ) {
        self.storeId = storeId
        self.appId = appId
        self.appName = appName
        self.versionId = versionId
        self.versionNumber = versionNumber
        self.isDeleted = isDeleted
    }

    private enum CodingKeys: String, CodingKey {
        case storeId, appId, appName, versionId, versionNumber, isDeleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeId = try container.decode(String.self, forKey: .storeId)
        appId = try container.decode(String.self, forKey: .appId)
        appName = try container.decode(String.self, forKey: .appName)
        versionId = try container.decode(String.self, forKey: .versionId)
        versionNumber = try container.decode(Int.self, forKey: .versionNumber)
        isDeleted = try container.decodeIfPresent(Bool.self, forKey: .isDeleted) ?? false
    }
}

nonisolated struct StoreAppSummary: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let storeId: String
    let authorDisplayName: String
    let authorHandle: String?
    let name: String
    let shortDescription: String
    let category: StoreAppCategory
    let status: StoreAppStatus
    let latestVersionNumber: Int
    let publishedAt: String
    let updatedAt: String
    let icon: StoreAsset?

    init(
        id: String,
        storeId: String,
        authorDisplayName: String,
        authorHandle: String?,
        name: String,
        shortDescription: String,
        category: StoreAppCategory,
        status: StoreAppStatus,
        latestVersionNumber: Int,
        publishedAt: String,
        updatedAt: String,
        icon: StoreAsset?
    ) {
        self.id = id
        self.storeId = storeId
        self.authorDisplayName = authorDisplayName
        self.authorHandle = authorHandle
        self.name = name
        self.shortDescription = shortDescription
        self.category = category
        self.status = status
        self.latestVersionNumber = latestVersionNumber
        self.publishedAt = publishedAt
        self.updatedAt = updatedAt
        self.icon = icon
    }

    init(detail: StoreAppDetail) {
        self.init(
            id: detail.id,
            storeId: detail.storeId,
            authorDisplayName: detail.authorDisplayName,
            authorHandle: detail.authorHandle,
            name: detail.name,
            shortDescription: detail.shortDescription,
            category: detail.category,
            status: detail.status,
            latestVersionNumber: detail.currentVersion.versionNumber,
            publishedAt: detail.publishedAt,
            updatedAt: detail.updatedAt,
            icon: detail.icon
        )
    }

}

nonisolated struct StoreAppDetail: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let storeId: String
    let storeVisibility: String
    let authorDisplayName: String
    let authorHandle: String?
    let name: String
    let shortDescription: String
    let description: String
    let category: StoreAppCategory
    let status: StoreAppStatus
    let publishedAt: String
    let createdAt: String
    let updatedAt: String
    let icon: StoreAsset?
    let iconMaster: StoreAsset?
    let screenshots: [StoreAsset]
    let currentVersion: StoreVersionMetadata
    let versions: [StoreVersionMetadata]
    let remix: StoreRemixMetadata?

    var iconAsset: StoreAsset? {
        icon
    }

    var creatorDisplayText: String {
        guard let authorHandle, !authorHandle.isEmpty else {
            return authorDisplayName
        }
        return "\(authorDisplayName) · @\(authorHandle)"
    }
}

nonisolated struct StoreAppPage: Equatable, Sendable {
    let apps: [StoreAppSummary]
    let hasMore: Bool
}

nonisolated struct StoreHomeSection: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let category: StoreAppCategory?
    let sort: StoreAppListSort
    let apps: [StoreAppSummary]
}

nonisolated struct StorePublicationRequest: Sendable {
    let storeId: String
    let name: String
    let shortDescription: String
    let description: String
    let category: StoreAppCategory
    let license: StoreLicenseIdentifier
    let sourceCode: String
    let generationSettings: ToolGenerationSettings
    let iconMasterJPEG: Data
    let iconThumbnailJPEG: Data
    let screenshotJPEGs: [Data]
    let remixedFromVersionId: String?
    var inspiredByVersionIds: [String] = []
}

nonisolated struct StoreVersionPublicationRequest: Sendable {
    let storeId: String
    let appId: String
    let license: StoreLicenseIdentifier
    let shortDescription: String
    let description: String
    let sourceCode: String
    let generationSettings: ToolGenerationSettings
    let iconMasterJPEG: Data?
    let iconThumbnailJPEG: Data?
    let screenshotJPEGs: [Data]
    let replaceScreenshots: Bool
    let remixedFromVersionId: String?
    var inspiredByVersionIds: [String] = []
}

nonisolated enum StoreGenerationContextMode: String, Codable, Equatable, Sendable {
    case base
    case baseWithCapabilities = "base_with_capabilities"
    case capabilitiesOnly = "capabilities_only"
    case scratch
}

nonisolated struct StoreGenerationContextRequest: Encodable, Equatable, Sendable {
    let originalPrompt: String
    let refinedPrompt: String
    let resolvedAppKind: ToolAppKind
    let sandboxPermissions: [String]
    let resourcePermissions: [String]
    let runtimeVersion: String
    let codingAgent: String
    let permissionMode: String

    init(
        originalPrompt: String,
        refinedPrompt: String,
        settings: ToolGenerationSettings,
        codingAgent: ToolCodingAgent,
        automaticallySelectPermissions: Bool
    ) {
        self.originalPrompt = originalPrompt
        self.refinedPrompt = refinedPrompt
        resolvedAppKind = settings.appKind
        sandboxPermissions = settings.sandboxPermissions.enabledPermissions.map(\.rawValue)
        resourcePermissions = settings.resourcePermissions.enabledPermissions.map(\.rawValue)
        runtimeVersion = IronsmithStoreConstants.runtimeVersion
        self.codingAgent = Self.value(for: codingAgent)
        permissionMode = automaticallySelectPermissions ? "automatic" : "strict"
    }

    static func value(for codingAgent: ToolCodingAgent) -> String {
        switch codingAgent {
        case .ironsmithSpark: "spark"
        case .ironsmithFlame: "flame"
        case .codex: "codex"
        case .custom: "custom"
        }
    }
}

nonisolated struct StoreGenerationBaseContext: Codable, Equatable, Sendable {
    let versionId: String
    let storeId: String
    let appId: String
    let appName: String
    let versionNumber: Int
    let runtimeVersion: String
    let appKind: ToolAppKind
    let summary: String
    let coreWorkflow: String
    let useCases: [String]
    let frameworks: [String]
    let sandboxPermissions: String
    let resourcePermissions: String
    let sourceTokenEstimate: Int
    let score: Double
    let sourceCode: String
    let sourceSha256: String
    let generationSettings: StoreGenerationSettingsDTO
    let license: StoreLicenseIdentifier
    let legalAttributions: [StoreLegalAttribution]
}

nonisolated struct StoreGenerationCapabilityContext: Codable, Equatable, Sendable {
    let id: String
    let versionId: String
    let storeId: String
    let appId: String
    let appName: String
    let title: String
    let summary: String
    let blueprint: String
    let frameworks: [String]
    let requirements: [String]
    let constraints: [String]
    let validationSteps: [String]
}

nonisolated struct StoreGenerationRequirement: Codable, Equatable, Sendable {
    let id: String
    let description: String
    let priority: String
}

nonisolated struct StoreGenerationAdaptationInstructions: Codable, Equatable, Sendable {
    let preserve: [String]
    let implement: [String]
    let removeUnrelatedBehavior: Bool
}

nonisolated struct StoreGenerationPlannerMetadata: Codable, Equatable, Sendable {
    let provider: String
    let model: String
    let promptVersion: Int
}

nonisolated struct StoreGenerationEmbeddingMetadata: Codable, Equatable, Sendable {
    let model: String
    let dimensions: Int
}

nonisolated struct StoreGenerationContextPlan: Codable, Equatable, Sendable {
    let id: String
    let mode: StoreGenerationContextMode
    let matchScore: Double
    let explanation: String
    let confidenceBand: String
    let resolvedAppKind: ToolAppKind
    let codingAgent: String
    let permissionMode: String
    let appliedStoreContextBudgetTokens: Int?
    let estimatedStoreContextTokens: Int
    let promptContext: String
    let resolvedSandboxPermissions: [String]
    let resolvedResourcePermissions: [String]
    let coveredRequirements: [StoreGenerationRequirement]
    let missingRequirements: [StoreGenerationRequirement]
    let adaptationInstructions: StoreGenerationAdaptationInstructions
    let base: StoreGenerationBaseContext?
    let capabilities: [StoreGenerationCapabilityContext]
    let inspiredByVersionIds: [String]
    let planner: StoreGenerationPlannerMetadata
    let embedding: StoreGenerationEmbeddingMetadata
}

nonisolated struct StoreGenerationContextSnapshot: Codable, Equatable, Sendable {
    let originalPrompt: String
    let refinedPrompt: String
    let plan: StoreGenerationContextPlan
}

nonisolated struct StoreListingUpdateRequest: Encodable, Sendable {
    var name: String?
    var shortDescription: String?
    var description: String?
    var category: StoreAppCategory?
    var status: StoreAppStatus?
}

nonisolated enum IronsmithStoreClientError: LocalizedError, Equatable {
    case notConfigured
    case missingSession
    case invalidResponse
    case reviewRejected(reasons: [String])
    case requestFailed(statusCode: Int, message: String)
    case sourceHashMismatch(expected: String, actual: String)
    case unsupportedLicense(String)
    case unchangedStoreVersion

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Ironsmith service is not configured."
        case .missingSession:
            return "Sign in with Ironsmith before using the Ironsmith Store."
        case .invalidResponse:
            return "The Ironsmith Store returned an invalid response."
        case .reviewRejected(let reasons):
            let explanation = reasons.map { "• \($0)" }.joined(separator: "\n")
            return "This app was not approved for the Ironsmith Store:\n\n\(explanation)"
        case .requestFailed(let statusCode, let message):
            return "The Ironsmith Store returned HTTP \(statusCode): \(message)"
        case .sourceHashMismatch:
            return "The downloaded source did not match the scanned source hash."
        case .unsupportedLicense(let identifier):
            return
                "Update Ironsmith to download or remix apps containing the \(identifier) license."
        case .unchangedStoreVersion:
            return
                "The source matches the currently published version. Make a source change before publishing a new version."
        }
    }
}

nonisolated struct IronsmithStoreClient {
    var listStores: @Sendable () async throws -> [AppStoreDescriptor]
    var listHomeSections: @Sendable (_ storeId: String) async throws -> [StoreHomeSection]
    var listApps:
        @Sendable (
            _ storeId: String,
            _ scope: StoreAppListScope,
            _ search: String?,
            _ offset: Int,
            _ sort: StoreAppListSort,
            _ category: StoreAppCategory?,
            _ creatorHandle: String?
        ) async throws
            -> StoreAppPage
    var fetchApp: @Sendable (_ storeId: String, _ appId: String) async throws -> StoreAppDetail
    var fetchVersion:
        @Sendable (_ storeId: String, _ appId: String, _ versionNumber: Int) async throws
            -> StoreVersionDownload
    var fetchSource:
        @Sendable (_ storeId: String, _ appId: String, _ versionNumber: Int) async throws
            -> StoreVersionDownload
    var publishApp: @Sendable (_ request: StorePublicationRequest) async throws -> StoreAppDetail
    var publishVersion:
        @Sendable (_ request: StoreVersionPublicationRequest) async throws -> StoreAppDetail
    var patchListing:
        @Sendable (_ storeId: String, _ appId: String, _ update: StoreListingUpdateRequest)
            async throws
            -> StoreAppDetail
    var deleteApp: @Sendable (_ storeId: String, _ appId: String) async throws -> Void
    var prepareGenerationContext:
        @Sendable (_ request: StoreGenerationContextRequest) async throws
            -> StoreGenerationContextPlan
}

extension IronsmithStoreClient {
    @MainActor
    static var live: Self {
        live(accountClient: .live)
    }

    nonisolated static func live(accountClient: IronsmithAccountClient) -> Self {
        guard let configuration = IronsmithBackendConfiguration.live else {
            return .unconfigured
        }
        let api = StoreHTTPClient(configuration: configuration, accountClient: accountClient)
        return Self(
            listStores: {
                let response: StoreDataEnvelope<[AppStoreDescriptor]> = try await api.request(
                    "api/v1/stores",
                    method: "GET",
                    authentication: .optional
                )
                return response.data
            },
            listHomeSections: { storeId in
                let response: StoreDataEnvelope<[StoreHomeSection]> = try await api.request(
                    "api/v1/stores/\(storeId)/apps/home",
                    method: "GET",
                    authentication: .optional
                )
                return response.data
            },
            listApps: { storeId, scope, search, offset, sort, category, creatorHandle in
                var queryItems = [
                    URLQueryItem(name: "scope", value: scope.rawValue),
                    URLQueryItem(name: "sort", value: sort.rawValue),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(
                        name: "limit",
                        value: String(IronsmithStoreConstants.appListPageSize)
                    ),
                ]
                if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    queryItems.append(URLQueryItem(name: "q", value: search))
                }
                if let category {
                    queryItems.append(URLQueryItem(name: "category", value: category.rawValue))
                }
                if let creatorHandle, !creatorHandle.isEmpty {
                    queryItems.append(URLQueryItem(name: "creator", value: creatorHandle))
                }
                let response: StorePageEnvelope<StoreAppSummary> = try await api.request(
                    "api/v1/stores/\(storeId)/apps",
                    method: "GET",
                    queryItems: queryItems,
                    authentication: scope == .mine ? .required : .optional
                )
                return StoreAppPage(apps: response.data, hasMore: response.hasMore)
            },
            fetchApp: { storeId, appId in
                let response: StoreDataEnvelope<StoreAppDetail> = try await api.request(
                    "api/v1/stores/\(storeId)/apps/\(appId)",
                    method: "GET",
                    authentication: .optional
                )
                return response.data
            },
            fetchVersion: { storeId, appId, versionNumber in
                let response: StoreDataEnvelope<StoreVersionDownload> = try await api.request(
                    "api/v1/stores/\(storeId)/apps/\(appId)/versions/\(versionNumber)",
                    method: "GET",
                    authentication: .required
                )
                return response.data
            },
            fetchSource: { storeId, appId, versionNumber in
                let response: StoreDataEnvelope<StoreVersionDownload> = try await api.request(
                    "api/v1/stores/\(storeId)/apps/\(appId)/versions/\(versionNumber)/source",
                    method: "GET",
                    authentication: .optional
                )
                return response.data
            },
            publishApp: { request in
                let metadata = StorePublicationMetadataPayload(
                    name: request.name,
                    shortDescription: request.shortDescription,
                    description: request.description,
                    category: request.category,
                    license: request.license,
                    runtimeVersion: IronsmithStoreConstants.runtimeVersion,
                    generationSettings: StoreGenerationSettingsDTO(
                        settings: request.generationSettings),
                    remixedFromVersionId: request.remixedFromVersionId,
                    inspiredByVersionIds: request.inspiredByVersionIds
                )
                let body = try StoreMultipartBody()
                    .addingJSONField(name: "metadata", value: metadata)
                    .addingFile(
                        name: "source",
                        filename: "ContentView.swift",
                        contentType: "text/x-swift",
                        data: Data(request.sourceCode.utf8)
                    )
                    .addingFile(
                        name: "iconMaster",
                        filename: "icon-master.jpg",
                        contentType: "image/jpeg",
                        data: request.iconMasterJPEG
                    )
                    .addingFile(
                        name: "iconThumbnail",
                        filename: "icon-thumbnail.jpg",
                        contentType: "image/jpeg",
                        data: request.iconThumbnailJPEG
                    )
                    .addingScreenshotFiles(request.screenshotJPEGs)
                let response: StoreDataEnvelope<StoreAppDetail> = try await api.request(
                    "api/v1/stores/\(request.storeId)/apps",
                    method: "POST",
                    body: body.data,
                    contentType: body.contentType,
                    authentication: .required
                )
                return response.data
            },
            publishVersion: { request in
                guard
                    (request.iconMasterJPEG == nil)
                        == (request.iconThumbnailJPEG == nil)
                else {
                    throw IronsmithStoreClientError.invalidResponse
                }
                let metadata = StoreVersionMetadataPayload(
                    license: request.license,
                    runtimeVersion: IronsmithStoreConstants.runtimeVersion,
                    generationSettings: StoreGenerationSettingsDTO(
                        settings: request.generationSettings),
                    remixedFromVersionId: request.remixedFromVersionId,
                    inspiredByVersionIds: request.inspiredByVersionIds,
                    replaceScreenshots: request.replaceScreenshots,
                    shortDescription: request.shortDescription,
                    description: request.description
                )
                var body = try StoreMultipartBody()
                    .addingJSONField(name: "metadata", value: metadata)
                    .addingFile(
                        name: "source",
                        filename: "ContentView.swift",
                        contentType: "text/x-swift",
                        data: Data(request.sourceCode.utf8)
                    )
                if let iconMasterJPEG = request.iconMasterJPEG,
                    let iconThumbnailJPEG = request.iconThumbnailJPEG
                {
                    body = body.addingFile(
                        name: "iconMaster",
                        filename: "icon-master.jpg",
                        contentType: "image/jpeg",
                        data: iconMasterJPEG
                    )
                    body = body.addingFile(
                        name: "iconThumbnail",
                        filename: "icon-thumbnail.jpg",
                        contentType: "image/jpeg",
                        data: iconThumbnailJPEG
                    )
                }
                body = body.addingScreenshotFiles(request.screenshotJPEGs)
                let response: StoreDataEnvelope<StoreAppDetail> = try await api.request(
                    "api/v1/stores/\(request.storeId)/apps/\(request.appId)/versions",
                    method: "POST",
                    body: body.data,
                    contentType: body.contentType,
                    authentication: .required
                )
                return response.data
            },
            patchListing: { storeId, appId, update in
                let response: StoreDataEnvelope<StoreAppDetail> = try await api.request(
                    "api/v1/stores/\(storeId)/apps/\(appId)",
                    method: "PATCH",
                    body: try StoreJSON.encoder.encode(update),
                    contentType: "application/json",
                    authentication: .required
                )
                return response.data
            },
            deleteApp: { storeId, appId in
                let _: StoreDataEnvelope<StoreDeletionResponse> = try await api.request(
                    "api/v1/stores/\(storeId)/apps/\(appId)",
                    method: "DELETE",
                    authentication: .required
                )
            },
            prepareGenerationContext: { request in
                let response: StoreDataEnvelope<StoreGenerationContextPlan> = try await api.request(
                    "api/v1/stores/generation-context",
                    method: "POST",
                    body: try StoreJSON.encoder.encode(request),
                    contentType: "application/json",
                    authentication: .required
                )
                return response.data
            }
        )
    }

    nonisolated static var unconfigured: Self {
        Self(
            listStores: { throw IronsmithStoreClientError.notConfigured },
            listHomeSections: { _ in throw IronsmithStoreClientError.notConfigured },
            listApps: { _, _, _, _, _, _, _ in throw IronsmithStoreClientError.notConfigured },
            fetchApp: { _, _ in throw IronsmithStoreClientError.notConfigured },
            fetchVersion: { _, _, _ in throw IronsmithStoreClientError.notConfigured },
            fetchSource: { _, _, _ in throw IronsmithStoreClientError.notConfigured },
            publishApp: { _ in throw IronsmithStoreClientError.notConfigured },
            publishVersion: { _ in throw IronsmithStoreClientError.notConfigured },
            patchListing: { _, _, _ in throw IronsmithStoreClientError.notConfigured },
            deleteApp: { _, _ in throw IronsmithStoreClientError.notConfigured },
            prepareGenerationContext: { _ in throw IronsmithStoreClientError.notConfigured }
        )
    }

    nonisolated static func sha256Hex(for sourceCode: String) -> String {
        let digest = SHA256.hash(data: Data(sourceCode.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func verifySourceHash(_ version: StoreVersionDownload) throws {
        let actual = sha256Hex(for: version.sourceCode)
        guard actual == version.sourceSha256.lowercased() else {
            throw IronsmithStoreClientError.sourceHashMismatch(
                expected: version.sourceSha256,
                actual: actual
            )
        }
    }

    nonisolated static func backendError(
        statusCode: Int,
        data: Data
    ) -> IronsmithStoreClientError {
        let decoder = StoreJSON.decoder
        let nestedError = try? decoder.decode(StoreBackendErrorEnvelope.self, from: data).error
        let topLevelError = try? decoder.decode(StoreBackendError.self, from: data)
        let backendError = nestedError ?? topLevelError

        if statusCode == 401 {
            return .missingSession
        }
        if backendError?.code == "store_review_rejected" {
            var seenReasons: Set<String> = []
            let reasons =
                backendError?.findings?
                .map { finding in
                    let detail = finding.detail?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let reason = (detail?.isEmpty == false ? detail : nil) ?? finding.summary
                    guard let line = finding.line else { return reason }
                    return "\(reason) (ContentView.swift line \(line))"
                }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seenReasons.insert($0).inserted }
                ?? []
            return .reviewRejected(
                reasons: reasons.isEmpty
                    ? [backendError?.message ?? "Automated review could not approve this app."]
                    : reasons
            )
        }
        return .requestFailed(
            statusCode: statusCode,
            message: backendError?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        )
    }
}

nonisolated private enum StoreAuthentication {
    case optional
    case required
}

nonisolated private struct StoreHTTPClient {
    let configuration: IronsmithBackendConfiguration
    let accountClient: IronsmithAccountClient

    func request<Response: Decodable>(
        _ path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        authentication: StoreAuthentication
    ) async throws -> Response {
        let request = try await makeRequest(
            path,
            method: method,
            queryItems: queryItems,
            body: body,
            contentType: contentType,
            authentication: authentication
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IronsmithStoreClientError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw IronsmithStoreClient.backendError(
                statusCode: httpResponse.statusCode,
                data: data
            )
        }
        do {
            return try StoreJSON.decoder.decode(Response.self, from: data)
        } catch {
            throw IronsmithStoreClientError.invalidResponse
        }
    }

    private func makeRequest(
        _ path: String,
        method: String,
        queryItems: [URLQueryItem],
        body: Data?,
        contentType: String?,
        authentication: StoreAuthentication
    ) async throws -> URLRequest {
        var url = configuration.apiBaseURL
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        if !queryItems.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = queryItems
            if let componentURL = components?.url {
                url = componentURL
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let token: String?
        switch authentication {
        case .optional:
            token = nil
        case .required:
            token = try await accountClient.validAccessToken()
            guard token?.isEmpty == false else {
                throw IronsmithStoreClientError.missingSession
            }
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

}

nonisolated private enum StoreJSON {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

nonisolated private struct StoreDataEnvelope<DataValue: Decodable>: Decodable {
    let data: DataValue
}

nonisolated private struct StorePageEnvelope<DataValue: Decodable>: Decodable {
    let data: [DataValue]
    let hasMore: Bool
}

nonisolated private struct StoreBackendErrorEnvelope: Decodable {
    let error: StoreBackendError
}

nonisolated private struct StoreBackendError: Decodable {
    let code: String
    let message: String
    let findings: [StoreBackendReviewFinding]?
}

nonisolated private struct StoreBackendReviewFinding: Decodable {
    let code: String
    let summary: String
    let detail: String?
    let line: Int?
}

nonisolated private struct StoreDeletionResponse: Decodable {
    let deleted: Bool
}

nonisolated private struct StorePublicationMetadataPayload: Encodable {
    let name: String
    let shortDescription: String
    let description: String
    let category: StoreAppCategory
    let license: StoreLicenseIdentifier
    let runtimeVersion: String
    let generationSettings: StoreGenerationSettingsDTO
    let remixedFromVersionId: String?
    let inspiredByVersionIds: [String]
}

nonisolated private struct StoreVersionMetadataPayload: Encodable {
    let license: StoreLicenseIdentifier
    let runtimeVersion: String
    let generationSettings: StoreGenerationSettingsDTO
    let remixedFromVersionId: String?
    let inspiredByVersionIds: [String]
    let replaceScreenshots: Bool
    let shortDescription: String
    let description: String
}

nonisolated struct StoreMultipartBody {
    let boundary: String
    private(set) var data = Data()

    init(boundary: String = "IronsmithStoreBoundary-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    func addingJSONField<Value: Encodable>(name: String, value: Value) throws -> StoreMultipartBody
    {
        try addingField(
            name: name,
            value: String(data: StoreJSON.encoder.encode(value), encoding: .utf8) ?? "{}")
    }

    func addingField(name: String, value: String) throws -> StoreMultipartBody {
        var copy = self
        copy.append("--\(boundary)\r\n")
        copy.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        copy.append(value)
        copy.append("\r\n")
        return copy
    }

    func addingFile(name: String, filename: String, contentType: String, data fileData: Data)
        -> StoreMultipartBody
    {
        var copy = self
        copy.append("--\(boundary)\r\n")
        copy.append(
            "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        copy.append("Content-Type: \(contentType)\r\n\r\n")
        copy.data.append(fileData)
        copy.append("\r\n")
        return copy
    }

    func addingScreenshotFiles(_ screenshots: [Data]) -> StoreMultipartBody {
        var copy = self
        for (index, screenshot) in screenshots.enumerated() {
            copy = copy.addingFile(
                name: "screenshots",
                filename: "screenshot-\(index + 1).jpg",
                contentType: "image/jpeg",
                data: screenshot
            )
        }
        return copy.finalized()
    }

    private func finalized() -> StoreMultipartBody {
        var copy = self
        copy.append("--\(boundary)--\r\n")
        return copy
    }

    private mutating func append(_ string: String) {
        data.append(Data(string.utf8))
    }
}
