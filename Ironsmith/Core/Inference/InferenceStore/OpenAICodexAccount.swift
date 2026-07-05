import Foundation

extension InferenceStore {
    var hasOpenAICodexCredential: Bool {
        openAICodexCredential != nil
    }

    func refreshOpenAICodexCredential() {
        do {
            openAICodexCredential = try dependencies.openAICodexAuthClient.credential()
        } catch {
            openAICodexCredential = nil
            presentError(error)
        }
    }

    func signInToOpenAIChatGPT(
        launchFlow: @escaping OpenAICodexOAuthLaunchFlow
    ) async -> Bool {
        do {
            openAICodexCredential = try await dependencies.openAICodexAuthClient.signIn(launchFlow)
            if let provider = providers.first(where: { $0.kind == .openAI }) {
                await refreshDiscoveredModels(for: provider)
                reconcileSelectedModel()
            }
            return true
        } catch {
            guard !IronsmithErrorPresentation.isCancellation(error) else {
                return false
            }
            presentError(error)
            return false
        }
    }

    func signOutOpenAIChatGPT(provider: ProviderConfig? = nil) -> Bool {
        do {
            try dependencies.openAICodexAuthClient.signOut()
            openAICodexCredential = nil
            if let provider {
                remoteModels.removeAll {
                    $0.providerIdentifier == provider.identifier && $0.isOpenAICodexModel
                }
                reconcileSelectedModel()
            }
            return true
        } catch {
            presentError(error)
            return false
        }
    }
}

