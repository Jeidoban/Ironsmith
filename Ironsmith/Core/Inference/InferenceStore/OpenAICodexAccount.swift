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

    func signInToOpenAIChatGPT() async -> Bool {
        do {
            openAICodexCredential = try await dependencies.openAICodexAuthClient.signIn()
            reconcileImageGenerationProvider()
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

    func signOutOpenAIChatGPT(provider: ProviderConfig? = nil) async -> Bool {
        do {
            try await dependencies.openAICodexAuthClient.signOut()
            openAICodexCredential = nil
            reconcileImageGenerationProvider()
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
