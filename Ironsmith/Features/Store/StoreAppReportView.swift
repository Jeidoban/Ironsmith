import SwiftUI

struct StoreAppReportSheet: View {
    static let maximumDetailsCharacters = 1_000

    let app: StoreAppDetail
    let version: StoreVersionMetadata
    let onSubmit: (StoreAppReportRequest) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var reason = StoreAppReportReason.securityPrivacy
    @State private var details = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Report \(app.name)")
                .font(.title2.weight(.semibold))

            Picker("Reason", selection: $reason) {
                ForEach(StoreAppReportReason.allCases) { reason in
                    Text(reason.title).tag(reason)
                }
            }
            .pickerStyle(.radioGroup)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Details")
                        .font(.headline)
                    Spacer()
                    Text("\(Self.detailsCharacterCount(details))/\(Self.maximumDetailsCharacters)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $details)
                    .font(.body)
                    .frame(minHeight: 100)
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.quaternary)
                    }
                    .onChange(of: details) { _, value in
                        if Self.detailsCharacterCount(value) > Self.maximumDetailsCharacters {
                            details = Self.truncateDetails(value)
                        }
                    }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .disabled(isSubmitting)

                Button("Submit Report") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || validatedDetails == nil)

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
        .interactiveDismissDisabled(isSubmitting)
    }

    static func detailsCharacterCount(_ value: String) -> Int {
        value.unicodeScalars.count
    }

    static func truncateDetails(_ value: String) -> String {
        String(value.unicodeScalars.prefix(maximumDetailsCharacters))
    }

    static func validatedDetails(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var validatedDetails: String? {
        Self.validatedDetails(details)
    }

    private func submit() {
        guard !isSubmitting else { return }
        guard let validatedDetails else { return }
        isSubmitting = true
        Task {
            let didSubmit = await onSubmit(
                StoreAppReportRequest(
                    storeId: app.storeId,
                    appId: app.id,
                    versionId: version.id,
                    reason: reason,
                    details: validatedDetails
                )
            )
            if didSubmit {
                dismiss()
            } else {
                isSubmitting = false
            }
        }
    }
}
