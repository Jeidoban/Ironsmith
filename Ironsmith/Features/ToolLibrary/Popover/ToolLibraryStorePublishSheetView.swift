import SwiftUI
import UniformTypeIdentifiers

struct ToolLibraryStorePublishSheetView: View {
    let tool: Tool
    let isUpdatingPublishedListing: Bool
    @Binding var publishShortDescription: String
    @Binding var publishDescription: String
    @Binding var publishCategory: StoreAppCategory
    let publishScreenshotName: String?
    let isPublishing: Bool
    let onChooseScreenshot: (URL) -> Void
    let onCancel: () -> Void
    let onPublish: () -> Void
    @State private var isChoosingScreenshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                isUpdatingPublishedListing
                    ? "Update \(tool.name) on Ironsmith Store"
                    : "Publish \(tool.name) to Ironsmith Store"
            )
                .font(.headline)

            field("Short Description") {
                TextField(
                    "Summarize your app in a few words",
                    text: $publishShortDescription
                )
                    .onChange(of: publishShortDescription) { _, value in
                        if value.count > 40 {
                            publishShortDescription = String(value.prefix(40))
                        }
                    }
            }
            field("Description") {
                TextField(
                    "Describe what your app does and how people can use it",
                    text: $publishDescription,
                    axis: .vertical
                )
                    .lineLimit(3...5)
            }
            if !isUpdatingPublishedListing {
                field("Category") {
                    Picker("Category", selection: $publishCategory) {
                        ForEach(StoreAppCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .labelsHidden()
                }
            }

            field("Screenshot") {
                HStack {
                    Button("Choose Screenshot…") {
                        isChoosingScreenshot = true
                    }
                    Text(publishScreenshotName ?? "No screenshot selected")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isUpdatingPublishedListing ? "Update" : "Publish", action: onPublish)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPublish || isPublishing)
                if isPublishing {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(18)
        .frame(width: 390)
        .fileImporter(
            isPresented: $isChoosingScreenshot,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onChooseScreenshot(url)
            }
        }
    }

    private func field<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
            content()
        }
    }

    private var canPublish: Bool {
        listingFieldsAreValid
            && !tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var listingFieldsAreValid: Bool {
        !publishShortDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publishDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
