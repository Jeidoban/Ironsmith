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
        let snapshot = StoreRemixTestFixture.snapshot(base: nil, inspirations: [])
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
        inspirations: [StoreGenerationInspirationReference] = inspirations,
        codingAgent: String = "spark"
    ) -> StoreGenerationContextSnapshot {
        StoreGenerationContextSnapshot(
            originalPrompt: "Build a focused timer with presets",
            refinedPrompt: "Build a focused timer with selectable presets and sounds.",
            plan: StoreGenerationContextPlan(
                mode: base == nil ? (inspirations.isEmpty ? .scratch : .capabilitiesOnly) : .baseWithCapabilities,
                codingAgent: codingAgent,
                promptContext: "[STORE-ASSISTED GENERATION CONTEXT]",
                resolvedSandboxPermissions: ["internet"],
                resolvedResourcePermissions: [],
                base: base,
                inspirations: inspirations
            )
        )
    }

    static let base = StoreGenerationBaseContext(
        versionId: "version-base",
        storeId: "store-1",
        appId: "app-1",
        appName: "Simple Timer",
        versionNumber: 3,
        sourceSha256: "sha256",
        sourceCode: "import SwiftUI\nstruct ContentView: View { var body: some View { Text(\"Timer\") } }"
    )

    static let inspirations = [
        inspiration(
            versionId: "version-capability-1",
            appId: "app-2",
            appName: "Preset Timer"
        ),
        inspiration(
            versionId: "version-capability-2",
            appId: "app-2",
            appName: "Preset Timer"
        ),
        inspiration(
            versionId: "version-capability-3",
            appId: "app-3",
            appName: "Sound Timer"
        ),
    ]

    private static func inspiration(
        versionId: String,
        appId: String,
        appName: String
    ) -> StoreGenerationInspirationReference {
        StoreGenerationInspirationReference(
            versionId: versionId,
            storeId: "store-1",
            appId: appId,
            appName: appName
        )
    }
}
