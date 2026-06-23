import Foundation

enum ToolGenerationPrompts {
    static let singleFileCodingInstructions = """
        You are Ironsmith's Coding Agent.
        Write exactly one complete Swift file named ContentView.swift for a SwiftUI app based on the user's request.
        Return only Swift source code.
        Do not add comments except for MARK.
        Do not add introductions, explanations, or labels like "Here is the fixed ContentView.swift file:".
        Define exactly one View-conforming type: struct ContentView: View.
        Helper types are allowed, but helper types must not conform to App.
        Keep state directly inside ContentView with @State properties.
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
        If what the user asks is too complicated, simplify it so it fits in the ContentView.
        Prefer Apple platform frameworks and native APIs when they fit the request, such as Vision for OCR, PDFKit for PDFs, AVFoundation for media etc.
        Use these stable sections when possible:
        // MARK: - State
        // MARK: - Body
        // MARK: - Actions
        // MARK: - Helpers
        """

    static let diffRepairInstructions = """
        You are Ironsmith's Swift compiler repair agent.
        You repair exactly one file: ContentView.swift.
        \(diffOutputContract)
        \(validUnifiedDiffShapeExample)
        Keep each repair turn focused on the listed compiler diagnostics.
        """

    static let diffEditInstructions = """
        You are Ironsmith's Swift edit agent.
        You edit exactly one file: ContentView.swift.
        \(diffOutputContract)
        \(validUnifiedDiffShapeExample)
        Keep the edit focused on the user's requested change.
        Prefer several small, focused hunks over one large hunk when multiple areas need changes.
        """

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

    static func singleFileEditDiffPrompt(
        userPrompt: String,
        executableName: String,
        existingSource: String,
        maximumDiffHunks: Int?
    ) -> String {
        """
        User request: \(userPrompt)
        Fixed package and target name: \(executableName).
        Edit ContentView.swift by returning a unified diff only.
        \(diffTurnReminder(maximumDiffHunks))
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

    static func diffContinuationPrompt(
        originalPrompt: String,
        partialDiff: String
    ) -> String {
        """
        Continue the exact unified diff response that was interrupted.
        Return only the next characters of the diff.
        Do not repeat any text from the partial diff.
        Do not include markdown fences, explanations, or labels.

        Original request context:
        \(originalPrompt)

        Partial unified diff already generated that needs to be completed:
        ```diff
        \(partialDiff)
        ```
        """
    }

    static func conversationalRepairPrompt(
        diagnostics: [SwiftCompilerDiagnostic],
        source: String?,
        editableSnippets: [ContentViewRepairSnippet] = [],
        previousOutcome: String?,
        compactionSummary: String?,
        maximumDiffHunks: Int?
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
                Your diff may edit any part of ContentView.swift needed to repair the listed diagnostics.
                """
            )
        }

        sections.append(
            """
            Return only a unified diff.
            \(diffTurnReminder(maximumDiffHunks))
            Do not reuse removed source from previous repair outcomes.
            Make one coherent repair step, then stop.
            """
        )

        return sections.joined(separator: "\n\n")
    }

    private static let diffOutputContract = """
        Return only a unified diff.
        The diff must edit ContentView.swift only.
        Use normal unified diff hunks with @@ headers and enough surrounding context to locate each edit uniquely.
        Every @@ hunk must include at least one real + or - changed line; do not use @@ as an ellipsis or section separator.
        Do not include prose, markdown fences, JSON, explanations, or unrelated rewrites in the diff.
        Do not include apply-patch markers such as *** Begin Patch or *** End Patch.
        Do not rewrite the entire file unless the whole file is malformed.
        """

    private static func diffTurnReminder(_ maximumDiffHunks: Int?) -> String {
        """
        \(diffHunkLimitInstruction(maximumDiffHunks))
        Follow the diff output contract from your instructions.
        """
    }

    private static func diffHunkLimitInstruction(_ maximumDiffHunks: Int?) -> String {
        if let maximumDiffHunks {
            return "Return at most \(maximumDiffHunks) unified diff hunk(s)."
        }
        return "Use as many unified diff hunks as needed."
    }

    private static let validUnifiedDiffShapeExample = """
        Valid response shape example (format only; do not copy this content):
        --- ContentView.swift
        +++ ContentView.swift
        @@ -3,5 +3,5 @@
        -    Text("Old")
        +    Text("New")
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
