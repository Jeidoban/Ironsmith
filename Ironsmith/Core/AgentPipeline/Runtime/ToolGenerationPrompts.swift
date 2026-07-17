import Foundation

enum ToolSourcePatchFormat: Equatable, Sendable {
    case searchReplace
    case unifiedDiff
}

enum ToolGenerationPrompts {
    static let singleFileCodingInstructions = """
        You are Ironsmith's Coding Agent.
        Write exactly one complete Swift file named ContentView.swift for a SwiftUI app based on the user's request.
        Return only Swift source code.
        Do not add comments except for MARK.
        Do not add introductions, explanations, or labels like "Here is the fixed ContentView.swift file:".
        Define ContentView as the root View; same-file helper View types are allowed for complex UI.
        Helper types are allowed, but helper types must not conform to App.
        Keep simple UI state directly inside ContentView with @State properties; helper models/classes are allowed for platform APIs, async work, timers, audio, and files.
        Do not create preview providers or #Preview blocks.
        Do not create Package.swift, AppDelegate, or SceneDelegate.
        Do NOT append @main to any struct. This entry point already exists and already calls ContentView
        This is a macOS SwiftUI app. Do not use iOS-only modifiers such as keyboardType.
        The prompt states whether ContentView is hosted as a normal window app or a menu bar app. Respect that app type when choosing scope, layout density, and sizing.
        The generated app is self-contained and runs on the user's Mac, with direct internet requests allowed when the user's request requires them.
        The prompt states whether the generated app uses the app sandbox. Treat that as runtime context, not a reason to reduce useful scope: when sandboxed, use sandbox-compatible macOS patterns such as user-selected files, and open/save/import panels etc.; when unsandboxed, use what is needed to complete the user's ask, but do not change the user's system unless asked or required.
        Local persistence is welcome when useful: in-memory state, @AppStorage, UserDefaults, local files, import/export, and open/save panels are all fine if they fit in this single file.
        Do not add or imply a separate backend service, custom server component, account system, iCloud/CloudKit integration, push notifications, analytics, subscriptions, or cross-device sync.
        Make the app feel native to macOS: prefer SwiftUI controls such as Form, List, Table, Picker, Toggle, Slider, Stepper, DatePicker, NavigationSplitView, toolbars, menus, keyboard shortcuts, system colors, and adaptive materials.
        Avoid mobile-first patterns, oversized marketing-style layouts, fake web dashboards, and custom controls when native macOS controls fit better.
        Games, drawing canvases, and highly visual toys may use custom graphics and game-like UI, but they should still use sensible macOS window sizing, pointer and keyboard behavior, and local-only state.
        For numeric input, use TextField("Label", value: $number, format: .number), not text: $number.
        For display rounding, use String(format:) or Text specifiers. Do not call rounded(toPlaces:).
        Avoid mutating let constants. Assign calculation results directly to @State properties when possible.
        Avoid checking isEmpty on numeric values. Compare numbers to 0 instead.
        Don't make anything overly complex. The code needs to fit in a single file.
        Break complex SwiftUI bodies into small same-file helper views/properties to avoid type-checker timeouts.
        If what the user asks is too complicated, simplify it so it fits in the ContentView.
        Prefer Apple platform frameworks and native APIs when they fit the request, such as Vision for OCR, PDFKit for PDFs, AVFoundation for media etc.
        Use these stable sections when possible:
        // MARK: - State
        // MARK: - Body
        // MARK: - Actions
        // MARK: - Helpers
        """

    static let searchReplaceRepairInstructions = """
        You are Ironsmith's Swift compiler repair agent.
        You repair exactly one file: ContentView.swift.
        \(searchReplaceOutputContract)
        \(validSearchReplaceShapeExample)
        Keep each repair turn focused on the listed compiler diagnostics.
        """

    static let searchReplaceEditInstructions = """
        You are Ironsmith's Swift edit agent.
        You edit exactly one file: ContentView.swift.
        \(searchReplaceOutputContract)
        \(validSearchReplaceShapeExample)
        Keep the edit focused on the user's requested change.
        Prefer the fewest unique search/replace blocks needed.
        """

    static let unifiedDiffRepairInstructions = """
        You are Ironsmith's Swift compiler repair agent.
        You repair exactly one file: ContentView.swift.
        \(unifiedDiffOutputContract)
        \(validUnifiedDiffShapeExample)
        Keep each repair turn focused on the listed compiler diagnostics.
        """

    static let unifiedDiffEditInstructions = """
        You are Ironsmith's Swift edit agent.
        You edit exactly one file: ContentView.swift.
        \(unifiedDiffOutputContract)
        \(validUnifiedDiffShapeExample)
        Keep the edit focused on the user's requested change.
        Prefer the fewest unified diff hunks needed.
        """

    static func repairInstructions(for format: ToolSourcePatchFormat) -> String {
        switch format {
        case .searchReplace:
            return searchReplaceRepairInstructions
        case .unifiedDiff:
            return unifiedDiffRepairInstructions
        }
    }

    static func editInstructions(for format: ToolSourcePatchFormat) -> String {
        switch format {
        case .searchReplace:
            return searchReplaceEditInstructions
        case .unifiedDiff:
            return unifiedDiffEditInstructions
        }
    }

    static func singleFileCreatePrompt(
        userPrompt: String,
        executableName: String,
        sandboxEnabled: Bool = true,
        appKind: ToolAppKind = .window
    ) -> String {
        """
        Build the smallest complete version of the requested app.
        Prefer a compiling, polished, narrow app over a broad unfinished app.

        User request: \(userPrompt)
        Fixed package and target name: \(executableName).
        \(appPresentationContext(appKind: appKind))
        \(sandboxContext(sandboxEnabled: sandboxEnabled))
        Generate ContentView.swift only.

        """
    }

    nonisolated static func sandboxContext(sandboxEnabled: Bool) -> String {
        if sandboxEnabled {
            """
            App sandbox: enabled.
            Build the requested app normally, using sandbox-compatible macOS patterns.
            """
        } else {
            """
            App sandbox: disabled.
            The app may use what it needs to complete the user's ask, but it must not make changes to the user's system unless the user asks for them or the request requires them.
            """
        }
    }

    nonisolated static func appPresentationContext(appKind: ToolAppKind) -> String {
        switch appKind {
        case .window:
            """
            App type: window app.
            ContentView is hosted in a normal macOS WindowGroup. Build a native desktop layout sized for a regular app window when the user's request calls for it.
            """
        case .menuBar:
            """
            App type: menu bar app.
            ContentView is hosted inside a MenuBarExtra popover-style window, not a regular full-size app window.
            Build it as a compact menu bar utility: concise controls, short labels, focused workflows, bounded width and height, and native macOS controls that work well in a popover.
            Do not include the app title in the UI, as it will already be visible in the menu bar.
            """
        }
    }

    static func singleFileEditPrompt(
        userPrompt: String,
        executableName: String,
        existingSource: String
    ) -> String {
        """
        User request: \(userPrompt)
        Fixed package and target name: \(executableName).
        Rewrite ContentView.swift only.
        Existing ContentView.swift:
        \(existingSource)
        """
    }

    static func diagnosticCreateWholeFileRewritePrompt(
        userPrompt: String,
        generationPrompt: String,
        executableName: String,
        sandboxEnabled: Bool,
        appKind: ToolAppKind,
        currentSource: String,
        diagnostics: [SwiftCompilerDiagnostic]
    ) -> String {
        let refinedContext = generationPrompt == userPrompt
            ? ""
            : "Refined generation brief: \(generationPrompt)"
        return diagnosticWholeFileRewritePrompt(
            requestContext: """
            Original create request: \(userPrompt)
            \(refinedContext)
            Fixed package and target name: \(executableName).
            \(appPresentationContext(appKind: appKind))
            \(sandboxContext(sandboxEnabled: sandboxEnabled))
            """,
            currentSource: currentSource,
            diagnostics: diagnostics
        )
    }

    static func diagnosticEditWholeFileRewritePrompt(
        userPrompt: String,
        executableName: String,
        currentSource: String,
        diagnostics: [SwiftCompilerDiagnostic]
    ) -> String {
        diagnosticWholeFileRewritePrompt(
            requestContext: """
            Original edit request: \(userPrompt)
            Fixed package and target name: \(executableName).
            Preserve the requested edit and all working behavior in the current implementation.
            """,
            currentSource: currentSource,
            diagnostics: diagnostics
        )
    }

    static func singleFileEditPatchPrompt(
        userPrompt: String,
        executableName: String,
        existingSource: String,
        maximumPatchBlocks: Int,
        previousPatchFailure: String? = nil,
        patchFormat: ToolSourcePatchFormat = .searchReplace
    ) -> String {
        """
        User request: \(userPrompt)
        Fixed package and target name: \(executableName).
        \(editPatchRequest(for: patchFormat))
        \(patchTurnReminder(maximumPatchBlocks, format: patchFormat))
        \(previousPatchFailureSection(previousPatchFailure))
        Current authoritative ContentView.swift:
        ```swift
        \(existingSource)
        ```
        """
    }

    static func sourceContinuationPrompt(
        originalPrompt: String,
        partialSource: String
    ) -> String {
        """
        Continue the exact Swift source response that was interrupted.
        Return only the next characters of ContentView.swift.
        Do not repeat any text from the partial source.
        Do not include markdown fences, explanations, or labels.

        Original request context:
        \(originalPrompt)

        Partial ContentView.swift already generated that needs to be completed:
        ```swift
        \(partialSource)
        ```
        """
    }

    private static func diagnosticWholeFileRewritePrompt(
        requestContext: String,
        currentSource: String,
        diagnostics: [SwiftCompilerDiagnostic]
    ) -> String {
        return """
        Narrow compiler repair stalled on this app.
        Rewrite the complete ContentView.swift to fix every compiler error listed below.
        Preserve the current app's working behavior, structure, and visual design wherever possible.
        Return only the complete corrected Swift source file. Do not return a diff, patch, explanation, or markdown fence.

        \(requestContext)

        Current authoritative ContentView.swift:
        ```swift
        \(currentSource)
        ```

        Current actionable compiler errors:
        \(formattedDiagnostics(diagnostics))
        """
    }

    static func conversationalRepairPrompt(
        diagnostics: [SwiftCompilerDiagnostic],
        source: String?,
        editableSnippets: [ContentViewRepairSnippet] = [],
        previousOutcome: String?,
        compactionSummary: String?,
        maximumPatchBlocks: Int,
        patchFormat: ToolSourcePatchFormat = .searchReplace
    ) -> String {
        var sections = [
            "Build failed for ContentView.swift.",
            "Compiler diagnostics:",
            formattedDiagnostics(diagnostics),
        ]

        if let previousOutcome, !previousOutcome.isEmpty {
            sections.append(
                """
                Previous repair outcome:
                \(previousOutcome)
                """
            )
        }

        if let compactionSummary, !compactionSummary.isEmpty {
            sections.append(
                """
                Compacted repair summary:
                \(compactionSummary)
                """
            )
        }

        if diagnostics.contains(where: ContentViewRepairSupport.isTypeCheckTimeout) {
            sections.append(
                "SwiftUI type-checker note: the reported line is often only where inference gave up; prefer extracting named same-file helper views/properties over local modifier tweaks."
            )
        }

        if let source {
            sections.append(
                """
                Current authoritative ContentView.swift:
                ```swift
                \(source)
                ```
                This source replaces any previous ContentView.swift in the conversation.
                """
            )
        }

        if !editableSnippets.isEmpty {
            sections.append(
                """
                Relevant current excerpts from authoritative ContentView.swift:
                \(repairExcerptsText(editableSnippets))
                These excerpts are context hints, not edit boundaries.
                \(repairPatchScopeDescription(for: patchFormat))
                """
            )
        }

        sections.append(
            """
            \(repairPatchRequest(for: patchFormat))
            \(patchTurnReminder(maximumPatchBlocks, format: patchFormat))
            Do not reuse removed source from previous repair outcomes.
            Make one coherent repair step, then stop.
            """
        )

        return sections.joined(separator: "\n\n")
    }

    private static let searchReplaceOutputContract = """
        Return only search/replace patch blocks.
        Each block must use this exact marker shape:
        <<<<<<< SEARCH
        exact code currently in ContentView.swift
        =======
        replacement code
        >>>>>>> REPLACE
        To insert without replacing, use <<<<<<< INSERT_BEFORE or <<<<<<< INSERT_AFTER with a unique existing anchor, then =======, inserted code, and >>>>>>> INSERT.
        SEARCH text must be non-empty.
        SEARCH/insert anchor text must be copied exactly from the current ContentView.swift and match one unique region.
        Include enough surrounding code to make it unique.
        Empty REPLACE is allowed only when deleting code.
        Do not include apply-patch markers.
        Do not include prose, markdown fences, JSON, explanations, file paths, or unrelated rewrites.
        Do not rewrite the entire file unless the whole file is malformed.
        """

    private static let unifiedDiffOutputContract = """
        Return only a unified diff that updates ContentView.swift.
        Prefer the standard --- a/ContentView.swift and +++ b/ContentView.swift file headers followed by one or more @@ hunks.
        Prefix unchanged context with one space, removed lines with -, and added lines with +.
        Hunk range numbers may be approximate, but existing context and removed lines must come from the current ContentView.swift.
        Include enough unchanged context for each hunk to identify one unique source region.
        Do not include prose, markdown fences, SEARCH/REPLACE markers, JSON, or changes to another file.
        Do not rewrite the entire file unless the whole file is malformed.
        """

    private static func patchTurnReminder(
        _ maximumPatchBlocks: Int,
        format: ToolSourcePatchFormat
    ) -> String {
        switch format {
        case .searchReplace:
            return """
            Return at most \(max(1, maximumPatchBlocks)) search/replace patch block(s).
            Follow the search/replace patch output contract from your instructions.
            """
        case .unifiedDiff:
            return """
            Return at most \(max(1, maximumPatchBlocks)) unified diff hunk(s).
            Follow the unified diff output contract from your instructions.
            """
        }
    }

    private static func editPatchRequest(for format: ToolSourcePatchFormat) -> String {
        switch format {
        case .searchReplace:
            return "Edit ContentView.swift by returning search/replace patch blocks only."
        case .unifiedDiff:
            return "Edit ContentView.swift by returning a unified diff only."
        }
    }

    private static func repairPatchRequest(for format: ToolSourcePatchFormat) -> String {
        switch format {
        case .searchReplace:
            return "Return only search/replace patch blocks."
        case .unifiedDiff:
            return "Return only a unified diff for ContentView.swift."
        }
    }

    private static func repairPatchScopeDescription(for format: ToolSourcePatchFormat) -> String {
        switch format {
        case .searchReplace:
            return "Your search/replace patch may edit any part of ContentView.swift needed to repair the listed diagnostics."
        case .unifiedDiff:
            return "Your unified diff may edit any part of ContentView.swift needed to repair the listed diagnostics."
        }
    }

    private static func previousPatchFailureSection(_ failure: String?) -> String {
        guard let failure = failure?.trimmingCharacters(in: .whitespacesAndNewlines),
              !failure.isEmpty
        else {
            return ""
        }
        return """
        Previous patch attempt failed:
        \(failure)
        Only patch the current authoritative source below.
        """
    }

    private static let validSearchReplaceShapeExample = """
        Valid response shape example (format only; do not copy this content):
        <<<<<<< SEARCH
            Text("Old")
        =======
            Text("New")
        >>>>>>> REPLACE
        """

    private static let validUnifiedDiffShapeExample = """
        Valid response shape example (format only; do not copy this content):
        --- a/ContentView.swift
        +++ b/ContentView.swift
        @@ -1,3 +1,3 @@
         struct ContentView: View {
        -    let title = "Old"
        +    let title = "New"
         }
        """

    private static func repairExcerptsText(_ snippets: [ContentViewRepairSnippet]) -> String {
        snippets
            .map { snippet in
                """
                Lines \(snippet.startLine)-\(snippet.endLine):
                ```swift
                \(snippet.text)
                ```
                """
            }
            .joined(separator: "\n\n")
    }

    private static func formattedDiagnostics(_ diagnostics: [SwiftCompilerDiagnostic]) -> String {
        diagnostics
            .map { diagnostic in
                var lines = [
                    "Line \(diagnostic.line), column \(diagnostic.column), \(diagnostic.severity.rawValue): \(diagnostic.message)"
                ]
                if !diagnostic.supportingLines.isEmpty {
                    lines.append("Context:")
                    lines.append(contentsOf: diagnostic.supportingLines)
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n\n")
    }

}
