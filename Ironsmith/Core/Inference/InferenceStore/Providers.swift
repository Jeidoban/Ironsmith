import Foundation

extension InferenceStore {
    var availableProviderChoices: [ProviderChoice] {
        let configuredKinds = Set(providers.map(\.kind))
        let builtInChoices = ProviderCatalog.addableBuiltInDescriptors
            .filter { !configuredKinds.contains($0.kind) }
            .map(ProviderChoice.init(descriptor:))
        let customChoice = ProviderCatalog.descriptor(for: .customOpenAICompatible)
            .map(ProviderChoice.init(descriptor:))

        if let customChoice {
            return builtInChoices + [customChoice]
        }

        return builtInChoices
    }

    func provider(for model: ModelConfig) -> ProviderConfig? {
        providers.first(where: { $0.identifier == model.providerIdentifier })
    }

    func models(for provider: ProviderConfig) -> [ModelConfig] {
        let source = provider.kind == .local ? enabledPersistedModels : remoteModels
        return
            source
            .filter { $0.providerIdentifier == provider.identifier }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func connectionIssue(for provider: ProviderConfig) -> ProviderConnectionIssue? {
        providerConnectionIssues[provider.identifier]
    }

    func addProvider(
        choice: ProviderChoice,
        apiKey: String,
        displayName: String = "",
        baseURLString: String = "",
        openAICompatibleAPIVariant: OpenAICompatibleAPIVariant = .chatCompletions
    ) async -> Bool {
        guard let repository else { return false }

        do {
            let provider = try makeProvider(
                choice: choice,
                apiKey: apiKey,
                displayName: displayName,
                baseURLString: baseURLString,
                openAICompatibleAPIVariant: openAICompatibleAPIVariant
            )
            try await validateProviderCanBeAdded(provider)
            repository.insertProvider(provider)

            let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAPIKey.isEmpty, let reference = provider.apiKeyReference {
                try dependencies.credentialClient.saveAPIKey(trimmedAPIKey, reference)
            }

            try repository.save()
            try refreshData()

            if provider.kind == .ironsmith {
                await refreshDiscoveredModels(for: provider)
                if selectedModelID == nil {
                    selectModel(
                        remoteModels.first(where: { $0.providerIdentifier == provider.identifier })?
                            .selectionIdentifier
                    )
                }
            } else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await refreshDiscoveredModels(for: provider)
                    if selectedModelID == nil {
                        selectModel(
                            remoteModels.first(where: { $0.providerIdentifier == provider.identifier })?
                                .selectionIdentifier
                        )
                    }
                }
            }
            return true
        } catch {
            repository.rollback()
            presentError(error)
            return false
        }
    }

    func saveProviderEdits(
        provider: ProviderConfig,
        apiKey: String,
        displayName: String? = nil,
        baseURLString: String? = nil,
        openAICompatibleAPIVariant: OpenAICompatibleAPIVariant? = nil
    ) async -> Bool {
        guard let repository else { return false }
        let originalDisplayName = provider.displayName
        let originalBaseURLString = provider.baseURLString
        let originalOpenAICompatibleAPIVariant = provider.openAICompatibleAPIVariant

        if provider.kind == .customOpenAICompatible || provider.kind == .ollama {
            do {
                try updateConfigurableProvider(
                    provider,
                    displayName: displayName,
                    baseURLString: baseURLString,
                    openAICompatibleAPIVariant: openAICompatibleAPIVariant
                )
            } catch {
                presentError(error)
                return false
            }
        }

        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if provider.authMode == .apiKey, let reference = provider.apiKeyReference {
            do {
                if trimmedAPIKey.isEmpty {
                    try dependencies.credentialClient.deleteAPIKey(reference)
                } else {
                    try dependencies.credentialClient.saveAPIKey(trimmedAPIKey, reference)
                }
            } catch {
                if provider.kind == .customOpenAICompatible || provider.kind == .ollama {
                    provider.displayName = originalDisplayName
                    provider.baseURLString = originalBaseURLString
                    provider.openAICompatibleAPIVariant = originalOpenAICompatibleAPIVariant
                }
                presentError(error)
                return false
            }
        }

        do {
            try repository.save()
            try refreshData(reconcileSelection: false)
            reconcileSelectedCodingAgentPreference()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await refreshDiscoveredModels(for: provider)
                reconcileSelectedModel()
            }
            return true
        } catch {
            repository.rollback()
            presentError(error)
            return false
        }
    }

    func removeProvider(_ provider: ProviderConfig) async {
        guard let repository else { return }
        guard provider.isRemovable else { return }

        if provider.kind == .openAI {
            do {
                let codexCredential = try dependencies.openAICodexAuthClient.credential()
                if codexCredential != nil {
                    try await dependencies.openAICodexAuthClient.signOut()
                }
                openAICodexCredential = nil
            } catch {
                presentError(error)
                return
            }
        }

        let identifier = provider.identifier
        if let reference = provider.apiKeyReference {
            do {
                try dependencies.credentialClient.deleteAPIKey(reference)
            } catch {
                presentError(error)
                return
            }
        }

        remoteModels.removeAll { $0.providerIdentifier == identifier }
        providerConnectionIssues.removeValue(forKey: identifier)
        startingOllamaProviderIDs.remove(identifier)
        repository.removeProvider(provider)

        do {
            try repository.save()
            try refreshData()
            reconcileSelectedModel()
        } catch {
            repository.rollback()
            presentError(error)
        }
    }

    func apiKey(for provider: ProviderConfig) -> String {
        guard let reference = provider.apiKeyReference else { return "" }
        return (try? dependencies.credentialClient.loadAPIKey(reference)) ?? ""
    }

    @discardableResult
    func refreshDiscoveredModels(for provider: ProviderConfig) async -> Bool {
        guard provider.kind != .local else { return true }

        do {
            let apiKey = apiKey(for: provider)
            let fetched = try await dependencies.remoteModelClient.discoverModels(provider, apiKey)
            remoteModels.removeAll { $0.providerIdentifier == provider.identifier }
            remoteModels.append(contentsOf: fetched)
            remoteModels.sort {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            reconcileSelectedReasoningEffort()
            providerConnectionIssues.removeValue(forKey: provider.identifier)
            return true
        } catch {
            guard !IronsmithErrorPresentation.isCancellation(error) else {
                return false
            }

            remoteModels.removeAll { $0.providerIdentifier == provider.identifier }
            if provider.kind == .ironsmith {
                providerConnectionIssues[provider.identifier] = ProviderConnectionIssue(
                    message: error.localizedDescription
                )
                return false
            }
            if shouldShowConnectionIssueOnProviderCard(provider, error: error) {
                providerConnectionIssues[provider.identifier] = ProviderConnectionIssue(
                    message: provider.kind == .ollama
                        ? "Could not connect to Ollama."
                        : "Could not connect to the server."
                )
                return false
            }
            presentedErrorMessage =
                "Could not fetch AI models for \(provider.displayName): \(error.localizedDescription)"
            return false
        }
    }

    func refreshServerProvidersForSettings() async {
        let serverProviders = providers.filter {
            $0.kind == .ollama || $0.kind == .customOpenAICompatible || $0.kind == .ironsmith
        }
        guard !serverProviders.isEmpty else { return }

        for provider in serverProviders {
            await refreshDiscoveredModels(for: provider)
        }
        reconcileSelectedModel()
    }

    private func shouldShowConnectionIssueOnProviderCard(_ provider: ProviderConfig, error: Error)
        -> Bool
    {
        guard provider.kind == .ollama || provider.kind == .customOpenAICompatible else {
            return false
        }
        return isServerConnectionFailure(error)
    }

    private func isServerConnectionFailure(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return urlError.isServerConnectionFailure
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return URLError.Code(rawValue: nsError.code).isServerConnectionFailure
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isServerConnectionFailure(underlyingError)
        }

        return false
    }

    private func makeProvider(
        choice: ProviderChoice,
        apiKey: String,
        displayName: String,
        baseURLString: String,
        openAICompatibleAPIVariant: OpenAICompatibleAPIVariant
    ) throws -> ProviderConfig {
        guard let provider = ProviderCatalog.makeProvider(for: choice.kind) else {
            throw ProviderCreationError.unsupportedProvider
        }

        if provider.kind == .customOpenAICompatible {
            provider.identifier = "custom.\(UUID().uuidString.lowercased())"
            try updateConfigurableProvider(
                provider,
                displayName: displayName,
                baseURLString: baseURLString,
                openAICompatibleAPIVariant: openAICompatibleAPIVariant
            )
            return provider
        }

        if provider.kind == .ollama {
            try updateConfigurableProvider(
                provider,
                displayName: nil,
                baseURLString: baseURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? provider.baseURLString
                    : baseURLString,
                openAICompatibleAPIVariant: nil
            )
            return provider
        }

        if provider.authMode == .apiKey,
            apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !(provider.kind == .openAI && hasOpenAICodexCredential)
        {
            throw ProviderCreationError.missingAPIKey
        }

        return provider
    }

    private func validateProviderCanBeAdded(
        _ provider: ProviderConfig
    ) async throws {
        guard provider.kind == .ollama, provider.hasLoopbackServerBaseURL else {
            return
        }

        if !(await dependencies.ollamaClient.isInstalled()) {
            throw ProviderCreationError.ollamaNotInstalled
        }
    }

    private func updateConfigurableProvider(
        _ provider: ProviderConfig,
        displayName: String?,
        baseURLString: String?,
        openAICompatibleAPIVariant: OpenAICompatibleAPIVariant?
    ) throws {
        let proposedDisplayName =
            provider.kind == .customOpenAICompatible
            ? (displayName ?? provider.displayName)
            : provider.displayName
        let trimmedDisplayName =
            proposedDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURLString = (baseURLString ?? provider.baseURLString)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedDisplayName.isEmpty else {
            throw ProviderCreationError.missingDisplayName
        }
        guard let baseURL = try? ProviderBaseURLValidator.validatedURL(from: trimmedBaseURLString)
        else {
            throw ProviderCreationError.invalidBaseURL
        }

        provider.displayName = trimmedDisplayName
        provider.baseURLString = baseURL.absoluteString
        if provider.kind == .customOpenAICompatible, let openAICompatibleAPIVariant {
            provider.openAICompatibleAPIVariant = openAICompatibleAPIVariant
        }
    }
}

extension ProviderConfig {
    var hasLoopbackServerBaseURL: Bool {
        ProviderBaseURLValidator.usesLoopbackHost(baseURLString)
    }
}

private extension URLError {
    var isServerConnectionFailure: Bool {
        code.isServerConnectionFailure
    }
}

private extension URLError.Code {
    var isServerConnectionFailure: Bool {
        switch self {
        case .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .timedOut:
            return true
        default:
            return false
        }
    }
}
