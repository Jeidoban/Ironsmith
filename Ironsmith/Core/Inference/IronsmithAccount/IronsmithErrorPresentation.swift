import Foundation

enum IronsmithErrorPresentation {
    static func message(for error: Error) -> String? {
        isCancellation(error) ? nil : error.localizedDescription
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }

        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return true
        }

        if nsError.domain == "com.apple.AuthenticationServices.WebAuthenticationSession",
           nsError.code == 1 {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           isCancellation(underlyingError) {
            return true
        }

        let description = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return description == "cancelled" || description == "canceled"
    }
}
