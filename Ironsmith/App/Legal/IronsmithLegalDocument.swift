import Foundation

struct IronsmithLegalDocument: Identifiable, Equatable {
    static let gplv3 = Self(
        id: "gplv3",
        title: "GNU GPLv3",
        resourceName: "GPLv3",
        resourceExtension: "txt",
        resourceSubdirectory: nil
    )

    static let codexApache2 = Self(
        id: "openai-codex-apache-2",
        title: "OpenAI Codex Apache 2.0 License",
        resourceName: "OpenAI-Codex-Apache-2.0",
        resourceExtension: "txt",
        resourceSubdirectory: "ThirdPartyLicenses"
    )

    static let codexNotice = Self(
        id: "openai-codex-notice",
        title: "OpenAI Codex Notice",
        resourceName: "OpenAI-Codex-NOTICE",
        resourceExtension: "txt",
        resourceSubdirectory: "ThirdPartyLicenses"
    )

    let id: String
    let title: String
    let resourceName: String
    let resourceExtension: String
    let resourceSubdirectory: String?

    func text(bundle: Bundle = .main) -> String {
        text(
            resourceURL: bundle.url(
                forResource: resourceName,
                withExtension: resourceExtension,
                subdirectory: resourceSubdirectory
            )
        )
    }

    func text(resourceURL: URL?) -> String {
        guard let resourceURL,
              let text = try? String(contentsOf: resourceURL, encoding: .utf8) else {
            return "\(title) could not be loaded."
        }

        return text
    }
}
