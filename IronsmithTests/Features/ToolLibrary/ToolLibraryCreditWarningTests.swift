import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension ToolLibraryTests {
    @MainActor
    @Test
    func toolLibraryCreditWarningShowsWhenBalanceIsBelowEstimate() throws {
        let provider = try #require(ProviderCatalog.makeProvider(for: .ironsmith))
        let model = Self.remoteModel(provider: provider, estimatedToolCredits: 200)

        #expect(
            ToolLibraryCreditWarning.message(
                model: model,
                provider: provider,
                balanceCredits: 199
            ) == ToolLibraryCreditWarning.lowCreditsMessage
        )
    }

    @MainActor
    @Test
    func toolLibraryCreditWarningHidesWhenBalanceCanCoverEstimate() throws {
        let provider = try #require(ProviderCatalog.makeProvider(for: .ironsmith))
        let model = Self.remoteModel(provider: provider, estimatedToolCredits: 200)

        #expect(ToolLibraryCreditWarning.message(model: model, provider: provider, balanceCredits: 200) == nil)
        #expect(ToolLibraryCreditWarning.message(model: model, provider: provider, balanceCredits: 201) == nil)
    }

    @MainActor
    @Test
    func toolLibraryCreditWarningHidesForNonIronsmithModels() throws {
        let provider = try #require(ProviderCatalog.makeProvider(for: .openAI))
        let model = Self.remoteModel(provider: provider, estimatedToolCredits: 200)

        #expect(ToolLibraryCreditWarning.message(model: model, provider: provider, balanceCredits: 50) == nil)
    }

    @MainActor
    @Test
    func toolLibraryCreditWarningHidesWhenBalanceIsZeroOrUnavailable() throws {
        let provider = try #require(ProviderCatalog.makeProvider(for: .ironsmith))
        let model = Self.remoteModel(provider: provider, estimatedToolCredits: 200)

        #expect(ToolLibraryCreditWarning.message(model: model, provider: provider, balanceCredits: 0) == nil)
        #expect(ToolLibraryCreditWarning.message(model: model, provider: provider, balanceCredits: nil) == nil)
    }
}
