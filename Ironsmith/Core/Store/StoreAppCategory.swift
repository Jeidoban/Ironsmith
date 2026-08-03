import Foundation

nonisolated enum StoreAppCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case business
    case developerTools
    case education
    case entertainment
    case finance
    case games
    case graphicsDesign
    case healthFitness
    case lifestyle
    case music
    case productivity
    case utilities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .business: "Business"
        case .developerTools: "Developer Tools"
        case .education: "Education"
        case .entertainment: "Entertainment"
        case .finance: "Finance"
        case .games: "Games"
        case .graphicsDesign: "Graphics & Design"
        case .healthFitness: "Health & Fitness"
        case .lifestyle: "Lifestyle"
        case .music: "Music"
        case .productivity: "Productivity"
        case .utilities: "Utilities"
        }
    }

    var systemImage: String {
        switch self {
        case .business: "briefcase"
        case .developerTools: "hammer"
        case .education: "graduationcap"
        case .entertainment: "play.rectangle"
        case .finance: "dollarsign.circle"
        case .games: "gamecontroller"
        case .graphicsDesign: "paintbrush"
        case .healthFitness: "heart"
        case .lifestyle: "leaf"
        case .music: "music.note"
        case .productivity: "checkmark.circle"
        case .utilities: "wrench.and.screwdriver"
        }
    }

    var applicationCategoryType: String {
        switch self {
        case .business: "public.app-category.business"
        case .developerTools: "public.app-category.developer-tools"
        case .education: "public.app-category.education"
        case .entertainment: "public.app-category.entertainment"
        case .finance: "public.app-category.finance"
        case .games: "public.app-category.games"
        case .graphicsDesign: "public.app-category.graphics-design"
        case .healthFitness: "public.app-category.healthcare-fitness"
        case .lifestyle: "public.app-category.lifestyle"
        case .music: "public.app-category.music"
        case .productivity: "public.app-category.productivity"
        case .utilities: "public.app-category.utilities"
        }
    }
}
