import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func deterministicRepairsCoverObservedFoundationModelPatterns() throws {
        let source = """
        import SwiftUI

        struct MortgageState: ObservableObject {
            @Published var principal: Double = 0
        }

        struct ContentView: View {
            @State private var principal: Double = 0
            @State private var years: Int = 0
            @State private var monthlyPayment: Double = 0

            func calculate() {
                guard !principal.isEmpty, !years.isEmpty else { return }
                let monthlyPayment = principal
                monthlyPayment = monthlyPayment.rounded(toPlaces: 2)
                self.monthlyPayment = monthlyPayment
            }
        }
        """

        let observableDiagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/Demo/ContentView.swift",
            line: 3,
            column: 8,
            severity: .error,
            message: "non-class type 'MortgageState' cannot conform to class protocol 'ObservableObject'",
            supportingLines: []
        )
        let isEmptyDiagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/Demo/ContentView.swift",
            line: 13,
            column: 26,
            severity: .error,
            message: "referencing property 'isEmpty' requires wrapper 'Binding<Double>'",
            supportingLines: []
        )
        let roundedDiagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/Demo/ContentView.swift",
            line: 15,
            column: 47,
            severity: .error,
            message: "no exact matches in call to instance method 'rounded'",
            supportingLines: []
        )
        let rangeDiagnostic = SwiftCompilerDiagnostic(
            relativePath: "Sources/Demo/ContentView.swift",
            line: 7,
            column: 17,
            severity: .error,
            message: "referencing instance method 'makeIterator()' on 'Range' requires that 'Double.Stride' (aka 'Double') conform to 'SignedInteger'",
            supportingLines: []
        )

        let observableEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: observableDiagnostic,
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: 3)
        ))
        let isEmptyEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: isEmptyDiagnostic,
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: 13)
        ))
        let roundedEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: roundedDiagnostic,
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: 15)
        ))
        let rangeSource = """
        import SwiftUI

        struct ContentView: View {
            @State private var monthlyPayment: Double = 0

            func calculate(numberOfPayments: Double) {
                for _ in 0..<numberOfPayments {
                    monthlyPayment += 1
                }
            }
        }
        """
        let rangeEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: rangeDiagnostic,
            source: rangeSource,
            snippet: ContentViewRepairSupport.extractSnippet(from: rangeSource, around: 7)
        ))

        #expect(observableEdit.replacement.contains("final class MortgageState"))
        #expect(isEmptyEdit.replacement.contains("principal > 0"))
        #expect(isEmptyEdit.replacement.contains("years > 0"))
        #expect(roundedEdit.replacement == "")
        #expect(rangeEdit.replacement.contains("0..<Int(numberOfPayments)"))
    }

    @Test
    func deterministicRepairsCoverLatestFoundationModelLogPatterns() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            @State private var years: Int = 30
            @State private var result: Double?
            @State private var firstNumber: Double = 0
            @State private var secondNumber: Double = 0

            var body: some View {
                VStack {
                    Slider(value: $years, in: 1...30)
                    Text("\\(result ?? "")")
                    TextField("First number", text: $years)
                        .background(Color.systemGray6)
                }
            }

            func calculate() {
                guard let firstNumber = Double(firstNumber), let secondNumber = Double(secondNumber) else { return }
                let operation = "+"
                operation = "-"
                result = firstNumber + secondNumber
            }
        }
        """

        func line(containing text: String) throws -> Int {
            let lines = source.components(separatedBy: .newlines)
            let index = try #require(lines.firstIndex { $0.contains(text) })
            return index + 1
        }

        let sliderLine = try line(containing: "Slider(value:")
        let sliderEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: sliderLine,
                column: 7,
                severity: .error,
                message: "initializer 'init(value:in:onEditingChanged:)' requires that 'Int' conform to 'BinaryFloatingPoint'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: sliderLine)
        ))

        let textLine = try line(containing: "result ??")
        let textEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: textLine,
                column: 17,
                severity: .error,
                message: "cannot convert value of type 'Double?' to expected argument type 'String?'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: textLine)
        ))

        let colorLine = try line(containing: "Color.systemGray6")
        let colorEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: colorLine,
                column: 27,
                severity: .error,
                message: "type 'Color' has no member 'systemGray6'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: colorLine)
        ))

        let guardLine = try line(containing: "guard let")
        let guardEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: guardLine,
                column: 11,
                severity: .error,
                message: "initializer for conditional binding must have Optional type, not 'Double'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: guardLine)
        ))

        let operationLine = try line(containing: "operation =")
        let operationEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: operationLine,
                column: 9,
                severity: .error,
                message: "cannot assign to value: 'operation' is a 'let' constant",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: operationLine)
        ))

        #expect(sliderEdit.replacement.contains("Stepper"))
        #expect(textEdit.replacement.contains("result.map"))
        #expect(colorEdit.replacement.contains("Color.gray.opacity"))
        #expect(guardEdit.replacement.contains("guard firstNumber"))
        #expect(operationEdit.target.contains("let operation"))
        #expect(operationEdit.replacement.contains("var operation"))
    }

    @Test
    func deterministicRepairsCoverLatestSuccessfulBatchNearMisses() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            struct LoanDetails {
                var amount: Double = 250000
            }

            @State private var principal: Double = 250000
            @State private var interestRate: Double = 4.5
            @State private var termYears: Double = 30
            @State private var timer = 60
            @State private var timeRemaining = timer
            @State private var html = ""
            @State private var loanDetails = LoanDetails()

            var body: some View {
                VStack {
                    Text("Cookies: \\(cookies)")
                    TextField("Enter URL", value: $html, format: .url)
                    TextField("Principal Amount", value: $loanDetails.principal, format: .number)
                }
                .onChange(of: loanDetails) { _, _ in }
                .background(Color(.windowBackground))
            }

            func showAlert(message: String) {
                let alert = UIAlertController(title: "Game Over", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
            }
        }
        """

        func line(containing text: String) throws -> Int {
            let lines = source.components(separatedBy: .newlines)
            let index = try #require(lines.firstIndex { $0.contains(text) })
            return index + 1
        }

        let stateLine = try line(containing: "timeRemaining")
        let stateRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: stateLine,
                column: 48,
                severity: .error,
                message: "cannot use instance member 'timer' within property initializer; property initializers run before 'self' is available",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: stateLine)
        ))
        #expect(stateRepair.name == "stateInitializedFromStateFix")
        #expect(stateRepair.edit.replacement.contains("= 60"))

        let missingLine = try line(containing: "Cookies:")
        let missingRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: missingLine,
                column: 34,
                severity: .error,
                message: "cannot find 'cookies' in scope",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: missingLine)
        ))
        #expect(missingRepair.name == "missingDisplayStateFix")
        #expect(missingRepair.edit.replacement == "@State private var cookies: Int = 0")

        let textFieldLine = try line(containing: "format: .url")
        let textFieldRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: textFieldLine,
                column: 17,
                severity: .error,
                message: "no exact matches in call to initializer",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: textFieldLine)
        ))
        #expect(textFieldRepair.name == "stringTextFieldFormatFix")
        #expect(textFieldRepair.edit.replacement.contains("text: $html"))
        #expect(!(textFieldRepair.edit.replacement.contains("format:")))

        let alertLine = try line(containing: "UIAlertController")
        let alertRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: alertLine,
                column: 29,
                severity: .error,
                message: "cannot find 'UIAlertController' in scope",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: alertLine)
        ))
        #expect(alertRepair.name == "uiAlertHelperNoopFix")
        #expect(alertRepair.edit.replacement == "func showAlert(message: String) { }")

        let dynamicMemberLine = try line(containing: "$loanDetails.principal")
        let dynamicMemberRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: dynamicMemberLine,
                column: 61,
                severity: .error,
                message: "value of type 'Binding<LoanDetails>' has no dynamic member 'principal' using key path from root type 'LoanDetails'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: dynamicMemberLine)
        ))
        #expect(dynamicMemberRepair.name == "dynamicMemberStateAliasFix")
        #expect(dynamicMemberRepair.edit.replacement.contains("$principal"))
        #expect(!(dynamicMemberRepair.edit.replacement.contains("$loanDetails.principal")))

        let onChangeLine = try line(containing: ".onChange(of:")
        let equatableRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: onChangeLine,
                column: 18,
                severity: .error,
                message: "instance method 'onChange(of:initial:_:)' requires that 'LoanDetails' conform to 'Equatable'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: onChangeLine)
        ))
        #expect(equatableRepair.name == "equatableConformanceFix")
        #expect(equatableRepair.edit.target.contains("struct LoanDetails"))
        #expect(equatableRepair.edit.replacement.contains(": Equatable"))

        let backgroundLine = try line(containing: "Color(.windowBackground)")
        let backgroundRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: backgroundLine,
                column: 29,
                severity: .error,
                message: "no exact matches in call to initializer",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: backgroundLine)
        ))
        #expect(backgroundRepair.name == "windowBackgroundColorFix")
        #expect(backgroundRepair.edit.replacement.contains("NSColor.windowBackgroundColor"))
    }

    @Test
    func deterministicRepairsCoverLoggedMortgageFailures() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            @State private var monthlyPayment: Double = 0
            @State private var interestRate: Double = 5
            @State private var years: Double = 30

            var body: some View {
                VStack {
                    Button(action: calculateMortgage) {
                        Text("Calculate")
                    }
                    Text("Total Interest: \\(String(format: "%.2f", totalInterest))")
                }
            }

            func calculateMortgage() -> Double? {
                let principal = 250000.0
                let rate = interestRate / 100 / 12
                let years = Double(years) * 12
                let monthlyPayment = (principal * rate) / (1 - (1 + rate) ** -years)
                monthlyPayment = String(format: "%.2f", monthlyPayment)
                let brokenPayment = (principal * interestRate / 100) / ((1 + interestRate / 100) / (1 - (1 / pow(1 + interestRate / 100, Double(years))))
                return monthlyPayment
            }
        }
        """

        func line(containing text: String) throws -> Int {
            let lines = source.components(separatedBy: .newlines)
            let index = try #require(lines.firstIndex { $0.contains(text) })
            return index + 1
        }

        let formatLine = try line(containing: "monthlyPayment = String(format:")
        let formatEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: formatLine,
                column: 17,
                severity: .error,
                message: "cannot assign to value: 'monthlyPayment' is a 'let' constant",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: formatLine)
        ))
        #expect(formatEdit.operation == .replaceLine)
        #expect(formatEdit.replacement == "")
        let namedFormatRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: formatLine,
                column: 17,
                severity: .error,
                message: "cannot assign to value: 'monthlyPayment' is a 'let' constant",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: formatLine)
        ))
        #expect(namedFormatRepair.name == "formattedNumericAssignmentFix")
        #expect(namedFormatRepair.edit == formatEdit)

        let exponentLine = try line(containing: "** -years")
        let exponentEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: exponentLine,
                column: 73,
                severity: .error,
                message: "no operator '**' is defined; did you mean 'pow(_:_:)'?",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: exponentLine)
        ))
        #expect(exponentEdit.replacement.contains("pow((1 + rate), -years)"))

        let buttonLine = try line(containing: "Button(action:")
        let buttonEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: buttonLine,
                column: 28,
                severity: .error,
                message: "cannot convert value of type '@MainActor @Sendable () -> Double?' to expected argument type '@MainActor () -> Void'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: buttonLine)
        ))
        #expect(buttonEdit.replacement.contains("Button(action: { _ = calculateMortgage() })"))

        let brokenLine = try line(containing: "let brokenPayment")
        let parenthesisEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: brokenLine,
                column: 149,
                severity: .error,
                message: "expected ',' separator",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: brokenLine)
        ))
        #expect(parenthesisEdit.replacement.hasSuffix(")"))
        #expect(parenthesisEdit.replacement.filter { $0 == "(" }.count == parenthesisEdit.replacement.filter { $0 == ")" }.count)

        let missingInterestLine = try line(containing: "totalInterest")
        let missingInterestEdit = try #require(ContentViewRepairSupport.makeDeterministicEdit(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: missingInterestLine,
                column: 60,
                severity: .error,
                message: "cannot find 'totalInterest' in scope",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: missingInterestLine)
        ))
        #expect(missingInterestEdit.operation == .addStateProperty)
        #expect(missingInterestEdit.replacement == "@State private var totalInterest: Double = 0.0")
    }
}
