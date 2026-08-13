import Foundation

nonisolated struct StoreLicenseIdentifier: RawRepresentable, Codable, Equatable, Hashable,
    Identifiable, Sendable
{
    static let mit = Self(rawValue: "MIT")
    static let apache2 = Self(rawValue: "Apache-2.0")
    static let supported: [Self] = [.mit, .apache2]

    let rawValue: String
    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mit: "MIT License"
        case .apache2: "Apache License 2.0"
        default: rawValue
        }
    }

    var summary: String {
        switch self {
        case .mit:
            "A short permissive license requiring preservation of the copyright and license notice."
        case .apache2:
            "A permissive license with explicit patent terms and notice-preservation requirements."
        default:
            "This license is not supported by this version of Ironsmith."
        }
    }

    var isSupportedForPublication: Bool {
        Self.supported.contains(self)
    }
}

nonisolated struct StoreLegalAttribution: Codable, Equatable, Sendable {
    let versionId: String
    let appName: String
    let creatorHandle: String?
    let creatorDisplayName: String
    let publicationYear: Int
    let license: StoreLicenseIdentifier

    var holderDisplayName: String {
        guard let creatorHandle, !creatorHandle.isEmpty else {
            return creatorDisplayName
        }
        return "@\(creatorHandle)"
    }
}

nonisolated struct StoreLegalDocuments: Equatable, Sendable {
    let license: String
    let notice: String
    let attributions: String
}

nonisolated struct StoreLicenseTemplates: Equatable, Sendable {
    let mit: String
    let apache2: String

    static func bundled(bundle: Bundle = .main) -> Self {
        Self(
            mit: load(named: "MIT", bundle: bundle),
            apache2: load(named: "Apache-2.0", bundle: bundle)
        )
    }

    private static func load(named name: String, bundle: Bundle) -> String {
        guard let url = bundle.url(
            forResource: name,
            withExtension: "txt",
            subdirectory: "StoreLicenses"
        ), let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return "\(name) license text could not be loaded."
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

nonisolated enum StoreLegalDocumentRenderer {
    static func render(
        appName: String,
        currentVersionId: String,
        primaryLicense: StoreLicenseIdentifier,
        attributions: [StoreLegalAttribution],
        templates: StoreLicenseTemplates = .bundled()
    ) -> StoreLegalDocuments {
        let mitText = templates.mit
        let apacheText = templates.apache2
        let current = attributions.last(where: { $0.versionId == currentVersionId })
        let holder = current?.holderDisplayName ?? "Unknown Creator"
        let year = current?.publicationYear ?? Calendar(identifier: .gregorian).component(
            .year, from: Date())
        let copyright = "Copyright \(year) \(holder)"

        let licenseText: String
        switch primaryLicense {
        case .mit:
            licenseText = "Copyright (c) \(year) \(holder)\n\n\(mitText)"
        case .apache2:
            licenseText = apacheText
        default:
            licenseText = "Unsupported Store license: \(primaryLicense.rawValue)"
        }

        let inherited = attributions.filter { $0.versionId != currentVersionId }
        let inheritedApacheNotices = inherited
            .filter { $0.license == .apache2 }
            .map { "\($0.appName)\nCopyright \($0.publicationYear) \($0.holderDisplayName)" }
        let notice = (["\(appName)\n\(copyright)"] + inheritedApacheNotices)
            .joined(separator: "\n\n")

        let attributionText: String
        if inherited.isEmpty {
            attributionText = "No inherited Store attributions."
        } else {
            attributionText = inherited.map { attribution in
                let heading = "\(attribution.appName) (Store version \(attribution.versionId))"
                let upstreamCopyright =
                    "Copyright \(attribution.publicationYear) \(attribution.holderDisplayName)"
                let terms: String
                switch attribution.license {
                case .mit:
                    terms = mitText
                case .apache2:
                    terms = apacheText
                default:
                    terms = "License text is unavailable for \(attribution.license.rawValue)."
                }
                return """
                    \(heading)
                    License: \(attribution.license.rawValue)
                    \(upstreamCopyright)
                    The source in this version was modified from the work above.

                    \(terms)
                    """
            }.joined(separator: "\n\n---\n\n")
        }

        return StoreLegalDocuments(
            license: licenseText + "\n",
            notice: notice + "\n",
            attributions: attributionText + "\n"
        )
    }

}

nonisolated enum StoreLegalPackageWriter {
    static func write(
        _ documents: StoreLegalDocuments,
        to layout: ToolPackageLayout,
        fileManager: FileManager = .default
    ) throws {
        let directory = layout.legalDirectoryURL
        let identifier = UUID().uuidString.lowercased()
        let stagingDirectory = layout.packageRootURL.appendingPathComponent(
            ".Legal.staging.\(identifier)", isDirectory: true)
        let backupDirectory = layout.packageRootURL.appendingPathComponent(
            ".Legal.backup.\(identifier)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }

        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try write(documents, to: stagingDirectory)

        let hadExistingDirectory = fileManager.fileExists(atPath: directory.path)
        if hadExistingDirectory {
            try fileManager.moveItem(at: directory, to: backupDirectory)
        }
        do {
            try fileManager.moveItem(at: stagingDirectory, to: directory)
        } catch let replacementError {
            if hadExistingDirectory {
                try fileManager.moveItem(at: backupDirectory, to: directory)
            }
            throw replacementError
        }
        try? fileManager.removeItem(at: backupDirectory)
    }

    private static func write(_ documents: StoreLegalDocuments, to directory: URL) throws {
        try documents.license.write(
            to: directory.appendingPathComponent("LICENSE.txt"),
            atomically: true,
            encoding: .utf8
        )
        try documents.notice.write(
            to: directory.appendingPathComponent("NOTICE.txt"),
            atomically: true,
            encoding: .utf8
        )
        try documents.attributions.write(
            to: directory.appendingPathComponent("ATTRIBUTIONS.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
