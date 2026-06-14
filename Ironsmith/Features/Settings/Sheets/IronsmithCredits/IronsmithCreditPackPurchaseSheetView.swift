import SwiftUI

struct IronsmithCreditPackPurchaseSheetView: View {
    @Environment(InferenceStore.self) private var inferenceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var checkoutCreditPackID: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if inferenceStore.isRefreshingIronsmithCreditPacks,
                       inferenceStore.ironsmithCreditPacks.isEmpty {
                        ProgressView()
                            .accessibilityLabel("Loading credit packs")
                    } else if inferenceStore.ironsmithCreditPacks.isEmpty {
                        Text("No credit packs are available right now.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(inferenceStore.ironsmithCreditPacks) { creditPack in
                            Button {
                                startCheckout(for: creditPack)
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(creditPack.priceText)
                                            .font(.headline)
                                        Text(creditPack.creditsText)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    if checkoutCreditPackID == creditPack.id {
                                        ProgressView()
                                            .controlSize(.small)
                                            .accessibilityLabel("Opening checkout")
                                    } else {
                                        Image(systemName: "arrow.up.forward.app")
                                            .foregroundStyle(.secondary)
                                            .accessibilityHidden(true)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(checkoutCreditPackID != nil)
                        }
                    }
                } header: {
                    Text("Buy Credits")
                }
            }
            .formStyle(.grouped)
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .disabled(checkoutCreditPackID != nil)
            }
            .padding(20)
            .background(.bar)
        }
        .frame(minWidth: 420, minHeight: 300)
        .task {
            await inferenceStore.refreshIronsmithCreditPacks()
        }
    }

    private func startCheckout(for creditPack: IronsmithCreditPack) {
        guard checkoutCreditPackID == nil else { return }

        checkoutCreditPackID = creditPack.id
        Task {
            defer {
                checkoutCreditPackID = nil
            }

            if let checkoutURL = await inferenceStore.createIronsmithCheckoutSession(
                creditPackID: creditPack.id
            ) {
                openURL(checkoutURL)
                dismiss()
            }
        }
    }
}
