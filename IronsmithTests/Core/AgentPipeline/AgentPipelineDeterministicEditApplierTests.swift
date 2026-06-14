import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func applyValidatedEditAllowsRepeatedTextOutsideTargetSnippet() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    TextField("Principal", value: $principal, format: .number, onCommit: calculateMortgage)
                    TextField("Interest", value: $interest, format: .number, onCommit: calculateMortgage)
                }
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 6, radius: 0)
        let patch = ContentViewDeterministicEdit(
            operation: .replaceLine,
            target: "            TextField(\"Principal\", value: $principal, format: .number, onCommit: calculateMortgage)",
            replacement: "            TextField(\"Principal\", value: $principal, format: .number)",
            section: nil
        )

        let updated = try ContentViewRepairSupport.applyValidatedEdit(
            patch,
            to: source,
            snippet: snippet
        )

        #expect(updated.contains("TextField(\"Principal\", value: $principal, format: .number)"))
        #expect(updated.contains("TextField(\"Interest\", value: $interest, format: .number, onCommit: calculateMortgage)"))
    }

    @Test
    func applyValidatedDeterministicEditsAppliesMultipleUniqueEdits() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    TextField("Principal", value: $principal, format: .number, onCommit: calculateMortgage)
                    TextField("Interest", value: $interest, format: .number, onCommit: calculateMortgage)
                }
            }
        }
        """
        let edits = [
            ContentViewDeterministicEdit(
                operation: .replaceLine,
                target: "            TextField(\"Principal\", value: $principal, format: .number, onCommit: calculateMortgage)",
                replacement: "            TextField(\"Principal\", value: $principal, format: .number)",
                section: nil
            ),
            ContentViewDeterministicEdit(
                operation: .replaceLine,
                target: "            TextField(\"Interest\", value: $interest, format: .number, onCommit: calculateMortgage)",
                replacement: "            TextField(\"Interest\", value: $interest, format: .number)",
                section: nil
            )
        ]

        let updated = try ContentViewRepairSupport.applyValidatedDeterministicEdits(edits, to: source)

        #expect(updated.contains("TextField(\"Principal\", value: $principal, format: .number)"))
        #expect(updated.contains("TextField(\"Interest\", value: $interest, format: .number)"))
        #expect(!(updated.contains("onCommit")))
    }

    @Test
    func applyValidatedDeterministicEditsRejectsAmbiguousFindText() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("One")
                    Text("Two")
                }
            }
        }
        """
        let edits = [
            ContentViewDeterministicEdit(
                operation: .replaceLine,
                target: "Text(",
                replacement: "Label(",
                section: nil
            )
        ]

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
            try ContentViewRepairSupport.applyValidatedDeterministicEdits(edits, to: source)
        }
    }

    @Test
    func applyValidatedDeterministicEditsStripsProseLeakingIntoPatchFields() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let edits = [
            ContentViewDeterministicEdit(
                operation: .replaceLine,
                target: "Text(\"One\")",
                replacement: "Text(\"Two\") // The best fix is to keep this line",
                section: nil
            )
        ]

        let updated = try ContentViewRepairSupport.applyValidatedDeterministicEdits(edits, to: source)

        #expect(updated.contains("Text(\"Two\")"))
        #expect(!(updated.contains("The best fix")))
    }

    @Test
    func applyValidatedDeterministicEditsStripsCommentRationaleInPatchFields() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let edits = [
            ContentViewDeterministicEdit(
                operation: .replaceLine,
                target: "Text(\"One\")",
                replacement: "Text(\"Two\") // keep this",
                section: nil
            )
        ]

        let updated = try ContentViewRepairSupport.applyValidatedDeterministicEdits(edits, to: source)

        #expect(updated.contains("Text(\"Two\")"))
        #expect(!(updated.contains("keep this")))
    }

    @Test
    func applyValidatedDeterministicEditsStripsFencedCodeFromPatchFields() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let edits = [
            ContentViewDeterministicEdit(
                operation: .replaceLine,
                target: """
                ```swift
                Text("One")
                ```
                """,
                replacement: """
                ```swift
                Text("Two")
                ```
                """,
                section: nil
            )
        ]

        let updated = try ContentViewRepairSupport.applyValidatedDeterministicEdits(edits, to: source)

        #expect(updated.contains("Text(\"Two\")"))
        #expect(!(updated.contains("```")))
    }

    @Test
    func applyValidatedDeterministicEditsAppliesMultipleSectionEditsAfterEarlierLineDeletion() throws {
        let source = """
        import AppKit

        final class KeyView: NSView {
          var onKeyDown: ((String) -> Void)?
          var onKeyUp: ((String) -> Void)?

          override func keyDown(with event: NSEvent) {
            onKeyDown?(event.keyEquivalent)
            if let chars = event.charactersIgnoringModifiers {
              onKeyDown?(chars)
            }
          }

          override func keyUp(with event: NSEvent) {
            onKeyUp?(event.keyEquivalent)
            if let chars = event.charactersIgnoringModifiers {
              onKeyUp?(chars)
            }
          }
        }
        """
        let edits = [
            ContentViewDeterministicEdit(
                operation: .replaceSection,
                target: """
                    override func keyDown(with event: NSEvent) {
                        onKeyDown?(event.keyEquivalent)
                        if let chars = event.charactersIgnoringModifiers {
                            onKeyDown?(chars)
                        }
                    }
                """,
                replacement: """
                    override func keyDown(with event: NSEvent) {
                        if let chars = event.charactersIgnoringModifiers {
                            onKeyDown?(chars)
                        }
                    }
                """,
                section: "Helpers"
            ),
            ContentViewDeterministicEdit(
                operation: .replaceSection,
                target: """
                    override func keyUp(with event: NSEvent) {
                        onKeyUp?(event.keyEquivalent)
                        if let chars = event.charactersIgnoringModifiers {
                            onKeyUp?(chars)
                        }
                    }
                """,
                replacement: """
                    override func keyUp(with event: NSEvent) {
                        if let chars = event.charactersIgnoringModifiers {
                            onKeyUp?(chars)
                        }
                    }
                """,
                section: "Helpers"
            )
        ]

        let updated = try ContentViewRepairSupport.applyValidatedDeterministicEdits(edits, to: source)

        #expect(!(updated.contains("keyEquivalent")))
        #expect(updated.contains("onKeyDown?(chars)"))
        #expect(updated.contains("onKeyUp?(chars)"))
    }

    @Test
    func applyValidatedDeterministicEditsRejectsPlaceholderPatchFields() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let edits = [
            ContentViewDeterministicEdit(
                operation: .addImport,
                target: "placeholder",
                replacement: "placeholder",
                section: "placeholder"
            )
        ]

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
            try ContentViewRepairSupport.applyValidatedDeterministicEdits(edits, to: source)
        }
    }

    @Test
    func deterministicRepairSpacesOneSidedIfComparisonOperators() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            private func updateGame() {
                var newPos = CGPoint(x: 1, y: 1)
                if newPos.x< 0 {
                    resetBall()
                }
            }

            private func resetBall() {}
        }
        """
        let line = try #require(source.components(separatedBy: .newlines).firstIndex { $0.contains("newPos.x< 0") }).advanced(by: 1)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/Demo/ContentView.swift",
            line: line,
            column: 22,
            severity: .error,
            message: "expected '{' after 'if' condition",
            supportingLines: []
        )

        let repair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: diagnostic,
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: line)
        ))

        #expect(repair.name == "ifConditionOperatorSpacingFix")
        #expect(repair.edit.target == "        if newPos.x< 0 {")
        #expect(repair.edit.replacement == "        if newPos.x < 0 {")
    }

    @Test
    func applyValidatedDeterministicEditsAllowsReplacingExistingPlaceholderSource() throws {
        let source = """
        import SwiftUI
        import placeholder

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 2)
        let edits = [
            ContentViewDeterministicEdit(
                operation: .replaceLine,
                target: "import placeholder",
                replacement: "",
                section: nil
            )
        ]

        let updated = try ContentViewRepairSupport.applyValidatedDeterministicEdits(edits, to: source, snippets: [snippet])

        #expect(!(updated.contains("import placeholder")))
    }

    @Test
    func applyValidatedDeterministicEditsAllowsDeterministicWholeSourceSectionReplacement() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Generated Tool")
            }

            // MARK: - Helpers
            var body: some View {
                VStack {
                    Text("Second")
                }
            }
        }
        """
        let target = """
            var body: some View {
                VStack {
                    Text("Second")
                }
            }
        """
        let snippet = ContentViewRepairSnippet(
            startLine: 4,
            endLine: 6,
            text: """
            var body: some View {
                Text("Generated Tool")
            }
            """
        )
        let edits = [
            ContentViewDeterministicEdit(
                operation: .replaceSection,
                target: target,
                replacement: "",
                section: nil
            )
        ]

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
            try ContentViewRepairSupport.applyValidatedDeterministicEdits(edits, to: source, snippets: [snippet])
        }

        let updated = try ContentViewRepairSupport.applyValidatedDeterministicEdits(
            edits,
            to: source,
            snippets: [snippet],
            allowWholeSourceTargets: true
        )

        #expect(!(updated.contains("Text(\"Second\")")))
        #expect(updated.components(separatedBy: "var body: some View").count == 2)
    }

    @Test
    func applyValidatedDeterministicEditsRejectsOperationsOutsideDirective() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            // MARK: - Helpers
        }
        """
        let edits = [
            ContentViewDeterministicEdit(
                operation: .addImport,
                target: "Foundation",
                replacement: "import Foundation",
                section: nil
            )
        ]

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
            try ContentViewRepairSupport.applyValidatedDeterministicEdits(
                edits,
                to: source,
                snippets: [ContentViewRepairSnippet(startLine: 1, endLine: 5, text: source)],
                allowedOperations: [.addHelperFunction],
                maximumEdits: 1
            )
        }
    }

    @Test
    func typedRepairOperationsCanAddImportsStateHelpersAndRenameInSection() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            // MARK: - State
            @State private var input = ""

            // MARK: - Body
            var body: some View {
                Text(input)
            }

            // MARK: - Helpers
        }
        """

        let firstPass = [
            ContentViewDeterministicEdit(
                operation: .addImport,
                target: "AppKit",
                replacement: "import AppKit",
                section: nil
            ),
            ContentViewDeterministicEdit(
                operation: .addStateProperty,
                target: "State",
                replacement: "@State private var output = \"\"",
                section: "State"
            ),
            ContentViewDeterministicEdit(
                operation: .addHelperFunction,
                target: "Helpers",
                replacement: "private func copyOutput() {\n    NSPasteboard.general.setString(output, forType: .string)\n}",
                section: "Helpers"
            )
        ]
        let secondPass = [
            ContentViewDeterministicEdit(
                operation: .renameIdentifierInSection,
                target: "input",
                replacement: "output",
                section: "Body"
            )
        ]

        let intermediate = try ContentViewRepairSupport.applyValidatedDeterministicEdits(firstPass, to: source, maximumEdits: 3)
        let updated = try ContentViewRepairSupport.applyValidatedDeterministicEdits(secondPass, to: intermediate, maximumEdits: 1)

        #expect(updated.contains("import AppKit"))
        #expect(updated.contains("@State private var output = \"\""))
        #expect(updated.contains("private func copyOutput()"))
        #expect(updated.contains("Text(output)"))
        #expect(updated.contains("@State private var input = \"\""))
    }

    @Test
    func applyValidatedEditCanTargetOneRepeatedLineInsideSnippet() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    TextField("Principal", value: $principal, format: .number)
                        .keyboardType(.decimalPad)
                    TextField("Rate", value: $rate, format: .number)
                        .keyboardType(.decimalPad)
                }
            }
        }
        """
        let lines = source.components(separatedBy: .newlines)
        let snippet = ContentViewRepairSnippet(
            startLine: 6,
            endLine: 7,
            text: [lines[5], lines[6]].joined(separator: "\n")
        )
        let patch = ContentViewDeterministicEdit(
            operation: .replaceLine,
            target: lines[6],
            replacement: "",
            section: nil
        )

        let updated = try ContentViewRepairSupport.applyValidatedEdit(
            patch,
            to: source,
            snippet: snippet
        )

        #expect(updated.contains("TextField(\"Principal\", value: $principal, format: .number)\n"))
        #expect(updated.contains("TextField(\"Rate\", value: $rate, format: .number)\n                .keyboardType(.decimalPad)"))
    }

    @Test
    func applyValidatedEditCanUseTrimmedLineFromSnippet() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("One")
                    Text("Two")
                }
            }
        }
        """
        let lines = source.components(separatedBy: .newlines)
        let snippet = ContentViewRepairSnippet(
            startLine: 6,
            endLine: 6,
            text: lines[5]
        )
        let patch = ContentViewDeterministicEdit(
            operation: .replaceLine,
            target: "Text(\"One\")",
            replacement: "Label(\"One\", systemImage: \"1.circle\")",
            section: nil
        )

        let updated = try ContentViewRepairSupport.applyValidatedEdit(
            patch,
            to: source,
            snippet: snippet
        )

        let updatedLine = try #require(updated.components(separatedBy: .newlines).first {
            $0.contains("Label(\"One\", systemImage: \"1.circle\")")
        })
        let originalIndentation = String(lines[5].prefix { $0 == " " || $0 == "\t" })
        #expect(updatedLine.hasPrefix(originalIndentation))
        #expect(updatedLine.trimmingCharacters(in: .whitespaces) == "Label(\"One\", systemImage: \"1.circle\")")
        #expect(updated.contains("Text(\"Two\")"))
    }

    @Test
    func applyValidatedEditCanUseIndentFlexibleSectionFromSnippet() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            private func calculate() {
                let numberOfPayments = Double(years) * 12
                for _ in 0..<numberOfPayments {
                    payment += 1
                }
            }
        }
        """
        let lines = source.components(separatedBy: .newlines)
        let snippet = ContentViewRepairSnippet(
            startLine: 5,
            endLine: 8,
            text: Array(lines[4...7]).joined(separator: "\n")
        )
        let patch = ContentViewDeterministicEdit(
            operation: .replaceSection,
            target: """
            let numberOfPayments = Double(years) * 12
            for _ in 0..<numberOfPayments {
                payment += 1
            }
            """,
            replacement: """
                let numberOfPayments = Int(Double(years) * 12)
                for _ in 0..<numberOfPayments {
                    payment += 1
                }
            """,
            section: nil
        )

        let updated = try ContentViewRepairSupport.applyValidatedEdit(
            patch,
            to: source,
            snippet: snippet
        )

        #expect(updated.contains("let numberOfPayments = Int(Double(years) * 12)"))
        #expect(updated.contains("for _ in 0..<numberOfPayments"))
    }
}
