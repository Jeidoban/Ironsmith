import Foundation

enum ToolLibraryDebugPopoverEmptyStateMode: String, CaseIterable, Identifiable {
    case off
    case noApps
    case noAppsNoModels

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:
            return "Off"
        case .noApps:
            return "No Apps"
        case .noAppsNoModels:
            return "No Apps and No Models"
        }
    }

    var forcesNoApps: Bool {
        switch self {
        case .off:
            return false
        case .noApps, .noAppsNoModels:
            return true
        }
    }

    var forcesNoModels: Bool {
        switch self {
        case .off, .noApps:
            return false
        case .noAppsNoModels:
            return true
        }
    }
}
