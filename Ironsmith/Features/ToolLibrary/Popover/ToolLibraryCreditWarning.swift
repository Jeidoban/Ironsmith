import Foundation

enum ToolLibraryCreditEstimate {
    static let lowerBoundMultiplier = 0.3
    static let upperBoundMultiplier = 3.0

    static func creditsRange(
        model: ModelConfig?,
        provider: ProviderConfig?
    ) -> ClosedRange<Int>? {
        guard provider?.kind == .ironsmith,
            let model,
            let estimatedToolCredits = model.estimatedToolCredits
        else {
            return nil
        }

        let lowerBound = Int(ceil(Double(estimatedToolCredits) * lowerBoundMultiplier))
        let upperBound = Int(ceil(Double(estimatedToolCredits) * upperBoundMultiplier))
        return lowerBound...upperBound
    }
}

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
