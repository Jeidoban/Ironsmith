import AcknowList
import SwiftUI

enum IronsmithLicenseAcknowledgements {
    static func appAcknowledgement(
        metadata: IronsmithAboutMetadata = .current(),
        document: IronsmithLegalDocument = .gplv3
    ) -> Acknow {
        Acknow(
            title: metadata.applicationName,
            text: document.text(),
            license: "GNU GPLv3",
            repository: metadata.sourceCodeURL
        )
    }

    static func all(
        metadata: IronsmithAboutMetadata = .current(),
        document: IronsmithLegalDocument = .gplv3,
        codexLicenseText: String = IronsmithLegalDocument.codexApache2.text(),
        codexNoticeText: String = IronsmithLegalDocument.codexNotice.text()
    ) -> [Acknow] {
        [
            appAcknowledgement(metadata: metadata, document: document),
            codexAcknowledgement(
                licenseText: codexLicenseText,
                noticeText: codexNoticeText
            ),
        ]
            + (AcknowParser.defaultAcknowList()?.acknowledgements ?? [])
    }

    static func codexAcknowledgement(
        licenseText: String = IronsmithLegalDocument.codexApache2.text(),
        noticeText: String = IronsmithLegalDocument.codexNotice.text()
    ) -> Acknow {
        Acknow(
            title: "OpenAI Codex",
            text: "\(licenseText)\n\nNOTICE\n\n\(noticeText)",
            license: "Apache 2.0",
            repository: URL(string: "https://github.com/openai/codex")!
        )
    }
}

struct IronsmithLicensesSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AcknowListSwiftUIView(acknowledgements: IronsmithLicenseAcknowledgements.all())
                .navigationTitle("Licenses")
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .background(.bar)
        }
        .frame(minWidth: 520, minHeight: 460)
    }
}
