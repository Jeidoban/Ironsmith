import SwiftUI

struct ToolLibraryEmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image("ProviderLogoIronsmith")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 50, height: 50)
                .accessibilityHidden(true)

            Text("No apps yet")
                .font(.title3.weight(.semibold))

            Text("Create a new one from the prompt box below, or change the selected AI model in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 288)
    }
}
