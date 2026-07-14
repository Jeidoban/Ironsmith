import Foundation
import ImagePlayground
import Observation

enum ImagePlaygroundSheetError: LocalizedError {
    case unavailable
    case busy
    case canceled

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Image Playground is unavailable."
        case .busy:
            return "Image Playground is already creating an image."
        case .canceled:
            return "Image Playground was canceled."
        }
    }
}

@MainActor
@Observable
final class ImagePlaygroundSheetCoordinator {
    static let shared = ImagePlaygroundSheetCoordinator()

    private(set) var isPresented = false
    private(set) var prompt = ""
    @ObservationIgnored private var continuation: CheckedContinuation<URL, Error>?

    var isAvailable: Bool {
        ImagePlaygroundViewController.isAvailable
    }

    func generate(prompt: String) async throws -> URL {
        guard isAvailable else { throw ImagePlaygroundSheetError.unavailable }
        guard continuation == nil else { throw ImagePlaygroundSheetError.busy }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ToolAppBundleError.iconGenerationProducedNoImage
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.prompt = trimmedPrompt
                self.continuation = continuation
                isPresented = true
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(throwing: CancellationError())
            }
        }
    }

    func completed(with url: URL) {
        finish(returning: url)
    }

    func canceled() {
        finish(throwing: ImagePlaygroundSheetError.canceled)
    }

    func presentationChanged(_ presented: Bool) {
        isPresented = presented
        if !presented, continuation != nil {
            canceled()
        }
    }

    private func finish(returning url: URL) {
        let continuation = continuation
        self.continuation = nil
        isPresented = false
        continuation?.resume(returning: url)
    }

    private func finish(throwing error: Error) {
        let continuation = continuation
        self.continuation = nil
        isPresented = false
        continuation?.resume(throwing: error)
    }
}
