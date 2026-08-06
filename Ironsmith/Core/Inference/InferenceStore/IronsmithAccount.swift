import Foundation

extension InferenceStore {
    func refreshIronsmithSession() {
        ironsmithSession = dependencies.accountClient.currentSession()
        reconcileImageGenerationProvider()
    }

    func refreshIronsmithAccountSummary() async {
        refreshIronsmithSession()
        guard ironsmithSession != nil else {
            ironsmithAccountSummary = nil
            return
        }
        guard !isRefreshingIronsmithAccount else { return }

        isRefreshingIronsmithAccount = true
        defer { isRefreshingIronsmithAccount = false }

        do {
            ironsmithAccountSummary = try await dependencies.accountClient.fetchAccountSummary()
        } catch {
            presentError(error)
        }
    }

    func updateIronsmithAccountProfile(_ update: IronsmithAccountProfileUpdate) async throws -> IronsmithAccountProfile {
        refreshIronsmithSession()
        guard ironsmithSession != nil else {
            throw IronsmithAccountClientError.missingSession
        }
        let profile = try await dependencies.accountClient.updateProfile(update)
        await refreshIronsmithAccountSummary()
        return profile
    }

    func checkIronsmithHandleAvailability(_ handle: String) async throws -> IronsmithHandleAvailability {
        refreshIronsmithSession()
        guard ironsmithSession != nil else {
            throw IronsmithAccountClientError.missingSession
        }
        return try await dependencies.accountClient.checkHandleAvailability(handle)
    }

    func refreshIronsmithCreditPacks() async {
        refreshIronsmithSession()
        guard ironsmithSession != nil else {
            ironsmithCreditPacks = []
            return
        }

        isRefreshingIronsmithCreditPacks = true
        defer { isRefreshingIronsmithCreditPacks = false }

        do {
            ironsmithCreditPacks = try await dependencies.accountClient.fetchCreditPacks()
        } catch {
            presentError(error)
        }
    }

    func createIronsmithCheckoutSession(creditPackID: String) async -> URL? {
        isCreatingIronsmithCheckoutSession = true
        defer { isCreatingIronsmithCheckoutSession = false }

        do {
            let session = try await dependencies.accountClient.createCheckoutSession(creditPackID)
            pendingIronsmithAccountRefreshAfterCheckout = true
            return session.url
        } catch {
            presentError(error)
            return nil
        }
    }

    func refreshIronsmithAccountSummaryIfNeededAfterCheckout() async {
        guard pendingIronsmithAccountRefreshAfterCheckout else { return }
        pendingIronsmithAccountRefreshAfterCheckout = false
        await refreshIronsmithAccountSummary()
    }

    func signInToIronsmithWithAppleOAuth(
        launchFlow: @escaping IronsmithOAuthLaunchFlow
    ) async -> Bool {
        do {
            ironsmithSession = try await dependencies.accountClient.signInWithAppleOAuth(launchFlow)
            reconcileImageGenerationProvider()
            let didEnsureProvider = await ensureIronsmithProviderExists()
            await refreshIronsmithAccountSummary()
            return didEnsureProvider
        } catch {
            guard !IronsmithErrorPresentation.isCancellation(error) else {
                return false
            }
            presentError(error)
            return false
        }
    }

    func signOutIronsmithProvider(_ provider: ProviderConfig) async -> Bool {
        await signOutIronsmithAccount(provider: provider)
    }

    func signOutIronsmithAccount() async -> Bool {
        await signOutIronsmithAccount(
            provider: providers.first(where: { $0.kind == .ironsmith })
        )
    }

    private func signOutIronsmithAccount(provider: ProviderConfig?) async -> Bool {
        do {
            try await dependencies.accountClient.signOut()
            ironsmithSession = nil
            reconcileImageGenerationProvider()
            ironsmithAccountSummary = nil
            ironsmithCreditPacks = []
            pendingIronsmithAccountRefreshAfterCheckout = false
            if let provider {
                await removeProvider(provider)
            }
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    func deleteIronsmithAccount(provider: ProviderConfig) async -> Bool {
        await deleteIronsmithAccount(provider: Optional(provider))
    }

    func deleteIronsmithAccount() async -> Bool {
        await deleteIronsmithAccount(
            provider: providers.first(where: { $0.kind == .ironsmith })
        )
    }

    private func deleteIronsmithAccount(provider: ProviderConfig?) async -> Bool {
        do {
            try await dependencies.accountClient.deleteAccount()
            try? await dependencies.accountClient.signOut()
            ironsmithSession = nil
            reconcileImageGenerationProvider()
            ironsmithAccountSummary = nil
            ironsmithCreditPacks = []
            pendingIronsmithAccountRefreshAfterCheckout = false
            if let provider {
                await removeProvider(provider)
            }
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    private func ensureIronsmithProviderExists() async -> Bool {
        if let provider = providers.first(where: { $0.kind == .ironsmith }) {
            return await refreshDiscoveredModels(for: provider)
        }

        guard let descriptor = ProviderCatalog.descriptor(for: .ironsmith) else {
            presentedErrorMessage = ProviderCreationError.unsupportedProvider.localizedDescription
            return false
        }

        return await addProvider(
            choice: ProviderChoice(descriptor: descriptor),
            apiKey: "",
            displayName: "",
            baseURLString: ""
        )
    }
}
