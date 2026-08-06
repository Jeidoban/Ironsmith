import SwiftUI

struct ToolLibraryCreatorProfileSheetView: View {
    @Binding var displayName: String
    @Binding var handle: String
    let isSaving: Bool
    let isClaimingHandle: Bool
    let onCancel: () -> Void
    let onSave: () -> Void
    @State private var isConfirmingHandleClaim = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Complete Your Creator Profile")
                .font(.headline)
            Text("Your display name and unique handle appear with apps you publish.")
                .foregroundStyle(.secondary)

            field("Display Name") {
                TextField("Your public creator name", text: $displayName)
            }
            field("Handle") {
                HStack(spacing: 2) {
                    Text("@")
                        .foregroundStyle(.secondary)
                    TextField("your_handle", text: $handle)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator)
                }
            }
            Text("Handles are permanent and use 3–30 letters, numbers, or underscores.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button(isSaving ? "Saving…" : "Continue") {
                    if isClaimingHandle {
                        isConfirmingHandleClaim = true
                    } else {
                        onSave()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave || isSaving)
            }
        }
        .padding(18)
        .frame(width: 390)
        .alert("Set Creator Handle?", isPresented: $isConfirmingHandleClaim) {
            Button("Cancel", role: .cancel) {}
            Button("Set Handle", action: onSave)
        } message: {
            Text(
                "@\(IronsmithCreatorHandle.normalized(handle)) cannot be changed after it is claimed."
            )
        }
    }

    static func isValidHandle(_ handle: String) -> Bool {
        IronsmithCreatorHandle.isValid(handle)
    }

    private var canSave: Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHandle = IronsmithCreatorHandle.normalized(handle)
        return (1...80).contains(name.count) && Self.isValidHandle(normalizedHandle)
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
}
