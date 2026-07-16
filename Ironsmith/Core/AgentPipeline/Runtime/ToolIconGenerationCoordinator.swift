import Foundation

nonisolated struct ToolIconGenerationHandle: Sendable {
    fileprivate let completion: ToolIconGenerationCompletion

    func wait() async throws {
        try await completion.wait()
    }
}

private actor ToolIconGenerationCompletion {
    private var result: Result<Void, any Error>?
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    func wait() async throws {
        let waiterID = UUID()
        try Task.checkCancellation()

        try await withTaskCancellationHandler {
            if let result {
                return try result.get()
            }

            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    func finish(with result: Result<Void, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pendingWaiters = waiters.values
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume(with: result)
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
    }
}

actor ToolIconGenerationCoordinator {
    private struct Entry {
        let id: UUID
        let handle: ToolIconGenerationHandle
        let task: Task<Void, Never>
    }

    private var entries: [String: Entry] = [:]

    func generation(
        for packageRootURL: URL,
        operation: @escaping @Sendable () async throws -> Void
    ) -> ToolIconGenerationHandle {
        let key = Self.key(for: packageRootURL)
        if let entry = entries[key] {
            return entry.handle
        }

        let id = UUID()
        let completion = ToolIconGenerationCompletion()
        let handle = ToolIconGenerationHandle(completion: completion)
        let task = Task { [weak self] in
            let result: Result<Void, any Error>
            do {
                try await operation()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await completion.finish(with: result)
            await self?.removeEntry(forKey: key, id: id)
        }
        entries[key] = Entry(id: id, handle: handle, task: task)
        return handle
    }

    func cancelGeneration(for packageRootURL: URL) {
        entries[Self.key(for: packageRootURL)]?.task.cancel()
    }

    private func removeEntry(forKey key: String, id: UUID) {
        guard entries[key]?.id == id else { return }
        entries.removeValue(forKey: key)
    }

    nonisolated private static func key(for packageRootURL: URL) -> String {
        packageRootURL.standardizedFileURL.path
    }
}
