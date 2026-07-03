import SwiftUI
import UniformTypeIdentifiers

struct ToolLibraryStorePublishSheetView: View {
    let tool: Tool
    let isUpdatingPublishedListing: Bool
    @Binding var publishName: String
    @Binding var publishShortDescription: String
    @Binding var publishDescription: String
    @Binding var publishCategory: StoreAppCategory
    @Binding var publishDisplayName: String
    let publishScreenshotName: String?
    let needsDisplayName: Bool
    let isPublishing: Bool
    let onSaveDisplayName: () -> Void
    let onChooseScreenshot: (URL) -> Void
    let onCancel: () -> Void
    let onPublish: () -> Void
    @State private var isChoosingScreenshot = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isUpdatingPublishedListing ? "Update Store Version" : "Publish to App Store")
                .font(.headline)

            if needsDisplayName {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Display Name", text: $publishDisplayName)
                    Button("Save Display Name", action: onSaveDisplayName)
                        .disabled(
                            publishDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty)
                }
            }

            if !isUpdatingPublishedListing {
                TextField("Name", text: $publishName)
                TextField("Short Description", text: $publishShortDescription)
                    .onChange(of: publishShortDescription) { _, value in
                        if value.count > 40 {
                            publishShortDescription = String(value.prefix(40))
                        }
                    }
                TextField("Description", text: $publishDescription, axis: .vertical)
                    .lineLimit(3...5)
                Picker("Category", selection: $publishCategory) {
                    ForEach(StoreAppCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
            }

            HStack {
                Button {
                    isChoosingScreenshot = true
                } label: {
                    Label("Screenshot", systemImage: "photo")
                }
                Text(publishScreenshotName ?? "No screenshot selected")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
        .frame(width: 340)
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

    private var canPublish: Bool {
        (isUpdatingPublishedListing || listingFieldsAreValid)
            && (!needsDisplayName
                || !publishDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var listingFieldsAreValid: Bool {
        !publishName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publishShortDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publishDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
