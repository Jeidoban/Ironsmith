import AppKit
import Foundation
import SwiftUI

struct IronsmithAboutMetadata: Equatable {
    static let fallbackApplicationName = "Ironsmith"
    static let fallbackCopyright = "Copyright © 2026 Jade Westover"
    static let licenseSummary = "Licensed under GNU GPLv3"
    static let sourceCodeURL = URL(string: "https://github.com/Jeidoban/Ironsmith")!

    var applicationName: String
    var applicationVersion: String?
    var copyright: String
    var licenseSummary: String
    var sourceCodeURL: URL

    init(
        applicationName: String = Self.fallbackApplicationName,
        applicationVersion: String? = nil,
        copyright: String = Self.fallbackCopyright,
        licenseSummary: String = Self.licenseSummary,
        sourceCodeURL: URL = Self.sourceCodeURL
    ) {
        self.applicationName = applicationName
        self.applicationVersion = applicationVersion
        self.copyright = copyright
        self.licenseSummary = licenseSummary
        self.sourceCodeURL = sourceCodeURL
    }

    init(infoDictionary: [String: Any]?) {
        let applicationName =
            Self.nonEmptyString(for: "CFBundleDisplayName", in: infoDictionary)
            ?? Self.nonEmptyString(for: "CFBundleName", in: infoDictionary)
            ?? Self.fallbackApplicationName
        let version = Self.nonEmptyString(for: "CFBundleShortVersionString", in: infoDictionary)
        let copyright =
            Self.nonEmptyString(for: "NSHumanReadableCopyright", in: infoDictionary)
            ?? Self.fallbackCopyright

        self.init(
            applicationName: applicationName,
            applicationVersion: version,
            copyright: copyright
        )
    }

    static func current(bundle: Bundle = .main) -> Self {
        Self(infoDictionary: bundle.infoDictionary)
    }

    var versionText: String? {
        applicationVersion.map { "Version \($0)" }
    }

    private static func nonEmptyString(for key: String, in infoDictionary: [String: Any]?)
        -> String?
    {
        guard let value = infoDictionary?[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

struct IronsmithAboutView: View {
    let metadata: IronsmithAboutMetadata
    @State private var isShowingLicenses = false

    init(
        metadata: IronsmithAboutMetadata = .current()
    ) {
        self.metadata = metadata
    }

    var body: some View {
        VStack(spacing: 14) {
            appIcon

            VStack(spacing: 5) {
                Text(metadata.applicationName)
                    .font(.title.bold())

                if let versionText = metadata.versionText {
                    Text(versionText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text(metadata.licenseSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Licenses") {
                    isShowingLicenses = true
                }

                Button("Source Code") {
                    NSWorkspace.shared.open(metadata.sourceCodeURL)
                }
            }

            Text(metadata.copyright)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .frame(width: 390)
        .sheet(isPresented: $isShowingLicenses) {
            IronsmithLicensesSheet()
        }
    }

    @ViewBuilder
    private var appIcon: some View {
        if let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .accessibilityHidden(true)
        } else {
            Image("ProviderLogoIronsmith")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)
        }
    }
}

#Preview("About") {
    IronsmithAboutView(
        metadata: IronsmithAboutMetadata(
            applicationVersion: "1.0"
        )
    )
}
