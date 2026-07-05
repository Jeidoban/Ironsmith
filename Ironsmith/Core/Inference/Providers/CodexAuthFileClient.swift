import Foundation

nonisolated struct CodexAuthFileClient: Sendable {
    var credential: @Sendable () throws -> OpenAICodexCredential?
    var saveCredential: @Sendable (OpenAICodexCredential) throws -> Void
}

extension CodexAuthFileClient {
    nonisolated static func live(authFileURL: URL = IronsmithPaths.codexAuthFileURL) -> Self {
        Self(
            credential: {
                try credential(from: authFileURL)
            },
            saveCredential: { credential in
                try save(credential, to: authFileURL)
            }
        )
    }

    nonisolated static var unconfigured: Self {
        Self(
            credential: { nil },
            saveCredential: { _ in }
        )
    }

    nonisolated static func credential(from authFileURL: URL) throws -> OpenAICodexCredential? {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: authFileURL)
        return try credential(from: data)
    }

    nonisolated static func credential(from data: Data) throws -> OpenAICodexCredential? {
        let object = try JSONObject(data: data)
        if let authMode = object.dictionary["auth_mode"] as? String,
           authMode != "chatgpt" {
            return nil
        }
        guard let tokens = object.dictionary["tokens"] as? [String: Any] else {
            throw OpenAICodexAuthClientError.invalidAuthFile
        }
        guard let accessToken = nonEmptyString(tokens["access_token"]) else {
            throw OpenAICodexAuthClientError.invalidAuthFile
        }

        let idToken = nonEmptyString(tokens["id_token"])
        let claims = OpenAICodexJWTClaims.bestClaims(
            idToken: idToken,
            accessToken: accessToken
        )
        return OpenAICodexCredential(
            accessToken: accessToken,
            refreshToken: nonEmptyString(tokens["refresh_token"]),
            expiresAt: claims.expiresAt,
            idToken: idToken,
            accountID: nonEmptyString(tokens["account_id"]) ?? claims.accountID,
            email: claims.email
        )
    }

    nonisolated static func save(_ credential: OpenAICodexCredential, to authFileURL: URL) throws {
        let existingData = try? Data(contentsOf: authFileURL)
        let data = try updatedAuthData(
            existingData: existingData,
            credential: credential,
            refreshDate: Date()
        )
        try FileManager.default.createDirectory(
            at: authFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: authFileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: authFileURL.path
        )
    }

    nonisolated static func updatedAuthData(
        existingData: Data?,
        credential: OpenAICodexCredential,
        refreshDate: Date
    ) throws -> Data {
        let object: JSONObject
        if let existingData {
            object = try JSONObject(data: existingData)
        } else {
            object = JSONObject(dictionary: [:])
        }
        var root = object.dictionary
        var tokens = root["tokens"] as? [String: Any] ?? [:]

        root["auth_mode"] = root["auth_mode"] ?? "chatgpt"
        root["OPENAI_API_KEY"] = root["OPENAI_API_KEY"] ?? NSNull()
        tokens["access_token"] = credential.accessToken
        tokens["refresh_token"] = credential.refreshToken ?? NSNull()
        tokens["id_token"] = credential.idToken ?? NSNull()
        tokens["account_id"] = credential.accountID ?? NSNull()
        root["tokens"] = tokens
        root["last_refresh"] = Self.timestampString(from: refreshDate)

        return try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    nonisolated private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func timestampString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

nonisolated private struct JSONObject {
    var dictionary: [String: Any]

    init(dictionary: [String: Any]) {
        self.dictionary = dictionary
    }

    init(data: Data) throws {
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAICodexAuthClientError.invalidAuthFile
        }
        self.dictionary = dictionary
    }
}
