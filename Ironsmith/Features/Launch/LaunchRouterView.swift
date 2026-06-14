//
//  LaunchRouterView.swift
//  Ironsmith
//

import SwiftData
import SwiftUI

struct LaunchRouterView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(InferenceStore.self) private var inferenceStore
    @State private var appUpdateStore: AppUpdateStore
    let gate: CommandLineToolsGate

    @MainActor
    init(gate: CommandLineToolsGate) {
        self.gate = gate
        _appUpdateStore = State(initialValue: AppUpdateStore())
    }

    var body: some View {
        // The root view is just a router: loading, onboarding, or the tool library.
        Group {
            switch gate.route {
            case .checking:
                ProgressView("Checking Command Line Tools…")
                    .frame(width: 360, height: 220)
                    .accessibilityIdentifier("app-launch-checking")
            case .onboarding:
                CommandLineToolsOnboardingView(
                    isChecking: gate.isCheckingInstallation,
                    notFoundMessageID: gate.notFoundMessageID,
                    onRetry: gate.refreshNow
                )
            case .shell:
                ToolLibraryPopoverView(appUpdateStore: appUpdateStore)
            }
        }
        .task {
            gate.start()
            appUpdateStore.startAutomaticChecks()
            await inferenceStore.loadIfNeeded(modelContext: modelContext)
        }
    }
}

#Preview("Launch Router - Tool Library") {
    let container = try! IronsmithModelContainerFactory.make(isRunningTests: true)
    let menuBarPopoverPresentationStore = MenuBarPopoverPresentationStore()
    return LaunchRouterView(gate: CommandLineToolsGate())
        .modelContainer(container)
        .environment(InferenceStore())
        .environment(menuBarPopoverPresentationStore)
}

#Preview("Launch Router - Onboarding") {
    let container = try! IronsmithModelContainerFactory.make(isRunningTests: true)
    let menuBarPopoverPresentationStore = MenuBarPopoverPresentationStore()
    return LaunchRouterView(gate: CommandLineToolsGate())
        .modelContainer(container)
        .environment(InferenceStore())
        .environment(menuBarPopoverPresentationStore)
}
