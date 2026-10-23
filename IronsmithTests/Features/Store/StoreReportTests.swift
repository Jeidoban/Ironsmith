import Foundation
import Supabase
import Testing

@testable import Ironsmith

struct StoreReportTests {
    @Test
    func storeClientPostsAuthenticatedCurrentVersionReport() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StoreReportURLProtocol.self]
        let urlSession = URLSession(configuration: sessionConfiguration)
        StoreReportURLProtocol.capture.reset()

        let configuration = IronsmithBackendConfiguration(
            supabaseURL: URL(string: "https://supabase.example")!,
            publishableKey: "test-publishable-key",
            apiBaseURL: URL(string: "https://api.example")!
        )
        var accountClient = IronsmithAccountClient.unconfigured
        accountClient.currentSession = { Self.storeSession() }
        accountClient.validAccessToken = { "signed-in-token" }
        let client = IronsmithStoreClient.configured(
            configuration: configuration,
            accountClient: accountClient,
            session: urlSession,
            publicationSession: urlSession
        )
        let request = Self.reportRequest

        let receipt = try await client.reportApp(request)

        #expect(receipt.id == "00000000-0000-4000-8000-000000000105")
        let captured = try #require(StoreReportURLProtocol.capture.request)
        #expect(captured.httpMethod == "POST")
        #expect(
            captured.url?.absoluteString
                == "https://api.example/api/v1/stores/\(request.storeId)/apps/\(request.appId)/reports"
        )
        #expect(captured.value(forHTTPHeaderField: "Authorization") == "Bearer signed-in-token")
        #expect(captured.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(StoreReportURLProtocol.capture.body)
        let object = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: String]
        )
        #expect(
            object == [
                "versionId": request.versionId,
                "reason": request.reason.rawValue,
                "details": "Unexpected network traffic.",
            ]
        )
    }

    @MainActor
    @Test
    func storeCoordinatesReportSubmissionAndConfirmation() async {
        let recorder = StoreReportRequestRecorder()
        var client = IronsmithStoreClient.unconfigured
        client.reportApp = { request in
            await recorder.record(request)
            return StoreAppReportReceipt(
                id: "00000000-0000-4000-8000-000000000105",
                createdAt: "2026-09-16T12:00:00.000Z"
            )
        }
        let store = Self.makeStore(client: client)

        let didSubmit = await store.submitReport(Self.reportRequest)

        #expect(didSubmit)
        #expect(store.reportingAppID == nil)
        #expect(store.reportConfirmationMessage == "Thanks. Your report was submitted.")
        #expect(store.errorMessage == nil)
        #expect(await recorder.request == Self.reportRequest)
    }

    @MainActor
    @Test
    func failedReportSubmissionKeepsTheComposerAvailable() async {
        var client = IronsmithStoreClient.unconfigured
        client.reportApp = { _ in
            throw IronsmithStoreClientError.requestFailed(
                statusCode: 400,
                message: "The reported version does not belong to this app."
            )
        }
        let store = Self.makeStore(client: client)

        let didSubmit = await store.submitReport(Self.reportRequest)

        #expect(!didSubmit)
        #expect(store.reportingAppID == nil)
        #expect(store.reportConfirmationMessage == nil)
        #expect(store.errorMessage?.contains("does not belong") == true)
    }

    @Test
    func reportDetailsUseUnicodeCodePointLimit() {
        let emoji = String(repeating: "\u{1F680}", count: 1_000)

        #expect(StoreAppReportSheet.detailsCharacterCount(emoji) == 1_000)
        #expect(StoreAppReportSheet.truncateDetails(emoji + "x") == emoji)
    }

    @Test
    func reportDetailsAreRequiredAndTrimmed() {
        #expect(StoreAppReportSheet.validatedDetails("  \n ") == nil)
        #expect(StoreAppReportSheet.validatedDetails("  Reproduces on launch.  ") == "Reproduces on launch.")
    }

    private static let reportRequest = StoreAppReportRequest(
        storeId: IronsmithStoreConstants.communityStoreId,
        appId: "00000000-0000-4000-8000-000000000101",
        versionId: "00000000-0000-4000-8000-000000000102",
        reason: .securityPrivacy,
        details: "Unexpected network traffic."
    )

    @MainActor
    private static func makeStore(client: IronsmithStoreClient) -> StoreWindowStore {
        StoreWindowStore(
            client: client,
            importClient: StoreToolImportClient(importTool: { _, _ in
                throw IronsmithStoreClientError.notConfigured
            }),
            buildClient: ToolBuildClient(buildTool: { _ in })
        )
    }

    nonisolated private static func storeSession() -> Session {
        Session(
            accessToken: "signed-in-token",
            tokenType: "bearer",
            expiresIn: 3_600,
            expiresAt: Date().addingTimeInterval(3_600).timeIntervalSince1970,
            refreshToken: "refresh-token",
            user: User(
                id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
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
}

private actor StoreReportRequestRecorder {
    private(set) var request: StoreAppReportRequest?

    func record(_ request: StoreAppReportRequest) {
        self.request = request
    }
}

private final class StoreReportRequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequest: URLRequest?
    private var capturedBody: Data?

    var request: URLRequest? {
        lock.withLock { capturedRequest }
    }

    var body: Data? {
        lock.withLock { capturedBody }
    }

    func record(_ request: URLRequest, body: Data?) {
        lock.withLock {
            capturedRequest = request
            capturedBody = body
        }
    }

    func reset() {
        lock.withLock {
            capturedRequest = nil
            capturedBody = nil
        }
    }
}

private final class StoreReportURLProtocol: URLProtocol, @unchecked Sendable {
    static let capture = StoreReportRequestCapture()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capture.record(request, body: requestBody())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 201,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(
                #"{"data":{"id":"00000000-0000-4000-8000-000000000105","createdAt":"2026-09-16T12:00:00.000Z"}}"#.utf8
            )
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBody() -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
