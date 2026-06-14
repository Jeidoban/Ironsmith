import Foundation
import SwiftUI

struct GenerationSettingsView: View {
    @Environment(InferenceStore.self) private var inferenceStore

    private var isMLX: Bool { inferenceStore.selectedModel?.isMLX == true }
    private var selectedModel: ModelConfig? { inferenceStore.selectedModel }
    private var preferences: GenerationPreferencesStore { inferenceStore.generationPreferences }

    var body: some View {
        if selectedModel != nil {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Custom Generation Options")
                        .frame(width: 196, alignment: .leading)

                    Spacer()

                    Toggle("Custom Generation Options", isOn: binding(\.customOptionsEnabled))
                        .labelsHidden()
                        .toggleStyle(.switch)
                }

                if preferences.customOptionsEnabled {
                    SettingsSliderRowView(
                        title: "Temperature",
                        value: temperatureBinding,
                        range: temperatureRange,
                        format: "%.2f"
                    )
                    SettingsStepperRowView(
                        title: "Max Tokens",
                        value: binding(\.maximumResponseTokens),
                        range: 1024...65536,
                        step: 1024
                    )

                    if isMLX {
                        Divider()
                        Text("MLX KV Cache")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        SettingsStepperRowView(
                            title: "Max Size",
                            value: binding(\.mlxKVCacheMaxSize),
                            range: 1024...32768,
                            step: 512
                        )
                        Toggle("Quantize KV Cache", isOn: binding(\.mlxKVCacheBitsEnabled))
                            .toggleStyle(.switch)
                        if preferences.mlxKVCacheBitsEnabled {
                            LabeledContent("Bits") {
                                Picker("Bits", selection: binding(\.mlxKVCacheBits)) {
                                    ForEach(GenerationPreferencesStore.availableKVCacheBits, id: \.self) { bits in
                                        Text("\(bits)-bit").tag(bits)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
        } else {
            Text("Select an AI model to configure generation.")
                .foregroundStyle(.secondary)
        }
    }

    private func binding<Value>(
        _ keyPath: ReferenceWritableKeyPath<GenerationPreferencesStore, Value>
    ) -> Binding<Value> {
        Binding(
            get: { preferences[keyPath: keyPath] },
            set: { newValue in
                preferences[keyPath: keyPath] = newValue
            }
        )
    }

    private var temperatureRange: ClosedRange<Double> {
        selectedModel?.source == .appleFoundation ? 0...1 : 0...2
    }

    private var temperatureBinding: Binding<Double> {
        Binding(
            get: {
                min(max(preferences.temperature, temperatureRange.lowerBound), temperatureRange.upperBound)
            },
            set: { newValue in
                preferences.temperature = min(max(newValue, temperatureRange.lowerBound), temperatureRange.upperBound)
            }
        )
    }
}

@MainActor
private struct GenerationSettingsPreview: View {
    @State private var inferenceStore = SettingsPreviewState.make(selectedModel: .mlx)

    var body: some View {
        Form {
            Section("Generation") {
                GenerationSettingsView()
            }
        }
        .formStyle(.grouped)
        .environment(inferenceStore)
        .padding(20)
        .frame(width: 620, height: 480)
    }
}

#Preview("Inference Settings") {
    GenerationSettingsPreview()
}
