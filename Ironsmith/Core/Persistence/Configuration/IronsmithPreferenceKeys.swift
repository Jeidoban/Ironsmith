enum IronsmithPreferenceKeys {
    nonisolated static let showSandboxOverride = "showSandboxOverride"
    nonisolated static let hasCompletedWelcomeOnboarding = "welcomeOnboarding.hasCompleted"
    nonisolated static let hasPresentedOllamaModelDownloadNudge = "ollama.hasPresentedModelDownloadNudge"
    nonisolated static let appleFoundationModelEnabled = "appleFoundationModel.enabled"
    nonisolated static let hasPresentedAppleFoundationModelWarning = "appleFoundationModel.hasPresentedWarning"
    nonisolated static let diagnosticsLoggingEnabled = "diagnosticsLoggingEnabled"
    nonisolated static let featureStoreEnabled = "feature.store.enabled"
    nonisolated static let recentHostedIconPaletteIndices = "icon.recentHostedPaletteIndices"

    #if DEBUG
    nonisolated static let debugAlwaysShowWelcomeOnboarding = "debug.alwaysShowWelcomeOnboarding"
    nonisolated static let debugAlwaysOpenOllamaEditorAfterAdd = "debug.alwaysOpenOllamaEditorAfterAdd"
    nonisolated static let debugAlwaysShowAppleFoundationModelWarning = "debug.alwaysShowAppleFoundationModelWarning"
    nonisolated static let debugPopoverEmptyStateMode = "debug.popoverEmptyStateMode"
    #endif
}
