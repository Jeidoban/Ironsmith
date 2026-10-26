# Ironsmith Agent Guide

## Scope

- This guide covers the macOS app in `Ironsmith/` and its tests in `IronsmithTests/`.
- The backend is maintained as a separate sibling repository with its own `AGENTS.md`. For backend changes, read that guide and run Git commands from the backend repository.
- Source and focused tests are the operational source of truth. Prefer following nearby code patterns over expanding this guide with implementation details.

## Build And Test

- `Package.swift` is the app build graph and test source of truth. There is no committed Xcode project.
- Build and stage the app with `script/build.sh`; use `script/build.sh run` to launch it.
- Run tests with `script/test.sh`. Pass normal `swift test` filters through the script when narrowing a failure.
- Use `script/clean.sh` to remove SwiftPM and staged build outputs.
- Release, signing, packaging, architecture, and bundled Codex CLI options live in `script/build.sh`, `script/package.sh`, and `script/release.sh`; consult their usage text.
- Build-time backend values are documented in `Config/.env.example`; `Config/.env` is local and must not be committed.
- Tests use Swift Testing (`@Test`, `#expect`, `#require`), not XCTest.
- The GitHub CLI is authenticated in the host environment. If `gh` reports invalid authentication inside the sandbox, rerun the command with elevated sandbox access instead of reauthenticating or switching to browser automation.

## Project Map

- `Ironsmith/App`: application startup, AppKit controllers, routing, and auxiliary-window presentation.
- `Ironsmith/Core/Models`: stable model aliases, domain enums, and application-facing computed behavior.
- `Ironsmith/Core/Persistence`: SwiftData setup and migrations, app paths/preferences, startup seeding, and repositories.
- `Ironsmith/Core/Inference`: provider metadata, credentials/accounts, model discovery and selection, local model/Ollama work, language-model construction, and `InferenceStore`.
- `Ironsmith/Core/AgentPipeline`: generated-package layout, prompts, file/process clients, source cleanup, compile/repair loops, app bundling, permissions, icons, and generation runtime.
- `Ironsmith/Core/Store`: shared Store domain values used outside the Store feature.
- `Ironsmith/Features/Launch`: Command Line Tools detection and launch routing.
- `Ironsmith/Features/ToolLibrary`: menu bar UI, `ToolLibraryStore`, generation, tool actions, Store publishing, and app updates.
- `Ironsmith/Features/Settings`: settings UI and provider/model/account management.
- `Ironsmith/Features/Store`: Store browsing, details, source inspection, downloads, imports/remixes, licenses, and `StoreWindowStore`.
- `IronsmithTests` mirrors these areas. Put focused tests beside the behavior being changed.

## Architecture

- Views render state and send intent. Observable stores coordinate workflows. Repositories own persisted-data access. Small closure clients wrap network, process, Keychain, filesystem, and launch effects.
- Production dependencies are assembled by the relevant `Dependencies.live` or client factory. Tests should inject lightweight fake clients directly rather than adding test-only abstraction layers.
- `InferenceStore` owns shared provider, model, account, and generation-preference state. `ToolLibraryStore` owns tool selection and generation. `StoreWindowStore` owns Store navigation and workflows.
- `IronsmithRouteStore` owns cross-surface routing and external URL handling. Keep route parsing out of views and window controllers.
- Model invocation is stage-based (`codingAgent`, `promptRefinement`, and `metadata`). Route pipeline calls through `ToolLanguageModelInvoker` so streaming, generation options, and lifecycle hooks stay consistent.
- Keep network, Keychain, process, and filesystem effects out of SwiftUI views and SwiftData repositories.
- Prefer request/configuration objects when an operation needs several related values. Avoid compatibility initializers or forwarding wrappers created only to keep old tests compiling; update tests to the current API.

## App Shell

- Ironsmith is a menu-bar-first macOS app. `IronsmithApplicationController` wires persistence, shared stores, routing, settings, Store, Agent Output, and `IronsmithMenuBarController`.
- The main menu bar surface is an AppKit `NSStatusItem` and `NSPopover`. Generated tools may independently use SwiftUI window or `MenuBarExtra` app entries.
- Keep startup wiring in the application layer and feature state in its owning store. Do not introduce a template-style main window flow without an intentional product change.
- Startup installs the curated macOS Codex plugin opportunistically; failure is diagnostic-only and retries on the next launch.
- Prefer native macOS SwiftUI controls and small responsibility-focused views. Reuse existing presentation helpers instead of duplicating display cleanup.

## Inference

- `ProviderCatalog` is the source of truth for built-in provider behavior and presentation metadata. Do not duplicate provider tables in views or tests.
- `InferenceRepository` persists providers and local/installable models. Provider-discovered models remain transient unless persistence is deliberately redesigned.
- Treat `persistedModels`, `remoteModels`, and their combined available-model view as distinct concepts at call sites.
- Provider API keys go through the credential client/Keychain path. ChatGPT/Codex OAuth is the exception: Ironsmith owns PKCE and refreshes the private `CODEX_HOME` `auth.json` that the bundled CLI shares. Never log or send those tokens through the backend.
- Provider-specific discovery belongs in `RemoteModelClient`; provider-to-model-wrapper construction belongs in `LanguageModelClient`.
- Custom OpenAI-compatible providers persist their API variant. Keep transport-aware Codex support, model-family detection, automatic agent routing, and reasoning capability decisions in centralized inference helpers rather than views.
- User generation preferences and selected-model persistence belong in their dedicated stores, not provider records or views.
- `CustomCodingAgentStore` owns user-defined runner persistence and validation. `CustomCodingAgentClient` owns process execution and transcript handling.

## Agent Pipeline

- The active runtime is single-file: the model creates or edits only `Sources/<ExecutableName>/ContentView.swift`. Ironsmith owns `Package.swift` and the fixed app entry source.
- Spark, Flame, Codex, and custom runners share one coding-agent preference axis. Resolve automatic and requested choices through `ToolCodingAgentResolver`.
- Generated tools are SwiftPM packages under `IronsmithPaths.toolsDirectory`. Derive package files and metadata paths through `ToolPackageLayout`; do not reconstruct them at call sites.
- Create flow prepares metadata and icon assets early, generates source, cleans/formats it, compiles and repairs it, then builds the internal app bundle.
- Edit flow must preserve the original source and settings until the edited package builds successfully. Keep version staging and restore behavior in `ToolVersionBackupClient`.
- `ContentViewSourceCleanup` owns model-output normalization. Compiler-driven deterministic repairs should be general Swift/SwiftUI fixes; model repairs must remain validated changes confined to `ContentView.swift`.
- Keep repair thresholds and strategy selection centralized in `ToolGenerationRepairPolicy`, `ToolRepairStrategy`, and inference model selection logic.
- Codex and custom runners own their build/repair attempts and do not enter the Spark/Flame repair loop. Ironsmith must still restore protected files, validate `ContentView.swift`, and perform final build verification.
- Coding-agent output is persisted as tool-local JSONL and tailed for diagnostics and Agent Output. Keep raw command output out of diagnostics, preserve transcript/session metadata, and avoid retaining complete transcripts in memory.
- `GeneratedAppSandboxPermission` and `GeneratedAppResourcePermission` are the sources of truth for generated-app access. Keep planning, user settings, entitlements, and usage descriptions aligned.
- `ToolAppBundleClient` owns internal/exported app bundle construction, signing, entitlements, legal resources, icon copying, verification, replacement, and launch support. Do not duplicate bundle assembly elsewhere.
- Store imports, remixes, and publications must preserve version provenance, licenses, and inherited legal attribution. Preserve resumable remix state until completion or deliberate fallback.
- Preserve cancellation/resume state through the generation lifecycle. Owning stores reconcile persisted tool state with generation results and failures.
- Diagnostics use `AgentDiagnosticsLog`; keep logs compact and avoid dumping full model responses or secrets.

## Persistence And Files

- Production app data lives under `~/.ironsmith/`; use `IronsmithPaths` instead of hard-coded paths.
- The SwiftData store is `~/.ironsmith/db/ironsmith.sqlite`. Startup preparation imports the legacy Application Support store only when needed, preserves the source, and snapshots the destination before SwiftData opens it.
- Startup database backups include SQLite companion files and retain the three newest completed snapshots. Never silently delete or replace a failed user store.
- Use `IronsmithModelContainerFactory.make(isRunningTests: true)` for tests and previews.
- Persisted models are declared inside immutable versioned schema files in `Core/Persistence/Migrations`. `Core/Models` points application code at the current schema through typealiases and extensions.
- Persist singular SwiftData enum properties directly as their enum types. Use raw-value serialization only for enum collections that SwiftData cannot persist in the required shape.
- Keep one ordered `IronsmithSchemaMigrationPlan`. For each database change, add a new self-contained schema version and the adjacent migration stage; never mutate a shipped historical schema.
- Persisted model names, stored properties, and Store provenance are compatibility surfaces. Use SwiftData rename metadata and a migration when changing them.
- Generated-package file access must remain inside the package root. Preserve path validation in `ToolPackageLayout` and generation/version-backup helpers.

## Change Discipline

- Match existing ownership boundaries and naming before introducing a new abstraction.
- Keep changes scoped; do not refactor unrelated code or overwrite user work in a dirty tree.
- Add focused tests for behavior changes, especially persistence, generation lifecycle, source repair, provider discovery, Store workflows, and app bundling.
- Prefer structured parsers and typed models over ad hoc string manipulation where the platform or project already provides them.
- Before finishing, run the narrowest relevant tests, then `script/test.sh` when the change has shared or user-facing impact. Run `git diff --check` for all changes.
