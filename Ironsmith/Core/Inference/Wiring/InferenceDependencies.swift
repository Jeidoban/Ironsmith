import Foundation

struct InferenceDependencies {
    var credentialClient: CredentialClient
    var accountClient: IronsmithAccountClient
    var remoteModelClient: RemoteModelClient
    var localModelClient: LocalModelClient
    var ollamaClient: OllamaClient
    var languageModelClient: LanguageModelClient

    init(
        credentialClient: CredentialClient,
        accountClient: IronsmithAccountClient = .unconfigured,
        remoteModelClient: RemoteModelClient,
        localModelClient: LocalModelClient,
        ollamaClient: OllamaClient,
        languageModelClient: LanguageModelClient
    ) {
        self.credentialClient = credentialClient
        self.accountClient = accountClient
        self.remoteModelClient = remoteModelClient
        self.localModelClient = localModelClient
        self.ollamaClient = ollamaClient
        self.languageModelClient = languageModelClient
    }
}

extension InferenceDependencies {
    static var live: Self {
        let credentialClient = CredentialClient.live
        let localModelClient = LocalModelClient.live
        let accountClient = IronsmithAccountClient.live
        return Self(
            credentialClient: credentialClient,
            accountClient: accountClient,
            remoteModelClient: .live(accountClient: accountClient),
            localModelClient: localModelClient,
            ollamaClient: .live,
            languageModelClient: .live(
                credentialClient: credentialClient,
                localModelClient: localModelClient,
                accountClient: accountClient
            )
        )
    }
}
