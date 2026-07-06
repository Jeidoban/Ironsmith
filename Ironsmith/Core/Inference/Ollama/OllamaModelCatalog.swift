import Foundation

enum OllamaModelCatalog {
    struct Entry: Identifiable, Equatable {
        let displayName: String
        let identifier: String
        let memoryRequirement: MemoryRequirement

        var id: String { identifier }

        init(
            displayName: String,
            identifier: String,
            memoryRequirement: MemoryRequirement
        ) {
            self.displayName = displayName
            self.identifier = identifier
            self.memoryRequirement = memoryRequirement
        }
    }

    enum MemoryRequirement: Int, CaseIterable, Identifiable {
        case gb8 = 8
        case gb16 = 16
        case gb24 = 24
        case gb32 = 32
        case gb48 = 48

        var id: Int { rawValue }

        var title: String {
            "\(rawValue) GB RAM"
        }

        var subtitle: String {
            "Recommended for machines with \(rawValue) GB memory and higher"
        }
    }

    struct Section: Identifiable, Equatable {
        let memoryRequirement: MemoryRequirement
        let entries: [Entry]

        var id: MemoryRequirement.ID { memoryRequirement.id }
        var title: String { memoryRequirement.title }
        var subtitle: String { memoryRequirement.subtitle }
    }

    static let all: [Entry] = [
        Entry(
            displayName: "Gemma 4 E2B",
            identifier: "gemma4:e2b",
            memoryRequirement: .gb8
        ),
        Entry(
            displayName: "Gemma 4 E4B Q8",
            identifier: "gemma4:e4b-it-q8_0",
            memoryRequirement: .gb16
        ),
        Entry(
            displayName: "Gemma 4 12B",
            identifier: "gemma4:12b",
            memoryRequirement: .gb16
        ),
        Entry(
            displayName: "Gemma 4 12B Q8",
            identifier: "gemma4:12b-it-q8_0",
            memoryRequirement: .gb24
        ),
        Entry(
            displayName: "Gemma 4 26B",
            identifier: "gemma4:26b",
            memoryRequirement: .gb24
        ),
        Entry(
            displayName: "Qwen 3.6 35B",
            identifier: "qwen3.6:35b",
            memoryRequirement: .gb32
        ),
        Entry(
            displayName: "Gemma 4 26B Q8",
            identifier: "gemma4:26b-a4b-it-q8_0",
            memoryRequirement: .gb32
        ),
        Entry(
            displayName: "Qwen 3.6 35B Q8",
            identifier: "qwen3.6:35b-a3b-q8_0",
            memoryRequirement: .gb48
        ),
    ]

    static var sections: [Section] {
        MemoryRequirement.allCases.compactMap { memoryRequirement in
            let entries = all.filter { $0.memoryRequirement == memoryRequirement }
            guard !entries.isEmpty else { return nil }
            return Section(memoryRequirement: memoryRequirement, entries: entries)
        }
    }

    static func displayName(forIdentifier identifier: String) -> String? {
        all.first {
            $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame
        }?.displayName
    }
}
