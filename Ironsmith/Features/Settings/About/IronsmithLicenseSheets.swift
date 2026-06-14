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
        document: IronsmithLegalDocument = .gplv3
    ) -> [Acknow] {
        [appAcknowledgement(metadata: metadata, document: document)]
            + (AcknowParser.defaultAcknowList()?.acknowledgements ?? [])
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
