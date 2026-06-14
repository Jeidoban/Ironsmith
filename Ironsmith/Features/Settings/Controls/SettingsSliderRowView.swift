import SwiftUI

struct SettingsSliderRowView: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .frame(width: 128, alignment: .leading)

            Slider(value: clampedValue, in: range)
                .frame(minWidth: 180)

            TextField(title, value: clampedValue, format: .number.precision(.fractionLength(fractionDigits)))
                .font(.system(.body, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: 72)
        }
    }

    private var clampedValue: Binding<Double> {
        Binding(
            get: { min(max(value, range.lowerBound), range.upperBound) },
            set: { newValue in
                value = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
    }

    private var fractionDigits: Int {
        if let decimalIndex = format.firstIndex(of: "."),
           let endIndex = format.firstIndex(of: "f") {
            return Int(format[format.index(after: decimalIndex)..<endIndex]) ?? 2
        }
        return 2
    }
}

private struct SettingsSliderRowPreview: View {
    @State private var value = 0.7

    var body: some View {
        SettingsSliderRowView(
            title: "Temperature",
            value: $value,
            range: 0...2,
            format: "%.2f"
        )
        .padding()
        .frame(width: 420)
    }
}

#Preview("Slider Row") {
    SettingsSliderRowPreview()
}
