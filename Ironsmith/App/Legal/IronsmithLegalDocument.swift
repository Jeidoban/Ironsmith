import Foundation

struct IronsmithLegalDocument: Identifiable, Equatable {
    static let gplv3 = Self(
        id: "gplv3",
        title: "GNU GPLv3",
        resourceName: "GPLv3",
        resourceExtension: "txt"
    )

    let id: String
    let title: String
    let resourceName: String
    let resourceExtension: String

    func text(bundle: Bundle = .main) -> String {
        text(resourceURL: bundle.url(forResource: resourceName, withExtension: resourceExtension))
    }

    func text(resourceURL: URL?) -> String {
        guard let resourceURL,
              let text = try? String(contentsOf: resourceURL, encoding: .utf8) else {
            return "\(title) could not be loaded."
        }

        return text
    }
}
