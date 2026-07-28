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
}
