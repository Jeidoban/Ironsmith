import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func contentViewRepairSupportRemovesUnsupportedKeyboardTypeModifier() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            @State private var principalAmount: Double = 0

            var body: some View {
                VStack {
                    TextField("Principal Amount", value: $principalAmount, format: .number)
                        .keyboardType(.decimalPad)
                        .padding()
                }
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 8)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 9,
            column: 10,
            severity: .error,
            message: "value of type 'TextField<Text>' has no member 'keyboardType'",
            supportingLines: []
        )

        let edit = ContentViewRepairSupport.makeDeterministicEdit(
            for: diagnostic,
            source: source,
            snippet: snippet
        )

        #expect(edit?.operation == .replaceSection)
        #expect(edit?.target.contains("TextField(\"Principal Amount\"") == true)
        #expect(edit?.target.contains(".keyboardType(.decimalPad)") == true)
        #expect(edit?.replacement == "            TextField(\"Principal Amount\", value: $principalAmount, format: .number)")
    }

    @Test
    func contentViewRepairSupportRemovesBareUnsupportedKeyboardTypeCall() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            @State private var principal: Double = 0

            var body: some View {
                VStack {
                    TextField("Principal", value: $principal, format: .number)
                        keyboardType(.numberPad)
                }
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 9)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 9,
            column: 25,
            severity: .error,
            message: "cannot find 'keyboardType' in scope",
            supportingLines: []
        )

        let edit = try #require(
            ContentViewRepairSupport.makeDeterministicEdit(
                for: diagnostic,
                source: source,
                snippet: snippet
            )
        )
        let updated = try ContentViewRepairSupport.applyValidatedEdit(
            edit,
            to: source,
            snippet: snippet
        )

        #expect(!(updated.contains("keyboardType(")))
        #expect(updated.contains("TextField(\"Principal\", value: $principal, format: .number)"))
    }

    @Test
    func contentViewRepairSupportRemovesOnlyTargetKeyboardTypeModifierWhenRepeated() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            @State private var loanAmount: Double = 0
            @State private var interestRate: Double = 0

            var body: some View {
                VStack {
                    TextField("Loan Amount", value: $loanAmount, format: .number)
                        .keyboardType(.decimalPad)
                        .padding()

                    TextField("Interest Rate", value: $interestRate, format: .number)
                        .keyboardType(.decimalPad)
                        .padding()
                }
            }
        }
        """
        let snippet = ContentViewRepairSupport.extractSnippet(from: source, around: 10)
        let diagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/GeneratedTool/ContentView.swift",
            line: 10,
            column: 10,
            severity: .error,
            message: "value of type 'TextField<Text>' has no member 'keyboardType'",
            supportingLines: []
        )

        let edit = try #require(
            ContentViewRepairSupport.makeDeterministicEdit(
                for: diagnostic,
                source: source,
                snippet: snippet
            )
        )
        let updated = try ContentViewRepairSupport.applyValidatedEdit(
            edit,
            to: source,
            snippet: snippet
        )

        #expect(updated.contains("TextField(\"Loan Amount\", value: $loanAmount, format: .number)\n                .padding()"))
        #expect(updated.contains("TextField(\"Interest Rate\", value: $interestRate, format: .number)\n                .keyboardType(.decimalPad)\n                .padding()"))
    }

    @Test
    func selectedDiagnosticGroupBatchesOnlySameRootCause() {
        let sameRoot = [
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 10,
                column: 12,
                severity: .error,
                message: "cannot find 'inputText' in scope",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 20,
                column: 12,
                severity: .error,
                message: "cannot find 'inputText' in scope",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 30,
                column: 12,
                severity: .error,
                message: "cannot find 'otherText' in scope",
                supportingLines: []
            )
        ]

        let grouped = ContentViewRepairSupport.selectedDiagnosticGroup(from: sameRoot, maximumCount: 3)
        #expect(grouped.count == 2)
        #expect(grouped.allSatisfy { $0.message.contains("inputText") })
        #expect(ContentViewRepairSupport.estimatedRepairGroupCount(from: sameRoot, maximumCount: 3) == 2)
        #expect(ContentViewRepairSupport.estimatedRepairGroupCount(from: sameRoot, maximumCount: 1) == 3)

        let unrelated = [
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 10,
                column: 12,
                severity: .error,
                message: "missing return in instance method expected to return 'Double'",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 20,
                column: 12,
                severity: .error,
                message: "cannot find 'inputText' in scope",
                supportingLines: []
            )
        ]

        #expect(ContentViewRepairSupport.selectedDiagnosticGroup(from: unrelated, maximumCount: 3).count == 1)

        let optionalSelfDiagnostics = [
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 20,
                column: 13,
                severity: .error,
                message: "cannot use optional chaining on non-optional value of type 'ContentView'",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 25,
                column: 15,
                severity: .error,
                message: "cannot use optional chaining on non-optional value of type 'ContentView'",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 30,
                column: 15,
                severity: .error,
                message: "cannot use optional chaining on non-optional value of type 'ContentView'",
                supportingLines: []
            )
        ]

        #expect(ContentViewRepairSupport.selectedDiagnosticGroup(from: optionalSelfDiagnostics, maximumCount: 3).count == 3)

        let distinctMemberDiagnostics = [
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 10,
                column: 12,
                severity: .error,
                message: "value of type 'Pipe' has no member 'gapY'",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 20,
                column: 12,
                severity: .error,
                message: "value of type 'Pipe' has no member 'gapY'",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 30,
                column: 12,
                severity: .error,
                message: "value of type 'Pipe' has no member 'x'",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 40,
                column: 12,
                severity: .error,
                message: "value of type 'Pipe' has no member 'passed'",
                supportingLines: []
            )
        ]
        #expect(ContentViewRepairSupport.estimatedRepairGroupCount(
            from: distinctMemberDiagnostics,
            maximumCount: distinctMemberDiagnostics.count
        ) == 3)
    }

    @Test
    func actionableErrorsIgnoreWarningsAndDeprioritizeTypeCheckTimeouts() {
        let diagnostics = [
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 45,
                column: 7,
                severity: .error,
                message: "the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 12,
                column: 10,
                severity: .warning,
                message: "initialization of immutable value was never used",
                supportingLines: []
            ),
            SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 30,
                column: 12,
                severity: .error,
                message: "cannot find 'payment' in scope",
                supportingLines: []
            )
        ]

        let errors = ContentViewRepairSupport.actionableErrors(
            from: diagnostics,
            contentViewPath: "Sources/Demo/ContentView.swift"
        )

        #expect(errors.map(\.line) == [30, 45])
    }
}
