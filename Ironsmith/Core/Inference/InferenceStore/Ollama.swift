import Foundation

extension InferenceStore {
    func isStartingOllama(_ provider: ProviderConfig) -> Bool {
        startingOllamaProviderIDs.contains(provider.identifier)
    }

    func canStartOllama(for provider: ProviderConfig) -> Bool {
        provider.kind == .ollama && provider.hasLoopbackServerBaseURL
    }

    func refreshOllamaInstallationStatus() {
        guard ollamaInstallationStatus != .checking else {
            return
        }

        ollamaInstallationStatus = .checking
        Task { @MainActor in
            let installed = await dependencies.ollamaClient.isInstalled()
            ollamaInstallationStatus = installed ? .installed : .notInstalled
        }
    }

    func startOllama(for provider: ProviderConfig) {
        guard provider.kind == .ollama,
            !startingOllamaProviderIDs.contains(provider.identifier)
        else {
            return
        }

        startingOllamaProviderIDs.insert(provider.identifier)
        Task { @MainActor in
            defer { startingOllamaProviderIDs.remove(provider.identifier) }

            do {
                try await dependencies.ollamaClient.startServer()
                let didConnect = await waitForProviderConnection(provider)
                if didConnect {
                    reconcileSelectedModel()
                } else {
                    providerConnectionIssues[provider.identifier] = ProviderConnectionIssue(
                        message: "Ollama started, but Ironsmith could not connect yet."
                    )
                }
            } catch {
                providerConnectionIssues[provider.identifier] = ProviderConnectionIssue(
                    message: "Could not start Ollama. Open it manually and try again."
                )
            }
        }
    }

    func ollamaModelTransferKey(provider: ProviderConfig, modelIdentifier: String) -> String {
        "\(provider.identifier)::\(modelIdentifier)"
    }

    func pullOllamaRecommendedModel(_ entry: OllamaModelCatalog.Entry, provider: ProviderConfig) {
        guard provider.kind == .ollama else { return }
        let key = ollamaModelTransferKey(provider: provider, modelIdentifier: entry.identifier)
        guard ollamaPullStates[key] == nil else { return }

        let baseURLString = provider.baseURLString
        let apiKey = apiKey(for: provider)
        ollamaPullStates[key] = OllamaModelTransferState(status: "Starting", progress: nil)

        Task { @MainActor in
            do {
                guard await ensureOllamaCanPull(provider, transferKey: key) else {
                    ollamaPullStates.removeValue(forKey: key)
                    return
                }

                let store = self
                try await dependencies.ollamaClient.pullModel(
                    entry.identifier,
                    baseURLString,
                    apiKey
                ) { progress in
                    await MainActor.run {
                        guard let currentState = store.ollamaPullStates[key] else { return }
                        let previousProgress = currentState.progress
                        store.ollamaPullStates[key] = OllamaModelTransferState(
                            status: progress.status,
                            progress: progress.fractionCompleted ?? previousProgress
                        )
                    }
                }
                ollamaPullStates.removeValue(forKey: key)
                await refreshDiscoveredModels(for: provider)
                reconcileSelectedModel()
            } catch {
                ollamaPullStates.removeValue(forKey: key)
                presentError(error)
            }
        }
    }

    func deleteOllamaRecommendedModel(_ entry: OllamaModelCatalog.Entry, provider: ProviderConfig) {
        guard provider.kind == .ollama,
            OllamaModelCatalog.all.contains(where: { $0.identifier == entry.identifier })
        else {
            return
        }

        let key = ollamaModelTransferKey(provider: provider, modelIdentifier: entry.identifier)
        guard !ollamaDeletingModelKeys.contains(key) else { return }

        let baseURLString = provider.baseURLString
        let apiKey = apiKey(for: provider)
        ollamaDeletingModelKeys.insert(key)

        Task { @MainActor in
            do {
                try await dependencies.ollamaClient.deleteModel(
                    entry.identifier, baseURLString, apiKey)
                ollamaDeletingModelKeys.remove(key)
                await refreshDiscoveredModels(for: provider)
                reconcileSelectedModel()
            } catch {
                ollamaDeletingModelKeys.remove(key)
                presentError(error)
            }
        }
    }

    private func ensureOllamaCanPull(
        _ provider: ProviderConfig,
        transferKey: String
    ) async -> Bool {
        guard canStartOllama(for: provider) else {
            return true
        }

        guard !(await refreshDiscoveredModels(for: provider)) else {
            return true
        }

        guard providerConnectionIssues[provider.identifier]?.message == "Could not connect to Ollama." else {
            return false
        }

        ollamaPullStates[transferKey] = OllamaModelTransferState(
            status: "Starting Ollama",
            progress: nil
        )

        if !startingOllamaProviderIDs.contains(provider.identifier) {
            startingOllamaProviderIDs.insert(provider.identifier)
            defer { startingOllamaProviderIDs.remove(provider.identifier) }

            do {
                try await dependencies.ollamaClient.startServer()
            } catch {
                providerConnectionIssues[provider.identifier] = ProviderConnectionIssue(
                    message: "Could not start Ollama. Open it manually and try again."
                )
                return false
            }
        }

        let didConnect = await waitForProviderConnection(provider)
        if didConnect {
            reconcileSelectedModel()
            return true
        }

        providerConnectionIssues[provider.identifier] = ProviderConnectionIssue(
            message: "Ollama started, but Ironsmith could not connect yet."
        )
        return false
    }

    private func waitForProviderConnection(
        _ provider: ProviderConfig,
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        retryIntervalNanoseconds: UInt64 = 500_000_000
    ) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds

        repeat {
            if await refreshDiscoveredModels(for: provider) {
                return true
            }
            try? await Task.sleep(nanoseconds: retryIntervalNanoseconds)
        } while DispatchTime.now().uptimeNanoseconds < deadline

        return false
    }
}
