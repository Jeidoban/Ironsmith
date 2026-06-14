enum SettingsProviderModelEmptyState {
    static func message(
        for provider: ProviderConfig,
        isAppleSiliconMac: Bool = IronsmithRuntimeEnvironment.isAppleSiliconMac
    ) -> String {
        if provider.kind == .local && isAppleSiliconMac {
            return "No AI models available. Enable Apple Intelligence in macOS settings to use the built in model."
        }

        return "No AI models available."
    }
}
