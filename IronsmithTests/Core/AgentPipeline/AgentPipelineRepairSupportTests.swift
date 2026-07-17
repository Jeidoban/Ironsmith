import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func contentViewRepairSupportMakesExtraArgumentEdit() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Stepper(value: $loanAmount, in: 0.0...1e9, step: 10000, onIncrement: {
                    self.loanAmount += 10000
                }, onDecrement: {
                    self.loanAmount -= 10000
                })
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 6)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 6,
            column: 23,
            severity: .error,
            message: "extra argument 'onDecrement' in call",
            supportingLines: []
        )

        let edit = ContentViewRepairSupport.makeDeterministicEdit(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(edit != nil)
        #expect(edit?.operation == .replaceSection)
        #expect(edit?.replacement == "")
    }

    @Test
    func contentViewRepairSupportMakesInlineExtraArgumentEdit() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            @State private var monthlyPayment: Double = 0.0

            var body: some View {
                VStack {
                    TextField("Monthly Payment", text: $monthlyPayment, key: "monthlyPayment", onCommit: {
                        computeMonthlyPayment()
                    })
                }
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 8)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 8,
            column: 70,
            severity: .error,
            message: "extra argument 'key' in call",
            supportingLines: []
        )

        let edit = ContentViewRepairSupport.makeDeterministicEdit(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(edit?.operation == .replaceLine)
        #expect(edit?.target.contains(#"key: "monthlyPayment""#) == true)
        #expect(!(edit?.replacement.contains(#"key: "monthlyPayment""#) ?? false))
        #expect(edit?.replacement.contains("onCommit") == true)
    }

    @Test
    func contentViewRepairSupportRemovesWeakSelfAndOptionalSelfInCallback() {
        let source = """
        import SwiftUI
        import Foundation

        struct ContentView: View {
            @State private var htmlContent: String = "Loading..."
            @State private var isLoading: Bool = false
            @State private var errorMessage: String? = nil

            var body: some View {
                Text(htmlContent)
            }

            private func fetchHTML() {
                guard let url = URL(string: "https://example.com") else {
                    return
                }

                let task = URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
                    DispatchQueue.main.async {
                        self?.isLoading = false
                        if let error = error {
                            self?.errorMessage = error.localizedDescription
                            return
                        }
                        guard let data = data,
                            let string = String(data: data, encoding: .utf8)
                        else {
                            self?.errorMessage = "Failed to decode response"
                            return
                        }
                        self?.htmlContent = string
                    }
                }
                task.resume()
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 18)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 18,
            column: 62,
            severity: .error,
            message: "'weak' may only be applied to class and class-bound protocol types, not 'ContentView'",
            supportingLines: []
        )

        let repair = ContentViewRepairSupport.makeDeterministicRepair(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(repair?.name == "weakSelfCaptureInValueViewFix")
        #expect(repair?.edit.operation == .replaceSection)
        #expect(repair?.edit.target.contains("[weak self]") == true)
        #expect(!(repair?.edit.replacement.contains("[weak self]") ?? false))
        #expect(!(repair?.edit.replacement.contains("self?.") ?? false))
        #expect(repair?.edit.replacement.contains("self.errorMessage = \"Failed to decode response\"") == true)
    }

    @Test
    func contentViewRepairSupportRewritesOptionalSelfAcrossCurrentClosure() {
        let source = """
        import SwiftUI
        import Foundation

        struct ContentView: View {
            @State private var htmlContent: String = "Loading..."
            @State private var isLoading: Bool = false
            @State private var errorMessage: String? = nil

            var body: some View {
                Text(htmlContent)
            }

            private func fetchHTML() {
                guard let url = URL(string: "https://example.com") else {
                    return
                }

                let task = URLSession.shared.dataTask(with: url) { [unowned self] data, response, error in
                    DispatchQueue.main.async {
                        self.isLoading = false
                        if let error = error {
                            self.errorMessage = error.localizedDescription
                            return
                        }
                        guard let data = data,
                            let string = String(data: data, encoding: .utf8)
                        else {
                            self?.errorMessage = "Failed to decode response"
                            return
                        }
                        self?.htmlContent = string
                    }
                }
                task.resume()
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 28)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 28,
            column: 15,
            severity: .error,
            message: "cannot use optional chaining on non-optional value of type 'ContentView'",
            supportingLines: []
        )

        let repair = ContentViewRepairSupport.makeDeterministicRepair(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(repair?.name == "nonOptionalContentViewSelfFix")
        #expect(repair?.edit.operation == .replaceSection)
        #expect(repair?.edit.target.contains("DispatchQueue.main.async {") == true)
        #expect(!(repair?.edit.replacement.contains("self?.") ?? false))
        #expect(repair?.edit.replacement.contains("self.errorMessage = \"Failed to decode response\"") == true)
        #expect(repair?.edit.replacement.contains("self.htmlContent = string") == true)
    }

    @Test
    func contentViewRepairSupportRemovesInvalidImport() {
        let source = """
        import SwiftUI
        import placeholder

        struct ContentView: View {
            var body: some View {
                Text("Generated Tool")
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 2)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 2,
            column: 8,
            severity: .error,
            message: "no such module 'placeholder'",
            supportingLines: []
        )

        let edit = ContentViewRepairSupport.makeDeterministicEdit(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(edit?.operation == .replaceLine)
        #expect(edit?.target == "import placeholder")
        #expect(edit?.replacement == "")
    }

    @Test
    func contentViewRepairSupportConvertsInvalidObservedObjectToState() {
        let source = """
        import SwiftUI

        struct MortgageLoan {
            var amount = 0.0
        }

        struct ContentView: View {
            @ObservedObject var mortgageLoan = MortgageLoan()

            var body: some View {
                Text("Mortgage")
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 8)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 8,
            column: 6,
            severity: .error,
            message: "generic struct 'ObservedObject' requires that 'MortgageLoan' conform to 'ObservableObject'",
            supportingLines: []
        )

        let edit = ContentViewRepairSupport.makeDeterministicEdit(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(edit?.operation == .replaceLine)
        #expect(edit?.target == "    @ObservedObject var mortgageLoan = MortgageLoan()")
        #expect(edit?.replacement == "    @State var mortgageLoan = MortgageLoan()")
    }

    @Test
    func contentViewRepairSupportRemovesDuplicateBody() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("First")
            }

            var body: some View {
                Text("Second")
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 8)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 8,
            column: 9,
            severity: .error,
            message: "invalid redeclaration of 'body'",
            supportingLines: []
        )

        let edit = ContentViewRepairSupport.makeDeterministicEdit(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(edit?.operation == .replaceSection)
        #expect(edit?.target.contains("Text(\"Second\")") == true)
        #expect(edit?.replacement == "")
    }

    @Test
    func contentViewRepairSupportAddsSelfForShadowedPropertyAssignment() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            @State private var loanAmount: Double = 0.0

            private func updateUI(loanAmount: Double) {
                loanAmount = loanAmount
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 7)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 7,
            column: 9,
            severity: .error,
            message: "cannot assign to value: 'loanAmount' is a 'let' constant",
            supportingLines: [
                "`- note: add explicit 'self.' to refer to mutable property of 'ContentView'"
            ]
        )

        let edit = ContentViewRepairSupport.makeDeterministicEdit(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(edit?.operation == .replaceLine)
        #expect(edit?.target == "        loanAmount = loanAmount")
        #expect(edit?.replacement == "        self.loanAmount = loanAmount")
    }

    @Test
    func contentViewRepairSupportIncludesRelatedDeclarationSnippetForCrossRegionRepair() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            let count = 0











            var body: some View {
                Button("Tap") {
                    count += 1
                }
            }
        }
        """
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 18,
            column: 17,
            severity: .error,
            message: "left side of mutating operator isn't mutable: 'count' is a 'let' constant",
            supportingLines: []
        )
        let immediateSnippets = ContentViewRepairSupport.snippets(from: source, diagnostics: [diagnostic])
        let relatedSnippets = ContentViewRepairSupport.relatedEditableSnippets(
            from: source,
            diagnostics: [diagnostic],
            excluding: immediateSnippets
        )

        let relatedSnippet = try #require(relatedSnippets.first)
        #expect(relatedSnippet.text.contains("let count = 0"))

        let updated = try ContentViewRepairSupport.applyValidatedDeterministicEdits(
            [
                ContentViewDeterministicEdit(
                    operation: .replaceLine,
                    target: "    let count = 0",
                    replacement: "    @State private var count = 0",
                    section: nil
                )
            ],
            to: source,
            snippets: immediateSnippets + relatedSnippets,
            maximumEdits: 1
        )

        #expect(updated.contains("@State private var count = 0"))
    }

    @Test
    func singleFileCodingInstructionsKeepGeneratedAppsSelfContainedAndNativeMacOS() {
        let instructions = ToolGenerationPrompts.singleFileCodingInstructions

        #expect(instructions.contains("self-contained"))
        #expect(instructions.contains("direct internet requests allowed"))
        #expect(instructions.contains("Respect that app type when choosing scope, layout density, and sizing"))
        #expect(instructions.contains("Treat that as runtime context, not a reason to reduce useful scope"))
        #expect(instructions.contains("sandbox-compatible macOS patterns"))
        #expect(instructions.contains("use what is needed to complete the user's ask"))
        #expect(instructions.contains("Local persistence is welcome"))
        #expect(instructions.contains("local files, import/export, and open/save panels"))
        #expect(instructions.contains("Do not add or imply a separate backend service"))
        #expect(instructions.contains("backend"))
        #expect(instructions.contains("iCloud/CloudKit"))
        #expect(instructions.contains("Make the app feel native to macOS"))
        #expect(instructions.contains("Games, drawing canvases, and highly visual toys"))
        #expect(instructions.contains("Define ContentView as the root View"))
        #expect(instructions.contains("same-file helper View types are allowed"))
        #expect(instructions.contains("helper models/classes are allowed"))
        #expect(instructions.contains("Break complex SwiftUI bodies into small same-file helper views/properties"))
        #expect(!(instructions.contains("Define exactly one View-conforming type")))
    }

    @Test
    func singleFileCreatePromptDoesNotMentionResponseTokenBudget() {
        let prompt = ToolGenerationPrompts.singleFileCreatePrompt(
            userPrompt: "Build a planner",
            executableName: "Planner",
            sandboxEnabled: true
        )

        #expect(prompt.contains("User request: Build a planner"))
        #expect(prompt.contains("App sandbox: enabled."))
        #expect(prompt.contains("Build the requested app normally"))
        #expect(prompt.contains("sandbox-compatible macOS patterns"))
        #expect(prompt.contains("Generate ContentView.swift only."))
        #expect(!(prompt.contains("capped at")))
        #expect(!(prompt.contains("output tokens")))
    }

    @Test
    func singleFilePromptsIncludeAppTypeContext() {
        let menuBarCreatePrompt = ToolGenerationPrompts.singleFileCreatePrompt(
            userPrompt: "Build a timer",
            executableName: "Timer",
            sandboxEnabled: true,
            appKind: .menuBar
        )
        let menuBarEditPrompt = ToolGenerationPrompts.singleFileEditPrompt(
            userPrompt: "Make it simpler",
            executableName: "Timer",
            existingSource: "import SwiftUI\n\nstruct ContentView: View { var body: some View { Text(\"Timer\") } }"
        )
        let menuBarPatchPrompt = ToolGenerationPrompts.singleFileEditPatchPrompt(
            userPrompt: "Make it simpler",
            executableName: "Timer",
            existingSource: "import SwiftUI\n\nstruct ContentView: View { var body: some View { Text(\"Timer\") } }",
            maximumPatchBlocks: ToolGenerationRepairPolicy.smallModelPatchBlocksPerTurn
        )
        let windowCreatePrompt = ToolGenerationPrompts.singleFileCreatePrompt(
            userPrompt: "Build a planner",
            executableName: "Planner",
            sandboxEnabled: true,
            appKind: .window
        )

        #expect(menuBarCreatePrompt.contains("App type: menu bar app."))
        #expect(menuBarCreatePrompt.contains("MenuBarExtra popover-style window"))
        #expect(menuBarCreatePrompt.contains("not a regular full-size app window"))
        #expect(menuBarCreatePrompt.contains("compact menu bar utility"))
        #expect(menuBarCreatePrompt.contains("bounded width and height"))
        #expect(!(menuBarCreatePrompt.contains("Avoid full-app layouts")))

        for prompt in [menuBarEditPrompt, menuBarPatchPrompt] {
            #expect(!(prompt.contains("App type: menu bar app.")))
            #expect(!(prompt.contains("MenuBarExtra popover-style window")))
            #expect(!(prompt.contains("compact menu bar utility")))
        }

        #expect(windowCreatePrompt.contains("App type: window app."))
        #expect(windowCreatePrompt.contains("normal macOS WindowGroup"))
        #expect(windowCreatePrompt.contains("native desktop layout sized for a regular app window"))
    }

    @Test
    func singleFileCreatePromptIncludesUnsandboxedContext() {
        let prompt = ToolGenerationPrompts.singleFileCreatePrompt(
            userPrompt: "Build a file organizer",
            executableName: "FileOrganizer",
            sandboxEnabled: false
        )

        #expect(prompt.contains("App sandbox: disabled."))
        #expect(prompt.contains("may use what it needs to complete the user's ask"))
        #expect(prompt.contains("must not make changes to the user's system unless the user asks"))
    }

    @Test
    func searchReplaceInstructionsIncludeValidPatchShapeExample() {
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 4,
            column: 9,
            severity: .error,
            message: "cannot find 'title' in scope",
            supportingLines: []
        )
        let editPrompt = ToolGenerationPrompts.singleFileEditPatchPrompt(
            userPrompt: "Rename a label",
            executableName: "GeneratedTool",
            existingSource: "import SwiftUI\n\nstruct ContentView: View { var body: some View { Text(\"Old\") } }",
            maximumPatchBlocks: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn
        )
        let repairPrompt = ToolGenerationPrompts.conversationalRepairPrompt(
            diagnostics: [diagnostic],
            source: nil,
            previousOutcome: nil,
            compactionSummary: nil,
            maximumPatchBlocks: 1
        )
        let prompts = [
            ToolGenerationPrompts.searchReplaceEditInstructions,
            ToolGenerationPrompts.searchReplaceRepairInstructions,
        ]

        for prompt in prompts {
            #expect(prompt.contains("Valid response shape example"))
            #expect(prompt.contains("<<<<<<< SEARCH"))
            #expect(prompt.contains("<<<<<<< INSERT_BEFORE"))
            #expect(prompt.contains("<<<<<<< INSERT_AFTER"))
            #expect(prompt.contains("======="))
            #expect(prompt.contains(">>>>>>> REPLACE"))
            #expect(prompt.contains(">>>>>>> INSERT"))
            #expect(prompt.contains("Text(\"Old\")"))
            #expect(prompt.contains("Text(\"New\")"))
            #expect(prompt.contains("SEARCH text must be non-empty"))
            #expect(prompt.contains("Do not include apply-patch markers"))
            #expect(prompt.contains("Do not rewrite the entire file unless the whole file is malformed"))
        }
        #expect(!(editPrompt.contains("Valid response shape example")))
        #expect(!(repairPrompt.contains("Valid response shape example")))
        #expect(editPrompt.contains("Follow the search/replace patch output contract from your instructions."))
        #expect(repairPrompt.contains("Follow the search/replace patch output contract from your instructions."))
        #expect(!(editPrompt.contains("SEARCH text must be non-empty")))
        #expect(!(repairPrompt.contains("SEARCH text must be non-empty")))
        #expect(!(editPrompt.contains("Do not include apply-patch markers")))
        #expect(!(repairPrompt.contains("Do not include apply-patch markers")))
    }

    @Test
    func unifiedDiffInstructionsAndTurnPromptsUseDiffsForSpark() {
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 4,
            column: 9,
            severity: .error,
            message: "cannot find 'title' in scope",
            supportingLines: []
        )
        let editPrompt = ToolGenerationPrompts.singleFileEditPatchPrompt(
            userPrompt: "Rename a label",
            executableName: "GeneratedTool",
            existingSource: "struct ContentView {}",
            maximumPatchBlocks: 1,
            patchFormat: .unifiedDiff
        )
        let repairPrompt = ToolGenerationPrompts.conversationalRepairPrompt(
            diagnostics: [diagnostic],
            source: nil,
            previousOutcome: nil,
            compactionSummary: nil,
            maximumPatchBlocks: 2,
            patchFormat: .unifiedDiff
        )

        for instructions in [
            ToolGenerationPrompts.unifiedDiffEditInstructions,
            ToolGenerationPrompts.unifiedDiffRepairInstructions,
        ] {
            #expect(instructions.contains("Return only a unified diff that updates ContentView.swift"))
            #expect(instructions.contains("Hunk range numbers may be approximate"))
            #expect(instructions.contains("--- a/ContentView.swift"))
            #expect(instructions.contains("@@ -1,3 +1,3 @@"))
        }
        #expect(editPrompt.contains("Edit ContentView.swift by returning a unified diff only."))
        #expect(editPrompt.contains("Return at most 1 unified diff hunk(s)."))
        #expect(repairPrompt.contains("Return only a unified diff for ContentView.swift."))
        #expect(repairPrompt.contains("Return at most 2 unified diff hunk(s)."))
    }

    @Test
    func conversationalRepairPromptRendersRelevantCurrentExcerpts() {
        let snippet = ContentViewRepairSnippet(
            startLine: 10,
            endLine: 14,
            text: """
            private func handleKey(_ press: KeyPress) -> KeyPress.Result {
              switch press.key {
              case .character("w"):
                return .handled
              }
            }
            """
        )
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 12,
            column: 9,
            severity: .error,
            message: "instance member 'character' cannot be used on type 'KeyEquivalent'",
            supportingLines: []
        )

        let prompt = ToolGenerationPrompts.conversationalRepairPrompt(
            diagnostics: [diagnostic],
            source: nil,
            editableSnippets: [snippet],
            previousOutcome: "accepted; ContentView error count 13 -> 9",
            compactionSummary: nil,
            maximumPatchBlocks: 3
        )

        #expect(prompt.contains("Relevant current excerpts from authoritative ContentView.swift"))
        #expect(prompt.contains("These excerpts are context hints, not edit boundaries"))
        #expect(prompt.contains("Your search/replace patch may edit any part of ContentView.swift"))
        #expect(prompt.contains("Lines 10-14"))
        #expect(prompt.contains("case .character(\"w\")"))
        #expect(prompt.contains("Do not reuse removed source from previous repair outcomes"))
        #expect(!(prompt.contains("Current authoritative ContentView.swift")))
    }

    @Test
    func conversationalRepairPromptCapsPatchBlocks() {
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 12,
            column: 9,
            severity: .error,
            message: "cannot find 'value' in scope",
            supportingLines: []
        )

        let prompt = ToolGenerationPrompts.conversationalRepairPrompt(
            diagnostics: [diagnostic],
            source: nil,
            previousOutcome: nil,
            compactionSummary: nil,
            maximumPatchBlocks: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn
        )

        #expect(prompt.contains("Return at most \(ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn) search/replace patch block(s)."))
    }

    @Test
    func conversationalRepairPromptAddsTypeCheckTimeoutGuidance() {
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 40,
            column: 17,
            severity: .error,
            message: "the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions",
            supportingLines: []
        )

        let prompt = ToolGenerationPrompts.conversationalRepairPrompt(
            diagnostics: [diagnostic],
            source: nil,
            previousOutcome: nil,
            compactionSummary: nil,
            maximumPatchBlocks: 1
        )

        #expect(prompt.contains("SwiftUI type-checker note"))
        #expect(prompt.contains("reported line is often only where inference gave up"))
        #expect(prompt.contains("same-file helper views/properties"))
    }

    @Test
    func enclosingEditableBlockSnippetIncludesWholeClosureBeyondLineWindow() throws {
        let source = """
        import SwiftUI
        import Foundation

        struct ContentView: View {
            @State private var htmlContent = ""
            @State private var errorMessage: String? = nil

            private func fetchHTML() {
                guard let url = URL(string: "https://example.com") else {
                    return
                }

                let task = URLSession.shared.dataTask(with: url) { data, response, error in
                    DispatchQueue.main.async {
                        let line1 = htmlContent
                        let line2 = line1
                        let line3 = line2
                        let line4 = line3
                        let line5 = line4
                        let line6 = line5
                        let line7 = line6
                        let line8 = line7
                        self?.errorMessage = error?.localizedDescription
                        let line9 = line8
                        let line10 = line9
                        let line11 = line10
                        let line12 = line11
                        let line13 = line12
                        self?.htmlContent = line13
                    }
                }
                task.resume()
            }
        }
        """
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 23,
            column: 17,
            severity: .error,
            message: "cannot use optional chaining on non-optional value of type 'ContentView'",
            supportingLines: []
        )
        let immediateSnippets = ContentViewRepairSupport.snippets(from: source, diagnostics: [diagnostic])

        let blockSnippet = try #require(
            ContentViewRepairSupport.enclosingEditableBlockSnippets(
                from: source,
                diagnostics: [diagnostic],
                excluding: immediateSnippets
            ).first
        )

        #expect(blockSnippet.text.contains("DispatchQueue.main.async {"))
        #expect(blockSnippet.text.contains("self?.errorMessage = error?.localizedDescription"))
        #expect(blockSnippet.text.contains("self?.htmlContent = line13"))
        #expect(!(immediateSnippets.first?.text.contains("DispatchQueue.main.async {") ?? false))
    }

    @Test
    func typeCheckTimeoutBlockSnippetPrefersContainingViewBuilderBlock() throws {
        let rows = (1...35)
            .map { #"                Text("Line \#($0)")"# }
            .joined(separator: "\n")
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
        \(rows)
                }
            }
        }
        """
        let diagnosticLine = try #require(
            source.components(separatedBy: .newlines).firstIndex { $0.contains(#"Text("Line 24")"#) }
        ) + 1
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: diagnosticLine,
            column: 17,
            severity: .error,
            message: "the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions",
            supportingLines: []
        )
        let immediateSnippets = ContentViewRepairSupport.snippets(from: source, diagnostics: [diagnostic])

        let blockSnippet = try #require(
            ContentViewRepairSupport.enclosingEditableBlockSnippets(
                from: source,
                diagnostics: [diagnostic],
                excluding: immediateSnippets
            ).first
        )

        #expect(blockSnippet.text.contains("var body: some View"))
        #expect(blockSnippet.text.contains(#"Text("Line 1")"#))
        #expect(blockSnippet.text.contains(#"Text("Line 35")"#))
        #expect(!(immediateSnippets.first?.text.contains(#"Text("Line 1")"#) ?? false))
    }

    @Test
    func contentViewRepairSupportAddsIdentifiableIDProperty() {
        let source = """
        import SwiftUI

        struct MortgageCalculator: Identifiable {
            var principalBalance: Double = 0.0
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 3)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 3,
            column: 8,
            severity: .error,
            message: "type 'MortgageCalculator' does not conform to protocol 'Identifiable'",
            supportingLines: []
        )

        let edit = ContentViewRepairSupport.makeDeterministicEdit(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(edit?.operation == .replaceLine)
        #expect(edit?.target == "struct MortgageCalculator: Identifiable {")
        #expect(edit?.replacement == "struct MortgageCalculator: Identifiable {\n  let id = UUID()")
    }
}
