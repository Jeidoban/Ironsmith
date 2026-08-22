import Foundation
import Observation

@MainActor
@Observable
final class CustomCodingAgentTestStore {
    private(set) var output: String?
    private(set) var errorMessage: String?
    private(set) var isRunning = false

    @ObservationIgnored private let client: CustomCodingAgentTestClient
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var activeRunID: UUID?

    init(client: CustomCodingAgentTestClient = .live()) {
        self.client = client
    }

    func run(
        agent: CustomCodingAgent,
        validate: (CustomCodingAgent) throws -> CustomCodingAgent
    ) {
        let validatedAgent: CustomCodingAgent
        do {
            validatedAgent = try validate(agent)
        } catch {
            reset()
            errorMessage = error.localizedDescription
            return
        }

        task?.cancel()
        let runID = UUID()
        activeRunID = runID
        output = nil
        errorMessage = nil
        isRunning = true

        task = Task { [client] in
            do {
                try await client.run(validatedAgent) { entry in
                    await self.append(entry, for: runID)
                }
                self.finish(runID: runID)
            } catch is CancellationError {
                self.finish(runID: runID)
            } catch {
                self.finish(runID: runID, error: error)
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        activeRunID = nil
        output = nil
        errorMessage = nil
        isRunning = false
    }

    private func append(_ entry: CustomCodingAgentOutput, for runID: UUID) {
        guard activeRunID == runID else { return }
        let text = CustomCodingAgentTranscriptReader.displayEntries(from: [entry])
            .map(\.text)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        if let output {
            self.output = output + "\n" + text
        } else {
            output = text
        }
    }

    private func finish(runID: UUID, error: Error? = nil) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        task = nil
        isRunning = false
        errorMessage = error?.localizedDescription
    }
}
