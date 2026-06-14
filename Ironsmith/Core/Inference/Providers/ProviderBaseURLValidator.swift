import Foundation

nonisolated enum ProviderBaseURLValidator {
    static func validatedURL(from rawValue: String) throws -> URL {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHost = components.host ?? components.percentEncodedHost,
              !rawHost.isEmpty
        else {
            throw ProviderBaseURLValidationError.invalidURL
        }

        switch scheme {
        case "https":
            return url
        case "http" where isAllowedLocalHTTPHost(rawHost):
            return url
        default:
            throw ProviderBaseURLValidationError.disallowedURL
        }
    }

    static func isAllowedLocalHTTPHost(_ rawHost: String) -> Bool {
        let host = rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()

        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host == "0.0.0.0"
            || host.hasSuffix(".localhost")
    }

    static func usesAllowedLocalHost(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("http://[::1]")
            || lowercased.hasPrefix("https://[::1]")
        {
            return true
        }

        guard let components = URLComponents(string: trimmed),
              let rawHost = components.host ?? components.percentEncodedHost
        else {
            return false
        }

        return isAllowedLocalHTTPHost(rawHost)
    }
}

enum ProviderBaseURLValidationError: Error {
    case invalidURL
    case disallowedURL
}
