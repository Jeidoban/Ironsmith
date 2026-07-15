import Foundation

nonisolated enum ToolImageGenerationProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case imagePlayground = "image_playground"
    case gemini
    case openAI = "openai"
    case ironsmith
    case disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .imagePlayground:
            return "Image Playground"
        case .gemini:
            return "Gemini"
        case .openAI:
            return "OpenAI"
        case .ironsmith:
            return "Ironsmith"
        case .disabled:
            return "Off"
        }
    }
}
