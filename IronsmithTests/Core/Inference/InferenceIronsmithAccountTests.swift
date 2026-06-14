import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension InferenceTests {
    @MainActor
    @Test
    func ironsmithProviderUsesPlatformCreditsWithoutAPIKey() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                remoteModelIDs: ["openai.gpt-5"]
            )
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        let choice = try #require(inferenceStore.availableProviderChoices.first { $0.kind == .ironsmith })
        let didAdd = await inferenceStore.addProvider(choice: choice, apiKey: "")
        let provider = try #require(inferenceStore.providers.first { $0.kind == .ironsmith })

        #expect(didAdd)
        #expect(provider.authMode == .platformCredits)
        #expect(provider.apiKeyReference == nil)
        #expect(inferenceStore.remoteModels.map(\.identifier) == ["openai.gpt-5"])
    }

    @MainActor
    @Test
    func appleOAuthRedirectUsesRegisteredAppScheme() {
        #expect(IronsmithOAuthRedirect.appCallbackScheme == "com.jeidoban.ironsmith")
        #expect(IronsmithOAuthRedirect.appRedirectURL.absoluteString == "com.jeidoban.ironsmith://auth/callback")
    }

    @MainActor
    @Test
    func appleOAuthSignInAddsIronsmithProviderAndLaunchesOAuthFlow() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let signInBox = AppleOAuthSignInBox()
        let callbackURL = URL(string: "com.jeidoban.ironsmith://auth/callback?code=test")!
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                remoteModelIDs: ["anthropic.claude-test"],
                accountClient: Self.accountClient(
                    signInBox: signInBox
                )
            )
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        let didSignIn = await inferenceStore.signInToIronsmithWithAppleOAuth { _ in
            callbackURL
        }

        #expect(didSignIn)
        #expect(signInBox.authorizationURL?.absoluteString == "https://auth.ironsmith.test/authorize")
        #expect(signInBox.callbackURL == callbackURL)
        #expect(inferenceStore.providers.contains { $0.kind == .ironsmith })
        #expect(inferenceStore.ironsmithAccountSummary?.credits.balanceCredits == 42)
        #expect(inferenceStore.remoteModels.map(\.identifier) == ["anthropic.claude-test"])
    }

    @MainActor
    @Test
    func appleOAuthOnboardingCanSelectDeepSeekFlashAfterSignIn() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let callbackURL = URL(string: "com.jeidoban.ironsmith://auth/callback?code=test")!
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                remoteModelIDs: [
                    "openai/gpt-5",
                    InferenceStore.onboardingPreferredIronsmithModelIdentifier,
                ],
                accountClient: Self.accountClient()
            ),
            modelSelection: Self.modelSelection()
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        let didSignIn = await inferenceStore.signInToIronsmithWithAppleOAuth { _ in
            callbackURL
        }
        let didSelectDeepSeek = inferenceStore.selectIronsmithModel(
            identifier: InferenceStore.onboardingPreferredIronsmithModelIdentifier
        )

        #expect(didSignIn)
        #expect(didSelectDeepSeek)
        #expect(inferenceStore.selectedModel?.identifier == InferenceStore.onboardingPreferredIronsmithModelIdentifier)
        #expect(inferenceStore.modelSelection.selectedModelID == inferenceStore.selectedModelID)
    }

    @MainActor
    @Test
    func appleOAuthCancellationDoesNotPresentError() async {
        let signInBox = AppleOAuthSignInBox()
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                accountClient: Self.accountClient(signInBox: signInBox)
            )
        )

        let didSignIn = await inferenceStore.signInToIronsmithWithAppleOAuth { _ in
            throw CancellationError()
        }

        #expect(!didSignIn)
        #expect(signInBox.authorizationURL?.absoluteString == "https://auth.ironsmith.test/authorize")
        #expect(signInBox.callbackURL == nil)
        #expect(inferenceStore.presentedErrorMessage == nil)
    }

    @MainActor
    @Test
    func appleOAuthFailurePresentsError() async {
        let error = NSError(
            domain: "IronsmithTests.OAuth",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "OAuth exchange failed."]
        )
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                accountClient: Self.accountClient(signInError: error)
            )
        )

        let didSignIn = await inferenceStore.signInToIronsmithWithAppleOAuth { _ in
            URL(string: "com.jeidoban.ironsmith://auth/callback?code=test")!
        }

        #expect(!didSignIn)
        #expect(inferenceStore.presentedErrorMessage == "OAuth exchange failed.")
    }

    @MainActor
    @Test
    func signOutRemovesIronsmithProvider() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let signOutBox = SignOutBox()
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                accountClient: Self.accountClient(signOutBox: signOutBox)
            )
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        context.insert(provider)
        try context.save()
        try inferenceStore.refreshData()

        let didSignOut = await inferenceStore.signOutIronsmithProvider(provider)

        #expect(didSignOut)
        #expect(signOutBox.didSignOut)
        #expect(!(inferenceStore.providers.contains { $0.kind == .ironsmith }))
        #expect(inferenceStore.ironsmithSession == nil)
    }

    @MainActor
    @Test
    func deleteIronsmithAccountRemovesProviderWithRemainingCredits() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let signOutBox = SignOutBox()
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                accountClient: Self.accountClient(signOutBox: signOutBox, balanceCredits: 7)
            )
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        let provider = ProviderCatalog.makeProvider(for: .ironsmith)!
        context.insert(provider)
        try context.save()
        try inferenceStore.refreshData()

        let didDelete = await inferenceStore.deleteIronsmithAccount(provider: provider)

        #expect(didDelete)
        #expect(signOutBox.didSignOut)
        #expect(!(inferenceStore.providers.contains { $0.kind == .ironsmith }))
        #expect(inferenceStore.ironsmithSession == nil)
    }

    @MainActor
    @Test
    func refreshIronsmithAccountSuppressesCancelledErrors() async throws {
        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                accountClient: Self.accountClient(
                    fetchError: NSError(
                        domain: NSURLErrorDomain,
                        code: NSURLErrorCancelled,
                        userInfo: [NSLocalizedDescriptionKey: "cancelled"]
                    )
                )
            )
        )

        await inferenceStore.loadIfNeeded(modelContext: context)
        await inferenceStore.refreshIronsmithAccountSummary()

        #expect(inferenceStore.presentedErrorMessage == nil)
        #expect(!(inferenceStore.isRefreshingIronsmithAccount))
    }

    @MainActor
    @Test
    func refreshIronsmithCreditPacksLoadsBackendPacks() async {
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                accountClient: Self.accountClient()
            )
        )

        await inferenceStore.refreshIronsmithCreditPacks()

        #expect(inferenceStore.ironsmithCreditPacks == [
            IronsmithCreditPack(
                id: "tier_1",
                credits: 500,
                amountCents: 500,
                currency: "usd"
            )
        ])
        #expect(!(inferenceStore.isRefreshingIronsmithCreditPacks))
    }

    @MainActor
    @Test
    func createIronsmithCheckoutSessionReturnsCheckoutURL() async throws {
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                accountClient: Self.accountClient()
            )
        )

        let url = await inferenceStore.createIronsmithCheckoutSession(creditPackID: "tier_1")

        #expect(url?.absoluteString == "https://checkout.stripe.com/c/pay/tier_1")
        #expect(inferenceStore.pendingIronsmithAccountRefreshAfterCheckout)
        #expect(!(inferenceStore.isCreatingIronsmithCheckoutSession))
    }

    @MainActor
    @Test
    func checkoutReturnRefreshesIronsmithAccountOnce() async throws {
        let inferenceStore = InferenceStore(
            dependencies: Self.dependencies(
                accountClient: Self.accountClient(balanceCredits: 250)
            )
        )

        _ = await inferenceStore.createIronsmithCheckoutSession(creditPackID: "tier_1")
        await inferenceStore.refreshIronsmithAccountSummaryIfNeededAfterCheckout()

        #expect(!inferenceStore.pendingIronsmithAccountRefreshAfterCheckout)
        #expect(inferenceStore.ironsmithAccountSummary?.credits.balanceCredits == 250)

        inferenceStore.ironsmithAccountSummary = nil
        await inferenceStore.refreshIronsmithAccountSummaryIfNeededAfterCheckout()

        #expect(inferenceStore.ironsmithAccountSummary == nil)
    }

    @Test
    func creditPackFormatsPriceAndCreditsForDisplay() {
        let pack = IronsmithCreditPack(
            id: "tier_1",
            credits: 500,
            amountCents: 500,
            currency: "usd"
        )

        #expect(pack.priceText == "$5" || pack.priceText == "US$5")
        #expect(pack.creditsText == "500 credits")
    }
}
