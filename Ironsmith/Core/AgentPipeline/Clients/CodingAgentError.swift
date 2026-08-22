import Foundation

enum CodingAgentError: LocalizedError, Equatable {
    case protectedFileChanged(String)
    case missingContentView

    var errorDescription: String? {
        switch self {
        case .protectedFileChanged(let path):
            return
                "The coding agent changed \(path), but Ironsmith only allows the agent to edit ContentView.swift."
        case .missingContentView:
            return "The coding agent did not create ContentView.swift."
        }
    }
}
