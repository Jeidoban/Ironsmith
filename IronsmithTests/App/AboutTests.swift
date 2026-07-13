import AcknowList
import Foundation
import Testing
@testable import Ironsmith

struct AboutTests {
    @Test
    func aboutMetadataUsesBundleInfo() {
        let metadata = IronsmithAboutMetadata(
            infoDictionary: [
                "CFBundleDisplayName": "Test Ironsmith",
                "CFBundleName": "Fallback Name",
                "CFBundleShortVersionString": "2.3",
                "CFBundleVersion": "45",
                "NSHumanReadableCopyright": "Copyright © 2026 Jade Westover"
            ]
        )

        #expect(metadata.applicationName == "Test Ironsmith")
        #expect(metadata.applicationVersion == "2.3")
        #expect(metadata.versionText == "Version 2.3")
        #expect(metadata.copyright == "Copyright © 2026 Jade Westover")
        #expect(metadata.licenseSummary == "Licensed under GNU GPLv3")
        #expect(metadata.sourceCodeURL.absoluteString == "https://github.com/Jeidoban/Ironsmith")
    }

    @Test
    func aboutMetadataFallsBackGracefully() {
        let metadata = IronsmithAboutMetadata(infoDictionary: [:])

        #expect(metadata.applicationName == "Ironsmith")
        #expect(metadata.applicationVersion == nil)
        #expect(metadata.versionText == nil)
        #expect(metadata.copyright == "Copyright © 2026 Jade Westover")
        #expect(metadata.licenseSummary == "Licensed under GNU GPLv3")
    }

    @Test
    func aboutMetadataFormatsVersionTextWithoutBuild() {
        let metadata = IronsmithAboutMetadata(
            infoDictionary: [
                "CFBundleName": "Ironsmith",
                "CFBundleShortVersionString": "2.3"
            ]
        )

        #expect(metadata.applicationVersion == "2.3")
        #expect(metadata.versionText == "Version 2.3")
    }

    @Test
    func aboutMetadataDoesNotDisplayBuildNumber() {
        let metadata = IronsmithAboutMetadata(
            infoDictionary: [
                "CFBundleName": "Ironsmith",
                "CFBundleVersion": "45"
            ]
        )

        #expect(metadata.applicationVersion == nil)
        #expect(metadata.versionText == nil)
    }

    @Test
    func gplResourceTextExistsInAppResources() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let gplResourceURL = repositoryRootURL
            .appendingPathComponent("Ironsmith/Resources/GPLv3.txt")

        let text = IronsmithLegalDocument.gplv3.text(resourceURL: gplResourceURL)

        #expect(text.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(text.contains("Version 3, 29 June 2007"))
    }

    @Test
    func codexLegalResourcesExistAndProduceAcknowledgement() throws {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let repositoryRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let licensesURL = repositoryRootURL
            .appendingPathComponent("Ironsmith/Resources/ThirdPartyLicenses", isDirectory: true)
        let licenseText = IronsmithLegalDocument.codexApache2.text(
            resourceURL: licensesURL.appendingPathComponent("OpenAI-Codex-Apache-2.0.txt")
        )
        let noticeText = IronsmithLegalDocument.codexNotice.text(
            resourceURL: licensesURL.appendingPathComponent("OpenAI-Codex-NOTICE.txt")
        )
        let acknowledgement = IronsmithLicenseAcknowledgements.codexAcknowledgement(
            licenseText: licenseText,
            noticeText: noticeText
        )

        #expect(licenseText.contains("Apache License"))
        #expect(licenseText.contains("Version 2.0, January 2004"))
        #expect(noticeText.contains("OpenAI Codex"))
        #expect(acknowledgement.title == "OpenAI Codex")
        #expect(acknowledgement.license == "Apache 2.0")
        #expect(acknowledgement.text?.contains("Ratatui") == true)
        #expect(acknowledgement.repository?.absoluteString == "https://github.com/openai/codex")
    }
}
