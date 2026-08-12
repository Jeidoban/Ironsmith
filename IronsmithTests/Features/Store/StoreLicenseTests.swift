import Foundation
import Testing

@testable import Ironsmith

@Suite("Store license documents")
struct StoreLicenseTests {
    private let templates = StoreLicenseTemplates(
        mit: "MIT TERMS",
        apache2: "APACHE TERMS"
    )

    @Test
    func identifierUsesStringWireFormatAndPreservesUnknownValues() throws {
        let encoded = try JSONEncoder().encode(StoreLicenseIdentifier.apache2)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"Apache-2.0\"")
        let unknown = try JSONDecoder().decode(
            StoreLicenseIdentifier.self,
            from: Data("\"Future-License\"".utf8)
        )
        #expect(unknown.rawValue == "Future-License")
        #expect(!unknown.isSupportedForPublication)
    }

    @Test
    func mitUsesCreatorHandleAndPreservesInheritedApacheTerms() {
        let documents = StoreLegalDocumentRenderer.render(
            appName: "Remixed Notes",
            currentVersionId: "current",
            primaryLicense: .mit,
            attributions: [
                StoreLegalAttribution(
                    versionId: "parent",
                    appName: "Original Notes",
                    creatorHandle: "original_author",
                    creatorDisplayName: "Original Author",
                    publicationYear: 2025,
                    license: .apache2
                ),
                StoreLegalAttribution(
                    versionId: "current",
                    appName: "Remixed Notes",
                    creatorHandle: "remixer",
                    creatorDisplayName: "Remixer",
                    publicationYear: 2026,
                    license: .mit
                ),
            ],
            templates: templates
        )

        #expect(documents.license.contains("Copyright (c) 2026 @remixer"))
        #expect(documents.license.contains("MIT TERMS"))
        #expect(documents.notice.contains("Copyright 2025 @original_author"))
        #expect(documents.attributions.contains("License: Apache-2.0"))
        #expect(documents.attributions.contains("APACHE TERMS"))
    }

    @Test
    func legacyCreatorFallsBackToDisplayName() {
        let documents = StoreLegalDocumentRenderer.render(
            appName: "Legacy Tool",
            currentVersionId: "legacy",
            primaryLicense: .apache2,
            attributions: [
                StoreLegalAttribution(
                    versionId: "legacy",
                    appName: "Legacy Tool",
                    creatorHandle: nil,
                    creatorDisplayName: "Legacy Creator",
                    publicationYear: 2024,
                    license: .apache2
                )
            ],
            templates: templates
        )

        #expect(documents.license == "APACHE TERMS\n")
        #expect(documents.notice.contains("Copyright 2024 Legacy Creator"))
        #expect(documents.attributions == "No inherited Store attributions.\n")
    }

    @Test
    func writerCreatesUniformLegalDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = ToolPackageLayout(packageRootURL: root, executableName: "Tool")
        let documents = StoreLegalDocuments(
            license: "license",
            notice: "notice",
            attributions: "attributions"
        )

        try StoreLegalPackageWriter.write(documents, to: layout)
        try StoreLegalPackageWriter.write(
            StoreLegalDocuments(
                license: "updated license",
                notice: "updated notice",
                attributions: "updated attributions"
            ),
            to: layout
        )

        #expect(try String(contentsOf: layout.legalDirectoryURL.appendingPathComponent("LICENSE.txt"), encoding: .utf8) == "updated license")
        #expect(try String(contentsOf: layout.legalDirectoryURL.appendingPathComponent("NOTICE.txt"), encoding: .utf8) == "updated notice")
        #expect(try String(contentsOf: layout.legalDirectoryURL.appendingPathComponent("ATTRIBUTIONS.txt"), encoding: .utf8) == "updated attributions")
    }
}
