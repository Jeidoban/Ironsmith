import Foundation
import SwiftData

@MainActor
struct ToolRepository {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func insert(_ tool: Tool) {
        modelContext.insert(tool)
    }

    func save() throws {
        if modelContext.hasChanges {
            try modelContext.save()
        }
    }

    func rollback() {
        modelContext.rollback()
    }
}
