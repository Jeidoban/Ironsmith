import SwiftUI

struct SettingsStepperRowView: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .frame(width: 128, alignment: .leading)

            Spacer()

            TextField(title, value: clampedValue, format: .number)
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 82)

            Stepper(title, value: clampedValue, in: range, step: step)
                .labelsHidden()
        }
    }

    private var clampedValue: Binding<Int> {
        Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { newValue in
                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
    }
}

private struct SettingsStepperRowPreview: View {
    @State private var value = 8192

    var body: some View {
        SettingsStepperRowView(
            title: "Context",
            value: $value,
            range: 1024...32768,
            step: 512
        )
        .padding()
        .frame(width: 420)
    }
}

#Preview("Stepper Row") {
    SettingsStepperRowPreview()
}
