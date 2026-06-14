enum ToolLibraryCreditWarning {
    static let lowCreditsMessage = "Low credits - may stop early"

    static func message(
        model: ModelConfig?,
        provider: ProviderConfig?,
        balanceCredits: Int?
    ) -> String? {
        guard provider?.kind == .ironsmith,
              let estimatedToolCredits = model?.estimatedToolCredits,
              let balanceCredits,
              balanceCredits > 0,
              balanceCredits < estimatedToolCredits
        else {
            return nil
        }

        return lowCreditsMessage
    }
}
