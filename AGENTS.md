# Ironsmith Agent Guide

## Build And Test

- `Package.swift` is the source of truth for app builds and tests.
- Build and stage the development app with `script/build.sh`.
- Build and run the development app with `script/build.sh run`.
- Build a Developer ID-signed release app with `script/build.sh --release --sign-identity "Developer ID Application: Example (TEAMID)"`.
- Package and notarize the release app with `script/package.sh --sign-identity "Developer ID Application: Example (TEAMID)"` plus one complete notarization credential option group; pass an explicit `.app` path to package another bundle.
- Run tests with `script/test.sh`.
- Remove SwiftPM/script outputs with `script/clean.sh`.
- Build-time backend values are documented in `Config/.env.example`; local `Config/.env` is gitignored.
- App tests use Swift Testing (`@Test`, `#expect`, `#require`) rather than XCTest.

## Project Shape

- Ironsmith is a macOS menu bar app built with SwiftUI, SwiftData, Observation, Foundation Models, AnyLanguageModel, and a small AppKit bridge.
- The menu bar surface is `IronsmithMenuBarController`, an `NSStatusItem` plus `NSPopover`. Do not reintroduce `MenuBarExtra` unless the app shell is deliberately changed.
- `Ironsmith/App` owns app-level wiring. `IronsmithApp` should stay focused on model container setup, startup bootstrapping, shared state creation, the AppKit menu bar controller, and the SwiftUI `Settings` scene.
- `Ironsmith/Core/Models` contains persisted SwiftData model types and stable domain identifiers: `Tool`, `ProviderConfig`, and `ModelConfig`. Do not rename persisted model types or stored properties casually, including `ProviderConfig.baseURLString` with its `originalName`.
- `Ironsmith/Core/Persistence` owns SwiftData container creation, app data bootstrapping, filesystem paths, preference keys, and the small `ToolRepository`.
- `Ironsmith/Core/Inference` owns provider catalog metadata, inference state, repository access, credentials, account/credit state, remote model discovery, local MLX downloads, Ollama integration, model selection, generation preferences, and language model construction.
- `Ironsmith/Core/AgentPipeline` owns generated-tool scaffolding, metadata prompts, source cleanup, Swift package builds, compiler diagnostic parsing, deterministic repairs, optional model-diff repairs, app bundle building, icon generation, launch/export clients, version backups, and diagnostics logging.
- `Ironsmith/Features/Launch` owns launch routing and Xcode Command Line Tools detection/onboarding.
- `Ironsmith/Features/ToolLibrary` owns the compact menu bar popover, `ToolLibraryStore`, tool rows, Finder/export actions, restore-previous-version actions, prompt composition, launch state, and export state.
- `Ironsmith/Features/Settings` owns the settings scene content, provider/model sections, sheets, presentation helpers, and small reusable settings controls.
- Tests mirror this structure under `IronsmithTests/Core` and `IronsmithTests/Features`; add focused tests beside the behavior you change.

## Architecture Pattern

- Keep the app simple: views render state and send intent; stores coordinate workflows; repositories wrap data access and persistence; closure clients wrap effectful service/process/filesystem operations.
- `InferenceStore` is the shared `@Observable` state owner for inference. It exposes providers, persisted local models, transient remote models, selected model state, provider connection issues, Ollama transfer state, Ironsmith account/session/credit state, error/smoke-test state, `GenerationPreferencesStore`, and `ModelSelectionStore`.
- `ToolLibraryStore` is local `@Observable` state for the popover only. Do not put tool-list UI state, selected tool state, generation progress, export state, launch state, restore availability, prompt text, or sandbox toggle state into `InferenceStore`.
- `InferenceRepository` is the normal persisted-data access layer for providers and persisted local models. It currently uses SwiftData, but callers should depend on the repository boundary rather than storage details. It should not make network calls, touch Keychain, launch processes, or persist remote model discovery results.
- `AppDataBootstrapper` is startup seeding logic, not a general repository. It ensures app directories and baseline built-in data exist when their runtime dependencies are available.
- Closure clients are the main side-effect seams:
  - `CredentialClient` for Keychain-backed API keys.
  - `IronsmithAccountClient` for app-side account, session, credit pack, checkout, and account deletion operations.
  - `RemoteModelClient` for provider model-list requests, provider-specific headers, response decoding, and text-model filtering.
  - `LocalModelClient` for MLX HuggingFace Hub filesystem/download work.
  - `OllamaClient` for detecting/starting Ollama and pulling/deleting Ollama models.
  - `LanguageModelClient` for constructing/running AnyLanguageModel language models.
  - `ToolGenerationClient`, `ToolRunnerClient`, `ToolBuildClient`, `ToolExportClient`, `ToolFinderClient`, and `ToolVersionBackupClient` for generated-tool effects.
- `InferenceDependencies.live` and `ToolLibraryDependencies.live` wire production clients. Tests should inject fake closure clients directly instead of adding protocol/mock ceremony.
- `ProviderCatalog` is the source of truth for built-in provider display names, default base URLs, auth modes, origins, sort order, model-list paths, and response formats.

## Startup And State

- `IronsmithApp.init` creates the SwiftData `ModelContainer`, runs `AppDataBootstrapper.bootstrapIfNeeded`, creates `InferenceStore` and `CommandLineToolsGate`, and installs `IronsmithMenuBarController` outside tests.
- The app body intentionally exposes only the SwiftUI `Settings` scene; the menu bar popover is owned by the AppKit controller.
- `LaunchRouterView` calls `gate.start()` and `InferenceStore.loadIfNeeded(modelContext:)` from the menu bar path so inference state warms before users generate from the popover.
- `SettingsWindowView` calls `InferenceStore.prepareSettings(modelContext:)`, which loads once and refreshes providers that declare model-list behavior through the inference layer.
- `CommandLineToolsGate` and inference loading are independent. The gate decides checking/onboarding/tool-library routing, while inference loads providers and models.
- `selectedModelID` is persisted by `ModelSelectionStore` in UserDefaults and must use `providerIdentifier::modelIdentifier` so selection survives remote model refetches.
- `availableModels` is derived from installed/built-in `persistedModels` plus transient `remoteModels`. Reconciliation rules live in `InferenceStore` and should keep selection valid while surfacing user-visible fallback alerts through `selectedModelFallbackMessage`.

## Model And Provider Rules

- Keep one `ModelConfig` type for built-in local models, downloaded local models, local-server models, Ironsmith provider models, custom providers, and remote hosted provider models.
- Persist only models that the SwiftData repository explicitly allows. Provider-discovered models should stay transient unless persistence behavior is deliberately changed.
- Remote/provider-discovered models are transient `ModelConfig` values. They can be shown, selected, and used, but must not be inserted into SwiftData.
- Use clear naming at call sites:
  - `persistedModels` for SwiftData-backed local/installable models.
  - `remoteModels` for transient provider-discovered models.
  - `availableModels` for the unified in-memory list used by UI and generation.
- `ProviderKind` and `ProviderCatalog` are the source of truth for provider cases, display names, auth modes, default URLs, sort order, model-list behavior, and response formats. Do not duplicate those tables in UI or tests.
- Custom OpenAI-compatible providers get unique `custom.<uuid>` identifiers and may be added multiple times.
- API keys are stored in Keychain through `ProviderCredentialStore`; provider-specific required/optional credential behavior should follow `ProviderConfig.authMode`, `ProviderCatalog`, and `InferenceStore.makeProvider`.
- Ironsmith provider setup uses account/session/credit state instead of a Keychain API key. Before generation, `InferenceStore.prepareSelectedModelForGeneration()` refreshes account credits and validates that the selected Ironsmith model can generate.
- `RemoteModelClient` owns provider model-list request construction, response decoding, text-model filtering, and snapshot-alias cleanup. Add or change provider discovery there with focused tests.
- `LanguageModelClient` owns mapping selected `ModelConfig`/`ProviderConfig` pairs to concrete AnyLanguageModel wrappers. Keep provider-specific API variants and sessions there, not in views.
- User-facing generation preferences live in `GenerationPreferencesStore` and UserDefaults. Exact keys and source/model defaults belong in `GenerationPreferencesStore` and `ModelGenerationDefaults`, not `ProviderConfig`.
- Model catalogs such as `MLXModelCatalog` and `OllamaModelCatalog` are source-of-truth lists, not assumptions. UI, previews, and tests must tolerate empty catalogs and provider-discovered models.
- Keep `ProviderConfig.localProviderIdentifier` and `ModelConfig.appleFoundationIdentifier` as the built-in identifiers.

## Agent Pipeline

- The active generation runtime is intentionally single-file. `SingleFileToolGenerationRuntime` creates or edits one editable file: `Sources/<ExecutableName>/ContentView.swift`.
- Generated tools are SwiftPM executable packages under `~/.ironsmith/tools/<tool-slug>/`. `Package.swift` and the fixed `@main` app entry file are written by Ironsmith, not by the model.
- Generated package toolchain, language mode, and platform settings live in `ToolPackageLayout.packageManifestContent()`. Do not duplicate those values elsewhere.
- Tool metadata is stored in SwiftData, and generated-file paths are derived from `ToolPackageLayout`. There is no active `Protocols/` directory or action-plan agent.
- Create mode asks `ToolMetadataClient` for a short display name and icon prompt, writes the package scaffold, prompts the selected model for a complete `ContentView.swift`, cleans/formats it, compiles it, strips quarantine from the debug binary, and builds an internal app bundle.
- `ToolMetadataClient.live()` may use local structured generation for nicer metadata, but metadata generation must remain a soft enhancement with a deterministic fallback.
- Edit mode stages the current `ContentView.swift` in `.ironsmith/versions/pending-ContentView.swift`. Model-diff capable selections start with a bounded unified diff; deterministic-only selections rewrite the whole `ContentView.swift`. Successful edits promote the staged source to `previous-ContentView.swift`; failed edits restore the original source and discard the staged backup.
- `ContentViewSourceCleanup` runs before compile attempts and repair mutations. It strips fences/thinking blocks/scaffolding, removes generated app/preview blocks, normalizes imports and common macOS SwiftUI footguns, moves loose top-level state into `ContentView`, removes misplaced member-scope view blocks, wraps loose SwiftUI fragments when possible, and then asks `swift-format` to format the file.
- Builds use `swift build --package-path <packageRoot>` through `SwiftPackageProcessClient`; compiler diagnostics are parsed into `SwiftCompilerDiagnostic` values and filtered to actionable `ContentView.swift` errors.
- `ContentViewBuildRepairLoop` owns compile/repair/regeneration:
  - Generate a candidate and clean/format it.
  - Compile and parse Swift diagnostics.
  - Apply deterministic repairs repeatedly until stable, compiled, rolled back, or the deterministic pass limit is reached.
  - If the selected model allows model repair, ask for small validated unified diffs against authoritative `ContentView.swift`, compile accepted mutations, and roll back patches that increase `ContentView` error count or compile to the placeholder scaffold.
  - Compact a repair conversation once on context-window errors, then regenerate if repair still exceeds context.
  - Regenerate when the candidate has too many `ContentView` errors, deterministic-only repair stalls, model patches are repeatedly invalid/no-progress/rolled-back, or context-window limits are hit.
  - Track and restore the best candidate before failing, except edit failure restores the original source.
- `ToolGenerationRepairPolicy` is the shared policy surface for thresholds, generation attempts, deterministic pass count, initial edit hunk limits, repair hunk limits, invalid-patch stalls, and model repair budget.
- `ToolRepairStrategy` is selected by `InferenceStore` from model source and capability. Keep strategy choices and numeric budgets in `InferenceStore`/`ToolGenerationRepairPolicy`; avoid scattering model-name heuristics or hunk counts elsewhere.
- Deterministic repairs should be compiler-shape fixes, not prompt-specific app implementations. Prefer broadly applicable Swift/SwiftUI/macOS corrections tied to a diagnostic pattern. Add focused tests in `AgentPipelineTests` for every new fixer and ensure a failed deterministic edit is safe to skip or roll back.
- Model repair diffs must remain validated unified diffs. Do not accept prose patches, ambiguous context, full rewrites unless the file is malformed, or edits outside `ContentView.swift`.
- Diagnostics logging goes through `AgentDiagnosticsLog` and is DEBUG-only at `~/.ironsmith/agent-diagnostics.log`; keep logs compact enough to explain repair loops without dumping entire model responses.

## App Bundle And Tool Execution

- `ToolAppBundleClient` builds internal LSUIElement app bundles inside each generated package and exports Dock-visible bundles to `/Applications`.
- App bundle builds use release `swift build`, `swift build -c release --show-bin-path`, `Info.plist`, optional sandbox entitlements, ad hoc signing, code-sign verification, staged replacement with backup restore, and quarantine stripping.
- Generated app bundle metadata is written by `ToolAppBundleClient`; keep deployment/version values aligned with the app target in code and tests rather than copying them into guidance.
- App icons are cached under `.ironsmith/` inside the generated package. `ToolIconClient` owns icon generation/encoding and must fall back gracefully when richer icon generation is unavailable.
- `ToolRunnerClient` launches the internal app bundle and rebuilds it first if the bundle is missing or incomplete. Prefer app-bundle launch/export paths over launching raw SwiftPM binaries.
- `ToolExportClient` rebuilds for the export destination and reuses an existing `/Applications/<name>.app` only when the bundle identifier matches; otherwise it chooses a suffixed app name.

## Tool Library Rules

- The menu bar popover is intentionally compact: header/actions at top, tool list first, generation status when needed, and prompt composer at the bottom. Check `ToolLibraryPopoverView` for sizing.
- The header shows the selected model and, for Ironsmith models, live credit/session status. Keep it concise enough for the popover width.
- Clicking a tool row toggles edit mode. Running, reverting, exporting, showing in Finder, and deleting live in row controls/context menus.
- `ToolLibraryStore.startPromptSubmission` owns the cancellable generation task. `cancelGeneration()` should cancel that task, clear stale errors, and leave the UI in a sensible "Stopping" state while the task unwinds.
- `ToolLibraryStore.submitPrompt` should persist a new or edited `Tool` only after successful generation. If launching after generation fails, the tool may already be persisted and the launch error is surfaced/logged separately.
- After Ironsmith-backed generation, refresh account credits so the popover and settings do not show stale balances.
- Deleting a tool removes it from the SwiftData library. Do not add package-directory deletion unless that product behavior is intentionally changed and tested.
- The sandbox toggle is hidden unless `IronsmithPreferenceKeys.showSandboxOverride` is enabled in Settings. When hidden, generation forces sandboxing on.
- Restore-previous-version uses `ToolPackageLayout` to find `ContentView.swift`, swaps it with `.ironsmith/versions/previous-ContentView.swift`, rebuilds the internal app bundle, and updates the tool summary.

## Settings Rules

- Settings should remain a separate SwiftUI `Settings` scene opened with `SettingsLink` from the popover.
- `SettingsWindowView` is a grouped `Form` with model selection/generation settings, providers, preferences, and any diagnostic sections gated by build configuration.
- Provider add/edit flows live in sheets. `AddProviderSheetView` owns provider selection, credential/base URL entry, and provider-specific onboarding.
- `ProviderEditorSheetView` owns provider editing, local model management, local-server model management, account rows, credit purchase sheet presentation, sign-out, and account deletion UI.
- `SettingsModelSelectionSectionView` owns the selected-model row and searchable model picker. Model rows should use `SettingsModelPresentation` plus `ModelLogoView` rather than duplicating display-name/logo cleanup.
- `SettingsPreferencesSectionView` owns the user-facing sandbox override preference; the popover decides whether to show the toggle and forces sandboxing on when hidden.

## SwiftUI Conventions

- The app is intentionally menu-bar-first. Do not introduce a template-style main window flow.
- Prefer native macOS `Form`, `Section`, `LabeledContent`, `Picker`, `Toggle`, `Stepper`, `Slider`, `List`, and sheet patterns in Settings.
- Use `@Environment(InferenceStore.self)` for shared inference state. When a view needs bindings into the store, create a local `@Bindable var inferenceStore = inferenceStore` inside `body`.
- Keep SwiftUI scene roots and section views small. Extract a view when it names a real responsibility, not just to split lines.
- Local preview frames should resemble the real surface being previewed, especially popover and settings-window previews.
- Be careful with previews and tests that index catalogs. Catalog arrays can be empty.
- Provider/model presentation helpers live in Settings controls (`ProviderLogoView`, `ModelLogoView`, `SettingsModelPresentation`); prefer extending them over duplicating logo/name cleanup logic.

## Persistence And Safety

- Use `IronsmithModelContainerFactory.make(isRunningTests: true)` for SwiftData tests and previews.
- Do not silently delete a failed persistent store. The container factory backs up bad sqlite/wal/shm files under `~/.ironsmith/Backups/` before creating a fresh store.
- App data lives under `~/.ironsmith/`: `ironsmith.sqlite`, `models/`, `tools/`, and the DEBUG diagnostics log.
- Use `Tool` and `ToolPackageLayout` derived URL helpers for package roots, package manifests, metadata, versions, app bundles, cached icons, and entitlements instead of rebuilding those paths at call sites.
- `ToolGenerationRuntimeContext.packageFileURL` and `ToolVersionBackupClient` validate that generated-tool file access stays inside the package root. Preserve those path-escape checks.
- The generator does not write protocol files, but `Tool.protocolsDirectoryURL` may still exist for compatibility/future work. Do not build new agent flow around protocols unless the runtime is intentionally changed.
- No Xcode project is committed. Open the root `Package.swift` in Xcode when IDE debugging is needed, and keep build graph changes in SwiftPM/script files.

## AnyLanguageModel Dependency

- The app depends directly on the `AnyLanguageModel` package from the root `Package.swift`.
- Do not enable the `AnyLanguageModel` MLX trait during the SwiftPM-first migration unless that product decision changes deliberately.
- Do not reintroduce `Packages/AnyLanguageModelShim`; it existed for Xcode trait limitations and is no longer part of the default build.

## Product Notes

- Source and tests are the operational source of truth. `docs/ironsmith-spec.md` is useful product background, but parts of it still describe older `MenuBarExtra`, architecture-agent, action-plan, and protocol-file ideas.
- The active generation pipeline is the single-file `ContentView.swift` runtime plus signed app-bundle packaging. Treat older architecture/action-plan/protocol-file notes as obsolete unless reintroduced deliberately.
- Generated user tools and downloaded local assets live under paths defined by `IronsmithPaths`; do not hard-code those paths outside the path helpers.
- Models managed by an external local server should be treated as provider-discovered remote models rather than SwiftData-persisted downloads.
