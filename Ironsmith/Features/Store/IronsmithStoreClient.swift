import CryptoKit
import Foundation

nonisolated enum IronsmithStoreConstants {
    static let communityStoreId = "00000000-0000-4000-8000-000000000011"

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
    case screenshot
}

nonisolated enum StoreAppCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case productivity
    case utilities
    case developerTools
    case creativity
    case education
    case finance
    case lifestyle
    case entertainment
    case reference
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .productivity: "Productivity"
        case .utilities: "Utilities"
        case .developerTools: "Developer Tools"
        case .creativity: "Creativity"
        case .education: "Education"
        case .finance: "Finance"
        case .lifestyle: "Lifestyle"
        case .entertainment: "Entertainment"
        case .reference: "Reference"
        case .other: "Other"
        }
    }
}

nonisolated enum StoreAppListSort: String, Codable, Hashable, Sendable {
    case recent
    case trending
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
    let license: String
    let scannerVersion: String
    let remixedFromVersionId: String?
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
    let license: String
    let scannerVersion: String
    let remixedFromVersionId: String?
    let publishedAt: String
    let sourceCode: String
}

nonisolated struct StoreRemixMetadata: Decodable, Equatable, Sendable {
    let storeId: String
    let appId: String
    let appName: String
    let versionId: String
    let versionNumber: Int
}

nonisolated struct StoreAppSummary: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let storeId: String
    let authorDisplayName: String
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
    let name: String
    let shortDescription: String
    let description: String
    let category: StoreAppCategory
    let status: StoreAppStatus
    let publishedAt: String
    let createdAt: String
    let updatedAt: String
    let icon: StoreAsset?
    let screenshots: [StoreAsset]
    let currentVersion: StoreVersionMetadata
    let recentVersions: [StoreVersionMetadata]
    let remix: StoreRemixMetadata?

    var iconAsset: StoreAsset? {
        icon
    }

}

nonisolated struct StoreAppPage: Equatable, Sendable {
    let apps: [StoreAppSummary]
    let nextCursor: String?
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
    let sourceCode: String
    let generationSettings: ToolGenerationSettings
    let iconPNG: Data
    let screenshotPNGs: [Data]
    let remixedFromVersionId: String?
}

nonisolated struct StoreVersionPublicationRequest: Sendable {
    let storeId: String
    let appId: String
    let sourceCode: String
    let generationSettings: ToolGenerationSettings
    let iconPNG: Data?
    let screenshotPNGs: [Data]
    let replaceScreenshots: Bool
    let remixedFromVersionId: String?
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
    case requestFailed(statusCode: Int, message: String)
    case sourceHashMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Ironsmith service is not configured."
        case .missingSession:
            return "Sign in with Ironsmith before using the App Store."
        case .invalidResponse:
            return "The App Store returned an invalid response."
        case .requestFailed(let statusCode, let message):
            return "The App Store returned HTTP \(statusCode): \(message)"
        case .sourceHashMismatch:
            return "The downloaded source did not match the scanned source hash."
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
            _ cursor: String?,
            _ sort: StoreAppListSort,
            _ category: StoreAppCategory?
        ) async throws
            -> StoreAppPage
    var fetchApp: @Sendable (_ storeId: String, _ appId: String) async throws -> StoreAppDetail
    var fetchVersion:
        @Sendable (_ storeId: String, _ appId: String, _ versionNumber: Int) async throws
            -> StoreVersionDownload
    var publishApp: @Sendable (_ request: StorePublicationRequest) async throws -> StoreAppDetail
    var publishVersion:
        @Sendable (_ request: StoreVersionPublicationRequest) async throws -> StoreAppDetail
    var patchListing:
        @Sendable (_ storeId: String, _ appId: String, _ update: StoreListingUpdateRequest)
            async throws
            -> StoreAppDetail
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
            listApps: { storeId, scope, search, cursor, sort, category in
                var queryItems = [
                    URLQueryItem(name: "scope", value: scope.rawValue),
                    URLQueryItem(name: "sort", value: sort.rawValue),
                ]
                if let search, !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    queryItems.append(URLQueryItem(name: "q", value: search))
                }
                if let category {
                    queryItems.append(URLQueryItem(name: "category", value: category.rawValue))
                }
                if let cursor {
                    queryItems.append(URLQueryItem(name: "cursor", value: cursor))
                }
                let response: StorePageEnvelope<StoreAppSummary> = try await api.request(
                    "api/v1/stores/\(storeId)/apps",
                    method: "GET",
                    queryItems: queryItems,
                    authentication: scope == .mine ? .required : .optional
                )
                return StoreAppPage(apps: response.data, nextCursor: response.nextCursor)
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
                    runtimeVersion: IronsmithStoreConstants.runtimeVersion,
                    generationSettings: StoreGenerationSettingsDTO(
                        settings: request.generationSettings),
                    remixedFromVersionId: request.remixedFromVersionId
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
                        name: "icon", filename: "icon.png", contentType: "image/png",
                        data: request.iconPNG
                    )
                    .addingScreenshotFiles(request.screenshotPNGs)
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
                let metadata = StoreVersionMetadataPayload(
                    runtimeVersion: IronsmithStoreConstants.runtimeVersion,
                    generationSettings: StoreGenerationSettingsDTO(
                        settings: request.generationSettings),
                    remixedFromVersionId: request.remixedFromVersionId,
                    replaceScreenshots: request.replaceScreenshots
                )
                var body = try StoreMultipartBody()
                    .addingJSONField(name: "metadata", value: metadata)
                    .addingFile(
                        name: "source",
                        filename: "ContentView.swift",
                        contentType: "text/x-swift",
                        data: Data(request.sourceCode.utf8)
                    )
                if let iconPNG = request.iconPNG {
                    body = body.addingFile(
                        name: "icon", filename: "icon.png", contentType: "image/png", data: iconPNG)
                }
                body = body.addingScreenshotFiles(request.screenshotPNGs)
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
            }
        )
    }

    nonisolated static var unconfigured: Self {
        Self(
            listStores: { throw IronsmithStoreClientError.notConfigured },
            listHomeSections: { _ in throw IronsmithStoreClientError.notConfigured },
            listApps: { _, _, _, _, _, _ in throw IronsmithStoreClientError.notConfigured },
            fetchApp: { _, _ in throw IronsmithStoreClientError.notConfigured },
            fetchVersion: { _, _, _ in throw IronsmithStoreClientError.notConfigured },
            publishApp: { _ in throw IronsmithStoreClientError.notConfigured },
            publishVersion: { _ in throw IronsmithStoreClientError.notConfigured },
            patchListing: { _, _, _ in throw IronsmithStoreClientError.notConfigured }
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
            throw Self.backendError(statusCode: httpResponse.statusCode, data: data)
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

    private static func backendError(statusCode: Int, data: Data) -> IronsmithStoreClientError {
        let decoder = StoreJSON.decoder
        let nestedError = try? decoder.decode(StoreBackendErrorEnvelope.self, from: data).error
        let topLevelError = try? decoder.decode(StoreBackendError.self, from: data)
        let backendError = nestedError ?? topLevelError

        if statusCode == 401 {
            return .missingSession
        }
        return .requestFailed(
            statusCode: statusCode,
            message: backendError?.message
                ?? HTTPURLResponse.localizedString(forStatusCode: statusCode)
        )
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
    let nextCursor: String?
}

nonisolated private struct StoreBackendErrorEnvelope: Decodable {
    let error: StoreBackendError
}

nonisolated private struct StoreBackendError: Decodable {
    let code: String
    let message: String
}

nonisolated private struct StorePublicationMetadataPayload: Encodable {
    let name: String
    let shortDescription: String
    let description: String
    let category: StoreAppCategory
    let runtimeVersion: String
    let generationSettings: StoreGenerationSettingsDTO
    let remixedFromVersionId: String?
}

nonisolated private struct StoreVersionMetadataPayload: Encodable {
    let runtimeVersion: String
    let generationSettings: StoreGenerationSettingsDTO
    let remixedFromVersionId: String?
    let replaceScreenshots: Bool
}

nonisolated private struct StoreMultipartBody {
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
                filename: "screenshot-\(index + 1).png",
                contentType: "image/png",
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
