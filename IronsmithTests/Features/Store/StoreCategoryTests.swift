import Testing
@testable import Ironsmith

@Suite("Store Categories")
struct StoreCategoryTests {
    @Test
    func categoriesMatchTheStoreSidebarTaxonomy() {
        #expect(
            StoreAppCategory.allCases.map(\.title) == [
                "Business",
                "Developer Tools",
                "Education",
                "Entertainment",
                "Finance",
                "Games",
                "Graphics & Design",
                "Health & Fitness",
                "Lifestyle",
                "Music",
                "Productivity",
                "Utilities",
            ]
        )
        #expect(StoreAppCategory.allCases.allSatisfy { !$0.systemImage.isEmpty })
    }

    @Test
    func categoriesMapToAppleApplicationCategoryTypes() {
        #expect(
            Dictionary(
                uniqueKeysWithValues: StoreAppCategory.allCases.map {
                    ($0, $0.applicationCategoryType)
                }
            ) == [
                .business: "public.app-category.business",
                .developerTools: "public.app-category.developer-tools",
                .education: "public.app-category.education",
                .entertainment: "public.app-category.entertainment",
                .finance: "public.app-category.finance",
                .games: "public.app-category.games",
                .graphicsDesign: "public.app-category.graphics-design",
                .healthFitness: "public.app-category.healthcare-fitness",
                .lifestyle: "public.app-category.lifestyle",
                .music: "public.app-category.music",
                .productivity: "public.app-category.productivity",
                .utilities: "public.app-category.utilities",
            ]
        )
    }
}
