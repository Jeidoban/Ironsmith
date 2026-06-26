import SwiftUI

struct ToolLibraryEmptyStateView: View {
    let showsNoModelActions: Bool
    let isSigningInToIronsmith: Bool
    let onAddProvider: () -> Void
    let onSignInToIronsmith: () -> Void

    init(
        showsNoModelActions: Bool = false,
        isSigningInToIronsmith: Bool = false,
        onAddProvider: @escaping () -> Void = {},
        onSignInToIronsmith: @escaping () -> Void = {}
    ) {
        self.showsNoModelActions = showsNoModelActions
        self.isSigningInToIronsmith = isSigningInToIronsmith
        self.onAddProvider = onAddProvider
        self.onSignInToIronsmith = onSignInToIronsmith
    }

    var body: some View {
        VStack(spacing: 10) {
            Image("ProviderLogoIronsmith")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(.secondary)
                .frame(width: 50, height: 50)
                .accessibilityHidden(true)

            Text(title)
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if showsNoModelActions {
                VStack(spacing: 8) {
                    Button("Add Provider", action: onAddProvider)
                        .buttonStyle(.bordered)

                    Button(action: onSignInToIronsmith) {
                        HStack(spacing: 6) {
                            if isSigningInToIronsmith {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Signing in")
                            }
                            Text(isSigningInToIronsmith ? "Signing In..." : "Sign in to Ironsmith")
                        }
                        .frame(minWidth: 154)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSigningInToIronsmith)
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 288)
    }

    private var title: String {
        showsNoModelActions ? "No AI models" : "No apps yet"
    }

    private var message: String {
        if showsNoModelActions {
            return
                "No AI models are available. Add a provider in settings or sign into Ironsmith for immediate access."
        }

        return "Create a new one from the prompt box below, or change the selected AI model in Settings."
    }
}
