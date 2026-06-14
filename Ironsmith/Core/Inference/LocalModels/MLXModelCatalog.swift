import Foundation

enum MLXModelCatalog {
    struct Entry: Identifiable {
        let displayName: String
        let identifier: String  // HuggingFace Hub ID — used for download and as ModelConfig.identifier
        let generationDefaults: ModelGenerationDefaults

        var id: String { identifier }

        init(
            displayName: String,
            identifier: String,
            generationDefaults: ModelGenerationDefaults = .qwenDefaults
        ) {
            self.displayName = displayName
            self.identifier = identifier
            self.generationDefaults = generationDefaults
        }
    }

    static let all: [Entry] = [
        // MLX models are performing very badly and I don't know why.
        // So disabling them for now and gonna rely on Ollama until I figure it out.
//        Entry(
//            displayName: "Qwen 3.5 4B",
//            identifier: "mlx-community/Qwen3.5-4B-MLX-4bit",
//            generationDefaults: .qwenDefaults
//        ),
//        Entry(
//            displayName: "Qwen 3.5 9B",
//            identifier: "mlx-community/Qwen3.5-9B-8bit",
//            generationDefaults: .qwenDefaults
//        ),
//        Entry(
//            displayName: "Qwen 3.6 35B 4-bit",
//            identifier: "unsloth/Qwen3.6-35B-A3B-UD-MLX-4bit",
//            generationDefaults: .qwenDefaults
//        ),
//        Entry(
//            displayName: "Qwen 3.6 35B 8-bit",
//            identifier: "unsloth/Qwen3.6-35B-A3B-MLX-8bit",
//            generationDefaults: .qwenDefaults
//        ),
    ]

    static let generationDefaultsByIdentifier = Dictionary(
        uniqueKeysWithValues: all.map { ($0.identifier, $0.generationDefaults) }
    )
}
