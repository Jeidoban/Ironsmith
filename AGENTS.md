# Ironsmith Agent Guide

## Scope

- This guide covers the macOS app in `Ironsmith/` and its tests in `IronsmithTests/`.
- `ironsmith-backend/` is a separate nested repository with its own `AGENTS.md`. Work from that directory and follow its guide for backend changes.
- Source and focused tests are the operational source of truth. Prefer following nearby code patterns over expanding this guide with implementation details.

## Build And Test

- `Package.swift` is the app build graph and test source of truth. There is no committed Xcode project.
- Build and stage the app with `script/build.sh`; use `script/build.sh run` to launch it.
- Run tests with `script/test.sh`. Pass normal `swift test` filters through the script when narrowing a failure.
- Use `script/clean.sh` to remove SwiftPM and staged build outputs.
- Release, signing, packaging, and notarization workflows live in `script/build.sh`, `script/package.sh`, and `script/release.sh`; consult their usage text rather than duplicating flags here.
- Build-time backend values are documented in `Config/.env.example`; `Config/.env` is local and must not be committed.
- Tests use Swift Testing (`@Test`, `#expect`, `#require`), not XCTest.

## Project Map

- `Ironsmith/App`: application startup, AppKit controllers, routing, settings/about window presentation.
- `Ironsmith/Core/Models`: stable model aliases, domain enums, and application-facing computed behavior.
- `Ironsmith/Core/Persistence`: SwiftData setup and migrations, app paths/preferences, startup seeding, and repositories.
- `Ironsmith/Core/Inference`: provider metadata, credentials/accounts, model discovery and selection, local model/Ollama work, language-model construction, and `InferenceStore`.
- `Ironsmith/Core/AgentPipeline`: generated-package layout, prompts, file/process clients, source cleanup, compile/repair loops, app bundling, icons, and generation runtime.
- `Ironsmith/Features/Launch`: Command Line Tools detection and launch routing.
- `Ironsmith/Features/ToolLibrary`: menu bar popover UI, `ToolLibraryStore`, tool actions, and app update checks.
- `Ironsmith/Features/Settings`: settings UI and provider/model management.
- `IronsmithTests` mirrors these areas. Put focused tests beside the behavior being changed.

## Architecture

- Views render state and send intent. Observable stores coordinate workflows. Repositories own persisted-data access. Small closure clients wrap network, process, Keychain, filesystem, and launch effects.
- Production dependencies are assembled by the relevant `Dependencies.live` or client factory. Tests should inject lightweight fake clients directly rather than adding test-only abstraction layers.
- `InferenceStore` owns shared provider, model, account, and generation-preference state. `ToolLibraryStore` owns popover-specific selection, prompt, generation, launch, export, and restore state.
- Keep network, Keychain, process, and filesystem effects out of SwiftUI views and SwiftData repositories.
- Prefer request/configuration objects when an operation needs several related values. Avoid compatibility initializers or forwarding wrappers created only to keep old tests compiling; update tests to the current API.

## App Shell

- Ironsmith is a menu-bar-first macOS app. `IronsmithApplicationController` wires persistence, shared stores, routing, settings, and `IronsmithMenuBarController`.
- The main menu bar surface is an AppKit `NSStatusItem` and `NSPopover`. Generated tools may independently use SwiftUI window or `MenuBarExtra` app entries.
- Keep startup wiring in the application layer and feature state in its owning store. Do not introduce a template-style main window flow without an intentional product change.
- Prefer native macOS SwiftUI controls and small responsibility-focused views. Reuse existing provider/model presentation helpers instead of duplicating display cleanup.

## Inference

- `ProviderCatalog` is the source of truth for built-in provider behavior and presentation metadata. Do not duplicate provider tables in views or tests.
- `InferenceRepository` persists providers and local/installable models. Provider-discovered models remain transient unless persistence is deliberately redesigned.
- Treat `persistedModels`, `remoteModels`, and their combined available-model view as distinct concepts at call sites.
- API keys go through the credential client/Keychain path. Ironsmith account, session, and credit behavior goes through `IronsmithAccountClient`.
- Provider-specific discovery belongs in `RemoteModelClient`; provider-to-model-wrapper construction belongs in `LanguageModelClient`.
- User generation preferences and selected-model persistence belong in their dedicated stores, not provider records or views.

## Agent Pipeline

- The active runtime is single-file: the model creates or edits only `Sources/<ExecutableName>/ContentView.swift`. Ironsmith owns `Package.swift` and the fixed app entry source.
- Generated tools are SwiftPM packages under `IronsmithPaths.toolsDirectory`. Derive package files and metadata paths through `ToolPackageLayout`; do not reconstruct them at call sites.
- Create flow prepares metadata and icon assets early, generates source, cleans/formats it, compiles and repairs it, then builds the internal app bundle.
- Edit flow must preserve the original source and settings until the edited package builds successfully. Keep version staging and restore behavior in `ToolVersionBackupClient`.
- `ContentViewSourceCleanup` owns model-output normalization. Compiler-driven deterministic repairs should be general Swift/SwiftUI fixes; model repairs must remain validated changes confined to `ContentView.swift`.
- Keep repair thresholds and strategy selection centralized in `ToolGenerationRepairPolicy`, `ToolRepairStrategy`, and inference model selection logic.
- `ToolAppBundleClient` owns internal/exported app bundle construction, signing, entitlements, icon copying, verification, replacement, and launch support. Do not duplicate bundle assembly elsewhere.
- Preserve cancellation/resume state through the generation lifecycle. `ToolLibraryStore` is responsible for reconciling persisted tool state with generation results and failures.
- Diagnostics use `AgentDiagnosticsLog`; keep logs compact and avoid dumping full model responses or secrets.

## Persistence And Files

- Production app data lives under `~/.ironsmith/`; use `IronsmithPaths` instead of hard-coded paths.
- The SwiftData store is `~/.ironsmith/db/ironsmith.sqlite`. Startup preparation imports the legacy Application Support store only when needed, preserves the source, and snapshots the destination before SwiftData opens it.
- Startup database backups include SQLite companion files and retain the three newest completed snapshots. Never silently delete or replace a failed user store.
- Use `IronsmithModelContainerFactory.make(isRunningTests: true)` for tests and previews.
- Persisted models are declared inside immutable versioned schema files in `Core/Persistence/Migrations`. `Core/Models` points application code at the current schema through typealiases and extensions.
- Keep one ordered `IronsmithSchemaMigrationPlan`. For each database change, add a new self-contained schema version and the adjacent migration stage; never mutate a shipped historical schema.
- Persisted model names and stored properties are compatibility surfaces. Use SwiftData rename metadata and a migration when changing them.
- Generated-package file access must remain inside the package root. Preserve the path validation in `ToolPackageLayout` and generation/version-backup helpers.

## Change Discipline

- Match existing ownership boundaries and naming before introducing a new abstraction.
- Keep changes scoped; do not refactor unrelated code or overwrite user work in a dirty tree.
- Add focused tests for behavior changes, especially persistence, generation lifecycle, source repair, provider discovery, and app bundling.
- Prefer structured parsers and typed models over ad hoc string manipulation where the platform or project already provides them.
- Before finishing, run the narrowest relevant tests, then `script/test.sh` when the change has shared or user-facing impact. Run `git diff --check` for all changes.
