import SwiftUI

struct ProviderSummaryRowView: View {
    let provider: ProviderConfig
    var logoSize: CGFloat = 32
    var titleFont: Font = .headline
    var subtitleFont: Font = .caption

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderLogoView(kind: provider.kind, size: logoSize)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .font(titleFont)
                    .lineLimit(1)

                Text(provider.settingsDetailText)
                    .font(subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
