enum IronsmithPreferenceKeys {
    nonisolated static let showSandboxOverride = "showSandboxOverride"
    nonisolated static let hasCompletedWelcomeOnboarding = "welcomeOnboarding.hasCompleted"
    nonisolated static let hasPresentedOllamaModelDownloadNudge = "ollama.hasPresentedModelDownloadNudge"

    #if DEBUG
    nonisolated static let debugAlwaysShowWelcomeOnboarding = "debug.alwaysShowWelcomeOnboarding"
    nonisolated static let debugAlwaysOpenOllamaEditorAfterAdd = "debug.alwaysOpenOllamaEditorAfterAdd"
    #endif
}
