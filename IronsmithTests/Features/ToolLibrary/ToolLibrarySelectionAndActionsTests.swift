import AnyLanguageModel
import Foundation
import Supabase
import SwiftData
import Testing
@testable import Ironsmith

extension ToolLibraryTests {
    @MainActor
    @Test
    func toolLibraryStoreSelectsToolForEditingAndUpdatesPlaceholder() {
        let toolLibraryState = ToolLibraryStore()
        let tool = Tool(name: "Calculator", packageRootPath: "/tmp/calculator")
        let otherTool = Tool(name: "Notes", packageRootPath: "/tmp/notes")

        #expect(toolLibraryState.promptPlaceholder == "Describe a new app to build…")
        #expect(!(toolLibraryState.isSelected(tool)))

        toolLibraryState.selectForEditing(tool)

        #expect(toolLibraryState.isSelected(tool))
        #expect(toolLibraryState.promptPlaceholder == "Describe changes for Calculator…")

        toolLibraryState.handleDeletedTool(otherTool)

        #expect(toolLibraryState.isSelected(tool))
        toolLibraryState.syncSelection(with: [otherTool])
        #expect(!(toolLibraryState.isSelected(tool)))
        #expect(toolLibraryState.promptPlaceholder == "Describe a new app to build…")
    }

    @MainActor
    @Test
    func toolLibraryStoreTogglesSelectedToolBackToCreateMode() {
        let toolLibraryState = ToolLibraryStore()
        let tool = Tool(name: "Calculator", packageRootPath: "/tmp/calculator")

        toolLibraryState.toggleSelection(for: tool)

        #expect(toolLibraryState.isSelected(tool))
        #expect(toolLibraryState.promptPlaceholder == "Describe changes for Calculator…")

        toolLibraryState.toggleSelection(for: tool)

        #expect(!(toolLibraryState.isSelected(tool)))
        #expect(toolLibraryState.promptPlaceholder == "Describe a new app to build…")
    }

    @MainActor
    @Test
    func toolLibraryStoreSyncSelectionIsNoOpWhenNothingSelected() {
        let toolLibraryState = ToolLibraryStore()
        let tool = Tool(name: "Formatter", packageRootPath: "/tmp/formatter")

        // Nothing selected — syncSelection should not crash and state stays clear.
        toolLibraryState.syncSelection(with: [tool])

        #expect(!(toolLibraryState.isSelected(tool)))
        #expect(toolLibraryState.promptPlaceholder == "Describe a new app to build…")
    }

    @MainActor
    @Test
    func toolLibraryStoreHandleDeletedToolIsNoOpForNonSelectedTool() {
        let toolLibraryState = ToolLibraryStore()
        let selected = Tool(name: "Linter", packageRootPath: "/tmp/linter")
        let other = Tool(name: "Formatter", packageRootPath: "/tmp/formatter")

        toolLibraryState.selectForEditing(selected)
        toolLibraryState.handleDeletedTool(other)

        #expect(toolLibraryState.isSelected(selected))
        #expect(toolLibraryState.promptPlaceholder == "Describe changes for Linter…")
    }

    @MainActor
    @Test
    func toolLibraryStoreManualRunCallsRunner() async {
        let tool = Tool(name: "Runner", packageRootPath: "/tmp/runner")
        let runCapture = ToolRunCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
                    ToolGenerationResult(
                        toolName: "Runner",
                        executableName: "Runner",
                        packageRootURL: tool.packageRootURL,
                        manifest: ToolManifest(displayName: "Runner", executableName: "Runner", files: [])
                    )
                },
                runnerClient: ToolRunnerClient { tool in
                    await runCapture.record(tool)
                }
            )
        )

        await store.run(tool)

        #expect(await runCapture.ranToolIDs == [tool.id])
        #expect(store.runningToolID == nil)
        #expect(store.presentedErrorMessage == nil)
    }

    @MainActor
    @Test
    func toolLibraryStoreSyncSelectionKeepsSelectionWhenToolIsPresent() {
        let toolLibraryState = ToolLibraryStore()
        let tool = Tool(name: "Linter", packageRootPath: "/tmp/linter")

        toolLibraryState.selectForEditing(tool)
        toolLibraryState.syncSelection(with: [tool])

        #expect(toolLibraryState.isSelected(tool))
        #expect(toolLibraryState.promptPlaceholder == "Describe changes for Linter…")
    }

    @MainActor
    @Test
    func toolLibraryStoreRestoresPreviousVersionAndSwapsCurrentVersion() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executableName = "VersionedTool"
        let packageRoot = root.appendingPathComponent(executableName, isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: executableName)
        let contentViewPath = layout.sourcePath(for: layout.defaultContentViewFileName)
        let contentViewURL = packageRoot.appendingPathComponent(contentViewPath)
        let previousURL = layout.previousContentViewVersionURL
        let manifest = ToolManifest(
            displayName: executableName,
            executableName: executableName,
            files: [
                ToolManifestFile(path: contentViewPath, description: "Primary SwiftUI screen.")
            ]
        )
        try FileManager.default.createDirectory(at: contentViewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previousURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: layout.agentManifestURL)
        try #"Text("current")"#.write(to: contentViewURL, atomically: true, encoding: .utf8)
        try #"Text("previous")"#.write(to: previousURL, atomically: true, encoding: .utf8)

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let tool = Tool(name: executableName, packageRootPath: packageRoot.path)
        context.insert(tool)
        try context.save()

        let buildCapture = ToolBuildCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
                    ToolGenerationResult(
                        toolName: executableName,
                        executableName: executableName,
                        packageRootURL: packageRoot,
                        manifest: manifest
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                versionBackupClient: .live,
                buildClient: ToolBuildClient { tool in
                    await buildCapture.record(tool.packageRootURL)
                }
            )
        )
        await store.refreshRestoreAvailability(for: [tool])
        #expect(store.canRestorePreviousVersion(tool))

        await store.restorePreviousVersion(tool, in: context)

        let restoredSource = try String(contentsOf: contentViewURL, encoding: .utf8)
        let swappedPreviousSource = try String(contentsOf: previousURL, encoding: .utf8)
        #expect(restoredSource == #"Text("previous")"#)
        #expect(swappedPreviousSource == #"Text("current")"#)
        #expect(await buildCapture.builtPackageRoot == packageRoot)
        #expect(tool.lastPromptSummary == "Reverted to previous version")
        #expect(store.generationStatus == nil)
    }

    @MainActor
    @Test
    func toolLibraryStoreExportsToolAsApp() async throws {
        let tool = Tool(
            name: "Exporter",
            executableName: "Exporter",
            bundleIdentifier: "com.ironsmith.tests.exporter",
            packageRootPath: "/tmp/exporter"
        )
        let capture = ToolExportCapture()
        let finderCapture = ToolFinderCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
                    ToolGenerationResult(
                        toolName: "Exporter",
                        executableName: "Exporter",
                        packageRootURL: URL(fileURLWithPath: "/tmp/exporter", isDirectory: true),
                        manifest: ToolManifest(displayName: "Exporter", executableName: "Exporter", files: [])
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                exportClient: ToolExportClient { tool in
                    await capture.record(tool)
                    return URL(fileURLWithPath: "/Applications/Exporter.app", isDirectory: true)
                },
                finderClient: ToolFinderClient(
                    showToolDirectory: { _ in },
                    revealURL: { url in
                        await finderCapture.record(url)
                    }
                )
            )
        )

        await store.export(tool)

        #expect(await capture.exportedToolID == tool.id)
        #expect(await finderCapture.openedURL == URL(fileURLWithPath: "/Applications/Exporter.app", isDirectory: true))
        #expect(store.exportingToolID == nil)
        #expect(store.generationStatus == nil)
        #expect(store.presentedErrorMessage == nil)
    }

    @MainActor
    @Test
    func toolLibraryStoreShowsToolDirectoryInFinder() async {
        let tool = Tool(name: "Finder Tool", packageRootPath: "/tmp/finder-tool")
        let capture = ToolFinderCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
                    ToolGenerationResult(
                        toolName: "Finder Tool",
                        executableName: "FinderTool",
                        packageRootURL: tool.packageRootURL,
                        manifest: ToolManifest(displayName: "Finder Tool", executableName: "FinderTool", files: [])
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                finderClient: ToolFinderClient(
                    showToolDirectory: { tool in
                        await capture.record(tool.packageRootURL)
                    },
                    revealURL: { _ in }
                )
            )
        )

        await store.showInFinder(tool)

        #expect(await capture.openedURL == tool.packageRootURL)
        #expect(store.presentedErrorMessage == nil)
    }

    @MainActor
    @Test
    func toolLibraryStoreViewsContentViewSource() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executableName = "SourceViewer"
        let packageRoot = root.appendingPathComponent(executableName, isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: executableName)
        let contentViewPath = layout.sourcePath(for: layout.defaultContentViewFileName)
        let contentViewURL = packageRoot.appendingPathComponent(contentViewPath)
        let manifest = ToolManifest(
            displayName: executableName,
            executableName: executableName,
            files: [
                ToolManifestFile(path: contentViewPath, description: "Primary SwiftUI screen.")
            ]
        )
        try FileManager.default.createDirectory(at: contentViewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: layout.agentManifestURL)
        try "import SwiftUI\n".write(to: contentViewURL, atomically: true, encoding: .utf8)

        let tool = Tool(name: executableName, packageRootPath: packageRoot.path)
        let capture = ToolFinderCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
                    ToolGenerationResult(
                        toolName: executableName,
                        executableName: executableName,
                        packageRootURL: packageRoot,
                        manifest: manifest
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                finderClient: ToolFinderClient(
                    showToolDirectory: { _ in },
                    revealURL: { _ in },
                    openURL: { url in
                        await capture.record(url)
                    }
                )
            )
        )

        await store.viewSource(tool)

        #expect(await capture.openedURL == contentViewURL.standardizedFileURL)
        #expect(store.presentedErrorMessage == nil)
    }

    @MainActor
    @Test
    func toolLibraryStoreRejectsSourcePathsOutsidePackage() async throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let executableName = "BadSourceViewer"
        let packageRoot = root.appendingPathComponent(executableName, isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: executableName)
        let manifest = ToolManifest(
            displayName: executableName,
            executableName: executableName,
            files: [
                ToolManifestFile(path: "../outside.swift", description: "Escaping source.")
            ]
        )
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: layout.agentManifestURL)

        let tool = Tool(name: executableName, packageRootPath: packageRoot.path)
        let capture = ToolFinderCapture()
        let store = ToolLibraryStore(
            dependencies: ToolLibraryDependencies(
                generationClient: ToolGenerationClient { _, _, _, _, _, _, _ in
                    ToolGenerationResult(
                        toolName: executableName,
                        executableName: executableName,
                        packageRootURL: packageRoot,
                        manifest: manifest
                    )
                },
                runnerClient: ToolRunnerClient { _ in },
                finderClient: ToolFinderClient(
                    showToolDirectory: { _ in },
                    revealURL: { _ in },
                    openURL: { url in
                        await capture.record(url)
                    }
                )
            )
        )

        await store.viewSource(tool)

        #expect(await capture.openedURL == nil)
        #expect(store.presentedErrorMessage?.contains("outside the generated package") == true)
    }

    @MainActor
    @Test
    func toolLibraryStoreDiscardRemovesIncompleteCreateToolAndPackage() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("IncompleteCreate", isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: "IncompleteCreate")
        try FileManager.default.createDirectory(at: layout.packageMetadataDirectoryURL, withIntermediateDirectories: true)
        try "partial source".write(to: layout.pendingContentViewDraftURL, atomically: true, encoding: .utf8)

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let tool = Tool(
            name: "Incomplete Create",
            executableName: "IncompleteCreate",
            packageRootPath: packageRoot.path,
            generationState: .failed,
            generationPhase: .generatingSource,
            generationMode: .create,
            pendingPrompt: "Build an incomplete create"
        )
        context.insert(tool)
        try context.save()

        let store = ToolLibraryStore()
        store.discardGeneration(tool, in: context)

        #expect(try context.fetch(FetchDescriptor<StoredTool>()).isEmpty)
        #expect(!(FileManager.default.fileExists(atPath: packageRoot.path)))
        #expect(store.presentedErrorMessage == nil)
    }

    @MainActor
    @Test
    func toolLibraryStoreDiscardClearsIncompleteEditAndKeepsPackage() throws {
        let root = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageRoot = root.appendingPathComponent("IncompleteEdit", isDirectory: true)
        let layout = ToolPackageLayout(packageRootURL: packageRoot, executableName: "IncompleteEdit")
        let contentViewURL = layout.sourceDirectoryURL.appendingPathComponent(layout.defaultContentViewFileName)
        try FileManager.default.createDirectory(at: layout.sourceDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: layout.packageMetadataDirectoryURL, withIntermediateDirectories: true)
        try #"Text("last ready")"#.write(to: contentViewURL, atomically: true, encoding: .utf8)
        try "partial diff".write(to: layout.pendingContentViewDraftURL, atomically: true, encoding: .utf8)

        let container = try IronsmithModelContainerFactory.make(isRunningTests: true)
        let context = ModelContext(container)
        let tool = Tool(
            name: "Incomplete Edit",
            executableName: "IncompleteEdit",
            packageRootPath: packageRoot.path,
            generationState: .stopped,
            generationPhase: .generatingEditDiff,
            generationMode: .edit,
            pendingPrompt: "Edit this app",
            generationErrorSummary: "Stopped"
        )
        context.insert(tool)
        try context.save()

        let store = ToolLibraryStore()
        store.discardGeneration(tool, in: context)

        #expect(tool.generationState == .ready)
        #expect(tool.generationPhase == .completed)
        #expect(tool.generationMode == nil)
        #expect(tool.pendingPrompt == nil)
        #expect(tool.generationErrorSummary == nil)
        #expect(FileManager.default.fileExists(atPath: packageRoot.path))
        #expect(!(FileManager.default.fileExists(atPath: layout.pendingContentViewDraftURL.path)))
        #expect(try String(contentsOf: contentViewURL, encoding: .utf8) == #"Text("last ready")"#)
        #expect(store.presentedErrorMessage == nil)
    }
}
