import Foundation
import Testing

@testable import Ironsmith

struct ToolStoreRemixStateClientTests {
    @Test
    func completedStateRemovesPendingContextSidecar() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = StoreRemixTestFixture.snapshot()
        let client = ToolStoreRemixStateClient.live

        try client.stage(snapshot, root)

        let stagedContext = try client.pendingContext(root)
        let pending = try #require(stagedContext)
        #expect(pending.originalPrompt == snapshot.originalPrompt)
        #expect(pending.refinedPrompt == snapshot.refinedPrompt)
        #expect(pending.codingAgent == snapshot.plan.codingAgent)
        #expect(pending.promptContext == snapshot.plan.promptContext)
        #expect(pending.baseSourceCode == snapshot.plan.base?.sourceCode)

        try client.complete(root)

        #expect(try client.pendingContext(root) == nil)
        #expect(
            !FileManager.default.fileExists(
                atPath: ToolPackageLayout.storeRemixStateURL(for: root).path
            )
        )
    }

    @Test
    func completedScratchStateRemovesEmptySidecar() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = StoreRemixTestFixture.snapshot(base: nil, capabilities: [])
        let client = ToolStoreRemixStateClient.live

        try client.stage(snapshot, root)
        try client.complete(root)

        #expect(
            !FileManager.default.fileExists(
                atPath: ToolPackageLayout.storeRemixStateURL(for: root).path
            )
        )
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ironsmith-store-remix-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

enum StoreRemixTestFixture {
    static func snapshot(
        base: StoreGenerationBaseContext? = base,
        capabilities: [StoreGenerationCapabilityContext] = capabilities,
        inspiredByVersionIds: [String]? = nil,
        codingAgent: String = "spark"
    ) -> StoreGenerationContextSnapshot {
        StoreGenerationContextSnapshot(
            originalPrompt: "Build a focused timer with presets",
            refinedPrompt: "Build a focused timer with selectable presets and sounds.",
            plan: StoreGenerationContextPlan(
                id: "plan-1",
                mode: base == nil ? (capabilities.isEmpty ? .scratch : .capabilitiesOnly) : .baseWithCapabilities,
                matchScore: 0.82,
                explanation: "The base matches the timer workflow.",
                confidenceBand: "high",
                resolvedAppKind: .window,
                codingAgent: codingAgent,
                permissionMode: "automatic",
                appliedStoreContextBudgetTokens: 16_000,
                estimatedStoreContextTokens: 800,
                promptContext: "[STORE-ASSISTED GENERATION CONTEXT]",
                resolvedSandboxPermissions: ["internet"],
                resolvedResourcePermissions: [],
                coveredRequirements: [],
                missingRequirements: [],
                adaptationInstructions: StoreGenerationAdaptationInstructions(
                    preserve: ["Run a focused timer"],
                    implement: ["Offer selectable presets"],
                    removeUnrelatedBehavior: true
                ),
                base: base,
                capabilities: capabilities,
                inspiredByVersionIds: inspiredByVersionIds ?? capabilities.map(\.versionId)
            )
        )
    }

    static let base = StoreGenerationBaseContext(
        versionId: "version-base",
        storeId: "store-1",
        appId: "app-1",
        appName: "Simple Timer",
        versionNumber: 3,
        runtimeVersion: IronsmithStoreConstants.runtimeVersion,
        appKind: .window,
        summary: "A small timer app.",
        coreWorkflow: "Start and stop a timer.",
        useCases: ["Focus"],
        frameworks: ["SwiftUI"],
        sandboxPermissions: "",
        resourcePermissions: "",
        sourceTokenEstimate: 100,
        score: 1,
        sourceCode: "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"Timer\") } }",
        sourceSha256: "sha256",
        generationSettings: StoreGenerationSettingsDTO(settings: .default),
        license: .mit,
        legalAttributions: []
    )

    static let capabilities = [
        capability(
            id: "capability-1",
            versionId: "version-capability-1",
            appId: "app-2",
            appName: "Preset Timer"
        ),
        capability(
            id: "capability-2",
            versionId: "version-capability-2",
            appId: "app-2",
            appName: "Preset Timer"
        ),
        capability(
            id: "capability-3",
            versionId: "version-capability-3",
            appId: "app-3",
            appName: "Sound Timer"
        ),
    ]

    private static func capability(
        id: String,
        versionId: String,
        appId: String,
        appName: String
    ) -> StoreGenerationCapabilityContext {
        StoreGenerationCapabilityContext(
            id: id,
            versionId: versionId,
            storeId: "store-1",
            appId: appId,
            appName: appName,
            title: "Reusable timer behavior",
            summary: "Adds reusable timer behavior.",
            blueprint: "Represent the behavior with SwiftUI state.",
            frameworks: ["SwiftUI"],
            requirements: [],
            constraints: [],
            validationSteps: []
        )
    }
}
