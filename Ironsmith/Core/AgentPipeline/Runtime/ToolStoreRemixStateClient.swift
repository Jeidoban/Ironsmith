import Foundation

nonisolated struct PendingStoreGenerationContext: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let originalPrompt: String
    let refinedPrompt: String
    let codingAgent: String
    let promptContext: String
    let resolvedSandboxPermissions: [String]
    let resolvedResourcePermissions: [String]
    let baseSourceCode: String?

    init(snapshot: StoreGenerationContextSnapshot) {
        let plan = snapshot.plan
        schemaVersion = 1
        originalPrompt = snapshot.originalPrompt
        refinedPrompt = snapshot.refinedPrompt
        codingAgent = plan.codingAgent
        promptContext = plan.promptContext
        resolvedSandboxPermissions = plan.resolvedSandboxPermissions
        resolvedResourcePermissions = plan.resolvedResourcePermissions
        baseSourceCode = plan.base?.sourceCode
    }
}

struct ToolStoreRemixStateClient {
    var stage: (
        _ snapshot: StoreGenerationContextSnapshot,
        _ packageRootURL: URL
    ) throws -> Void
    var pendingContext: (_ packageRootURL: URL) throws -> PendingStoreGenerationContext?
    var complete: (_ packageRootURL: URL) throws -> Void
    var clear: (_ packageRootURL: URL) throws -> Void

    nonisolated static let live = ToolStoreRemixStateClient(
        stage: { snapshot, packageRootURL in
            try write(
                PendingStoreGenerationContext(snapshot: snapshot),
                packageRootURL: packageRootURL
            )
        },
        pendingContext: { packageRootURL in
            try read(packageRootURL: packageRootURL)
        },
        complete: { packageRootURL in
            try removeFile(packageRootURL: packageRootURL)
        },
        clear: { packageRootURL in
            try removeFile(packageRootURL: packageRootURL)
        }
    )
}

nonisolated private func read(
    packageRootURL: URL
) throws -> PendingStoreGenerationContext? {
    let url = ToolPackageLayout.storeRemixStateURL(for: packageRootURL)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(
        PendingStoreGenerationContext.self,
        from: Data(contentsOf: url)
    )
}

nonisolated private func write(
    _ state: PendingStoreGenerationContext,
    packageRootURL: URL
) throws {
    let url = ToolPackageLayout.storeRemixStateURL(for: packageRootURL)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try encoder.encode(state).write(to: url, options: .atomic)
}

nonisolated private func removeFile(packageRootURL: URL) throws {
    let url = ToolPackageLayout.storeRemixStateURL(for: packageRootURL)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
}
