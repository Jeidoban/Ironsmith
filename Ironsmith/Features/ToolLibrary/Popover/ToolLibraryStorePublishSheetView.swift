import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ToolLibraryStorePublishSheetView: View {
    let tool: Tool
    let isUpdatingPublishedListing: Bool
    @Binding var publishShortDescription: String
    @Binding var publishDescription: String
    @Binding var publishCategory: StoreAppCategory
    @Binding var publishLicense: StoreLicenseIdentifier
    let publishScreenshotName: String?
    let publishIconPreviewData: Data?
    let creatorHandle: String
    let inheritedLegalAttributions: [StoreLegalAttribution]
    let publishNameMatchesOriginal: Bool
    let isUsingOriginalRemixIcon: Bool
    let isPublishing: Bool
    let onChooseScreenshot: (URL) -> Void
    let onCancel: () -> Void
    let onEditDetails: () -> Void
    let onPublish: () -> Void
    @State private var isChoosingScreenshot = false
    @State private var isShowingLicense = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                isUpdatingPublishedListing
                    ? "Update \(tool.name) on Ironsmith Store"
                    : "Publish \(tool.name) to Ironsmith Store"
            )
                .font(.headline)

            appIdentitySection

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
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $publishDescription)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(4)

                    if publishDescription.isEmpty {
                        Text("Describe what your app does and how people can use it")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 100, maxHeight: 160)
                .background(.background, in: RoundedRectangle(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.quaternary)
                }
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

            field("License") {
                HStack {
                    Picker("License", selection: $publishLicense) {
                        ForEach(StoreLicenseIdentifier.supported) { license in
                            Text(license.title).tag(license)
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Button("View License…") {
                        isShowingLicense = true
                    }
                }
                if isUpdatingPublishedListing {
                    Text(
                        "This license applies to the new version. Earlier versions keep their existing licenses."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 460)
        .fileImporter(
            isPresented: $isChoosingScreenshot,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onChooseScreenshot(url)
            }
        }
        .sheet(isPresented: $isShowingLicense) {
            StoreLicenseDetailSheet(
                license: publishLicense,
                documents: previewLegalDocuments,
                inheritedAttributions: inheritedLegalAttributions
            )
        }
    }

    private var previewLegalDocuments: StoreLegalDocuments {
        StoreLegalDocumentRenderer.render(
            appName: tool.name,
            currentVersionId: "preview-current-version",
            primaryLicense: publishLicense,
            attributions: inheritedLegalAttributions + [
                StoreLegalAttribution(
                    versionId: "preview-current-version",
                    appName: tool.name,
                    creatorHandle: creatorHandle,
                    creatorDisplayName: creatorHandle,
                    publicationYear: Calendar(identifier: .gregorian).component(
                        .year, from: Date()),
                    license: publishLicense
                )
            ]
        )
    }

    private var appIdentitySection: some View {
        field("App Identity") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    identityIcon(localData: publishIconPreviewData)
                    Text(tool.name)
                        .font(.body.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Edit Details", action: onEditDetails)
                        .disabled(isPublishing)
                }

                if isUsingOriginalRemixIcon {
                    Label(
                        "This app still uses the original icon. Consider using Edit Details to choose a new one.",
                        systemImage: "info.circle"
                    )
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if publishNameMatchesOriginal {
                    Label(
                        "Current app name is the same as the original. Change the app name in Edit Details before publishing.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.red)
                    .font(.callout)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func identityIcon(localData: Data?) -> some View {
        if let localData, let image = NSImage(data: localData) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            StoreIconView(url: nil, size: 48)
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
            && !publishNameMatchesOriginal
    }

    private var listingFieldsAreValid: Bool {
        !publishShortDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !publishDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
