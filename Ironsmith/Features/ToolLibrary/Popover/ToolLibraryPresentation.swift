import Foundation

nonisolated enum ToolLibraryViewMode: String, CaseIterable, Identifiable, Sendable {
    case list
    case icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list:
            return "List"
        case .icons:
            return "Icons"
        }
    }

    var systemImage: String {
        switch self {
        case .list:
            return "list.bullet"
        case .icons:
            return "square.grid.2x2"
        }
    }

    static func resolved(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .list
    }
}

nonisolated enum ToolLibrarySortOrder: String, CaseIterable, Identifiable, Sendable {
    case latest
    case alphabetical

    var id: String { rawValue }

    var title: String {
        switch self {
        case .latest:
            return "Latest"
        case .alphabetical:
            return "Alphabetical"
        }
    }

    static func resolved(_ rawValue: String) -> Self {
        Self(rawValue: rawValue) ?? .latest
    }
}

@MainActor
enum ToolLibraryPresentation {
    static func visibleTools(
        from tools: [Tool],
        searchText: String,
        sortOrder: ToolLibrarySortOrder
    ) -> [Tool] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredTools = query.isEmpty
            ? tools
            : tools.filter { $0.name.localizedCaseInsensitiveContains(query) }

        return filteredTools.sorted { lhs, rhs in
            switch sortOrder {
            case .latest:
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return compareNamesThenIDs(lhs, rhs)
            case .alphabetical:
                let comparison = lhs.name.localizedStandardCompare(rhs.name)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    private static func compareNamesThenIDs(_ lhs: Tool, _ rhs: Tool) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
