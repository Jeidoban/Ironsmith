import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func deterministicRepairsCoverLoggedPongAndValidationFailures() throws {
        let largeGeneratedBody = """
          var body: some View {
            VStack {
        \(String(repeating: "      Text(\"Score\")\n", count: 140))\
            }
          }
        """
        let duplicateBodySource = """
        import SwiftUI

        struct ContentView: View {
          var body: some View {
            Text("Generated Tool")
          }

        \(largeGeneratedBody)
        }
        """

        let duplicateRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: 8,
                column: 7,
                severity: .error,
                message: "invalid redeclaration of 'body'",
                supportingLines: []
            ),
            source: duplicateBodySource,
            snippet: ContentViewRepairSupport.extractSnippet(from: duplicateBodySource, around: 8)
        ))
        #expect(duplicateRepair.name == "duplicateBodyFix")
        #expect(duplicateRepair.edit.target.contains("Text(\"Generated Tool\")"))
        #expect(duplicateRepair.edit.target.count < ContentViewRepairSupport.maximumTargetLength)
        let duplicateRepairedSource = try ContentViewRepairSupport.applyValidatedDeterministicEdits(
            [duplicateRepair.edit],
            to: duplicateBodySource,
            snippets: [ContentViewRepairSupport.extractSnippet(from: duplicateBodySource, around: 4)],
            allowWholeSourceTargets: true,
            maximumEdits: 1
        )
        #expect(!(duplicateRepairedSource.contains("Text(\"Generated Tool\")")))
        #expect(duplicateRepairedSource.contains("Text(\"Score\")"))

        let source = """
        import SwiftUI

        struct ContentView: View {
          @State private var loanTerm: Int = 30
          @State private var loanAmount: Double = 250000
          @State private var interestRate: Double = 5

          var body: some View {
            VStack {
              TextField(
                "Loan Term in Years", value: $loanTerm, formatter: NumberFormatter(numberStyle: .decimal))
              Rectangle()
                .frame(height: 100, width: 300)
                .fill(Color.white)
            }
          }

          private func isValidInput() -> Bool {
            guard let loanAmount = loanAmount, loanAmount > 0 else { return false }
            return true
          }

          private func updateMonthlyPayment() {
            let monthlyPayment =
              loanAmount * interestRate * (1 + interestRate)
              / ((1 + interestRate).pow(Double(loanTerm)) - 1)
          }
        }
        """

        func line(containing text: String) throws -> Int {
            let lines = source.components(separatedBy: .newlines)
            let index = try #require(lines.firstIndex { $0.contains(text) })
            return index + 1
        }

        let formatterLine = try line(containing: "NumberFormatter(numberStyle:")
        let formatterRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: formatterLine,
                column: 92,
                severity: .error,
                message: "argument passed to call that takes no arguments",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: formatterLine)
        ))
        #expect(formatterRepair.name == "textFieldNumberFormatterStyleFix")
        #expect(formatterRepair.edit.replacement.contains("format: .number"))
        #expect(!(formatterRepair.edit.replacement.contains("NumberFormatter")))

        let frameLine = try line(containing: ".frame(height:")
        let frameRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: frameLine,
                column: 29,
                severity: .error,
                message: "argument 'width' must precede argument 'height'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: frameLine)
        ))
        #expect(frameRepair.name == "frameArgumentOrderFix")
        #expect(frameRepair.edit.replacement.contains(".frame(width: 300, height: 100)"))

        let fillLine = try line(containing: ".fill(")
        let fillRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: fillLine,
                column: 10,
                severity: .error,
                message: "value of type 'some View' has no member 'fill'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: fillLine)
        ))
        #expect(fillRepair.name == "misplacedFillModifierFix")
        #expect(fillRepair.edit.replacement.contains(".background(Color.white)"))

        let guardLine = try line(containing: "guard let loanAmount")
        let guardRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
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
        #expect(guardRepair.name == "nonOptionalGuardBindingFix")
        #expect(guardRepair.edit.replacement == "    guard loanAmount > 0 else { return false }")

        let typeCheckLine = try line(containing: "loanAmount * interestRate")
        let powRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: typeCheckLine,
                column: 11,
                severity: .error,
                message: "the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: typeCheckLine)
        ))
        #expect(powRepair.name == "methodPowFix")
        #expect(powRepair.edit.replacement.contains("pow((1 + interestRate), Double(loanTerm))"))
    }

    @Test
    func deterministicRepairsCoverLoggedCalculatorAndSpreadsheetFailures() throws {
        let source = """
        import AppKit
        import SwiftUI

        struct ContentView: View {
          @State private var isEditing: Bool = false
          @State private var selectedCell: IndexPath? = IndexPath(row: 0, section: 0)
          private let columns = 26

          var body: some View {
            VStack {
              Text("\\(selectedCell?.row ?? 0)")
              ForEach(0 < columns, id: \\.self) { col in
                Text("\\(col)")
              }
              TextField("", text: .constant(""))
                .focused($isEditing)
                .onDoubleTapGesture {
                }
            }
          }

          private func resize(rows: Int, oldRows: Int) {
            if rows< oldRows {
            }
            for _ in 0 < 10 {
            }
            while index< chars.count {
            }
          }

          private func evaluateRangeSum(_ rangeString: String) {
            let parts = rangeString.split(separator: ":")
            let startCell = String(parts[0])
            _ = colFromString(startCell.prefix(1))
          }

          private func colFromString(_ value: String) -> Int? { nil }

          private var backgroundColor: Color {
            Color(NSColor.gray.opacity(0.15))
          }

          enum ButtonStyle {
            case operator
          }
        }
        """

        func line(containing text: String) throws -> Int {
            let lines = source.components(separatedBy: .newlines)
            let index = try #require(lines.firstIndex { $0.contains(text) })
            return index + 1
        }

        let forEachLine = try line(containing: "ForEach(0 < columns")
        let forEachRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: forEachLine,
                column: 13,
                severity: .error,
                message: "generic struct 'ForEach' requires that 'Bool' conform to 'RandomAccessCollection'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: forEachLine)
        ))
        #expect(forEachRepair.name == "malformedRangeIterationFix")
        #expect(forEachRepair.edit.replacement.contains("ForEach(0..<columns"))

        let forLine = try line(containing: "for _ in 0 < 10")
        let forRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: forLine,
                column: 16,
                severity: .error,
                message: "for-in loop requires 'Bool' to conform to 'Sequence'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: forLine)
        ))
        #expect(forRepair.name == "malformedRangeIterationFix")
        #expect(forRepair.edit.replacement.contains("for _ in 0..<10"))

        let ifLine = try line(containing: "if rows< oldRows")
        let ifRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: ifLine,
                column: 20,
                severity: .error,
                message: "expected '{' after 'if' condition",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: ifLine)
        ))
        #expect(ifRepair.name == "ifConditionOperatorSpacingFix")
        #expect(ifRepair.edit.replacement.contains("rows < oldRows"))

        let whileLine = try line(containing: "while index< chars.count")
        let whileRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: whileLine,
                column: 24,
                severity: .error,
                message: "expected '{' after 'while' condition",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: whileLine)
        ))
        #expect(whileRepair.name == "ifConditionOperatorSpacingFix")
        #expect(whileRepair.edit.replacement.contains("index < chars.count"))

        let substringLine = try line(containing: "colFromString(startCell.prefix")
        let substringRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: substringLine,
                column: 31,
                severity: .error,
                message: "cannot convert value of type 'String.SubSequence' (aka 'Substring') to expected argument type 'String'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: substringLine)
        ))
        #expect(substringRepair.name == "substringToStringArgumentFix")
        #expect(substringRepair.edit.replacement.contains("colFromString(String(startCell.prefix(1)))"))

        let colorLine = try line(containing: "NSColor.gray.opacity")
        let colorRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: colorLine,
                column: 31,
                severity: .error,
                message: "value of type 'NSColor' has no member 'opacity'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: colorLine)
        ))
        #expect(colorRepair.name == "nsColorOpacityFix")
        #expect(colorRepair.edit.replacement.contains("withAlphaComponent(0.15)"))

        let indexPathInitializerLine = try line(containing: "IndexPath(row:")
        let indexPathInitializerRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: indexPathInitializerLine,
                column: 58,
                severity: .error,
                message: "incorrect argument label in call (have 'row:section:', expected 'item:section:')",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: indexPathInitializerLine)
        ))
        #expect(indexPathInitializerRepair.name == "indexPathMacOSFix")
        #expect(indexPathInitializerRepair.edit.replacement.contains("IndexPath(item: 0, section: 0)"))

        let indexPathRowLine = try line(containing: "selectedCell?.row")
        let indexPathRowRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: indexPathRowLine,
                column: 32,
                severity: .error,
                message: "value of type 'IndexPath' has no member 'row'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: indexPathRowLine)
        ))
        #expect(indexPathRowRepair.name == "indexPathMacOSFix")
        #expect(indexPathRowRepair.edit.replacement.contains("selectedCell?.item"))

        let focusLine = try line(containing: ".focused($isEditing)")
        let focusRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: focusLine,
                column: 20,
                severity: .error,
                message: "cannot find '$isEditing' in scope",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: focusLine)
        ))
        #expect(focusRepair.name == "unsupportedFocusModifierFix")
        #expect(focusRepair.edit.replacement == "")

        let doubleTapLine = try line(containing: ".onDoubleTapGesture")
        let doubleTapRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: doubleTapLine,
                column: 16,
                severity: .error,
                message: "value of type 'some View' has no member 'onDoubleTapGesture'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: doubleTapLine)
        ))
        #expect(doubleTapRepair.name == "unsupportedModifierFix")
        #expect(doubleTapRepair.edit.replacement.contains(".onTapGesture(count: 2)"))

        let operatorLine = try line(containing: "case operator")
        let operatorRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: operatorLine,
                column: 18,
                severity: .error,
                message: "keyword 'operator' cannot be used as an identifier here",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: operatorLine)
        ))
        #expect(operatorRepair.name == "reservedKeywordEnumCaseFix")
        #expect(operatorRepair.edit.replacement.contains("case `operator`"))
    }

    @Test
    func deterministicRepairsCoverSpreadsheetRegenerationLoopFailures() throws {
        let source = """
        import SwiftUI

        struct CellData: Identifiable, Equatable {
          let id = UUID()

          init(value: String = "", formula: String? = nil) {
            self.value = value
            self.formula = formula
          }

          static func == (lhs: CellData, rhs: CellData) -> Bool {
            lhs.id == rhs.id && lhs.value == rhs.value && lhs.formula == rhs.formula
          }
        }

        struct CellID {
          let row: Int
          let col: Int
        }

        struct ContentView: View {
          @State private var editValue = ""
          @State private var selectedCell: CellID?
          private let columns = 26

          var body: some View {
            VStack {
              FormulaBar(text: editValue)
              TextField("Formula or Value", text: $editValue)
                .font(.monospacedDigit(.fixed(size: 12)))
              ForEach(0 < min(columns, 26), id: \\.self) { col in
                Text("\\(col)")
              }
              ControlGroup {
                Button("B") {}
              }
              .controlGroupStyle(.bordered)
              Text("A")
                .border(Color.gray.opacity(0.3), edges: [.bottom, .trailing])
              Text("B")
                .border(Color(.separator), width: 1)
              Text("C")
                .focused(\\.isFocused)
            }
          }

          private func generateInitialCells() {
            for _ in 0<1352 { // 26 cols * 52 rows
            }
          }

          private func headerTap(col: Int) {
            let isHeaderSelected = selectedCell.map { $0.col == col } ?? false
            _ = isHeaderSelected
          }

          private func tokenize(formula: String) {
            _ = formula.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty && !CharacterSet.letters.contains($0.first!) }
          }

          private func evaluate(expression: String) -> Double? {
            let chars = Array(expression)
            for i in 1..<chars.count - 1 {
              let leftStr = String(chars[0 < i])
              let rightStr = String(chars[i + 1...])
              _ = leftStr
              _ = rightStr
            }
            return nil
          }
        }
        """

        func line(containing text: String) throws -> Int {
            let lines = source.components(separatedBy: .newlines)
            let index = try #require(lines.firstIndex { $0.contains(text) })
            return index + 1
        }

        let storedPropertyLine = try line(containing: "self.value = value")
        let storedPropertyRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: storedPropertyLine,
                column: 10,
                severity: .error,
                message: "value of type 'CellData' has no member 'value'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: storedPropertyLine)
        ))
        #expect(storedPropertyRepair.name == "missingStoredPropertyFromInitializerFix")
        #expect(storedPropertyRepair.edit.replacement.contains("var value: String"))
        #expect(storedPropertyRepair.edit.replacement.contains("var formula: String?"))

        let bindingLine = try line(containing: "FormulaBar(text: editValue)")
        let bindingRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: bindingLine,
                column: 26,
                severity: .error,
                message: "cannot convert value 'editValue' of type 'String' to expected type 'Binding<String>', use wrapper instead",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: bindingLine)
        ))
        #expect(bindingRepair.name == "missingBindingPrefixFix")
        #expect(bindingRepair.edit.replacement.contains("FormulaBar(text: $editValue)"))

        let fontLine = try line(containing: ".monospacedDigit")
        let fontRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: fontLine,
                column: 16,
                severity: .error,
                message: "member 'monospacedDigit()' is a function that produces expected type 'Font'; did you mean to call it?",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: fontLine)
        ))
        #expect(fontRepair.name == "invalidMonospacedDigitFontFix")
        #expect(fontRepair.edit.replacement.contains(".system(size: 12, design: .monospaced)"))

        let forEachLine = try line(containing: "ForEach(0 < min")
        let forEachRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: forEachLine,
                column: 13,
                severity: .error,
                message: "generic struct 'ForEach' requires that 'Bool' conform to 'RandomAccessCollection'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: forEachLine)
        ))
        let forEachUpdated = try ContentViewRepairSupport.applyValidatedDeterministicEdit(
            forEachRepair.edit,
            to: source,
            allowWholeSourceTargets: true
        )
        #expect(forEachRepair.name == "malformedRangeIterationFix")
        #expect(forEachUpdated.contains("ForEach(0..<min(columns, 26), id: \\.self)"))

        let commentRangeLine = try line(containing: "0<1352")
        let commentRangeRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: commentRangeLine,
                column: 18,
                severity: .error,
                message: "for-in loop requires 'Bool' to conform to 'Sequence'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: commentRangeLine)
        ))
        let commentRangeUpdated = try ContentViewRepairSupport.applyValidatedDeterministicEdit(
            commentRangeRepair.edit,
            to: source,
            allowWholeSourceTargets: true
        )
        #expect(commentRangeUpdated.contains("for _ in 0..<1352 {"))

        let borderLine = try line(containing: "edges:")
        let borderRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: borderLine,
                column: 18,
                severity: .error,
                message: "extra argument 'edges' in call",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: borderLine)
        ))
        #expect(borderRepair.name == "borderEdgesArgumentFix")
        #expect(borderRepair.edit.replacement.trimmingCharacters(in: .whitespaces) == ".border(Color.gray.opacity(0.3))")

        let controlGroupLine = try line(containing: ".controlGroupStyle")
        let controlGroupRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: controlGroupLine,
                column: 24,
                severity: .error,
                message: "type 'ControlGroupStyle' has no member 'bordered'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: controlGroupLine)
        ))
        #expect(controlGroupRepair.name == "unsupportedControlGroupStyleFix")
        #expect(controlGroupRepair.edit.replacement == "")

        let colorLine = try line(containing: "Color(.separator)")
        let colorRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: colorLine,
                column: 18,
                severity: .error,
                message: "no exact matches in call to initializer",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: colorLine)
        ))
        #expect(colorRepair.name == "invalidColorInitializerFix")
        #expect(colorRepair.edit.replacement.contains("Color.gray.opacity(0.3)"))

        let focusLine = try line(containing: ".focused(\\.isFocused)")
        let focusRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: focusLine,
                column: 18,
                severity: .error,
                message: "cannot convert value of type 'KeyPath<Root, Value>' to expected argument type 'FocusState<Bool>.Binding'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: focusLine)
        ))
        #expect(focusRepair.name == "unsupportedFocusModifierFix")

        let mapLine = try line(containing: "selectedCell.map")
        let mapRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: mapLine,
                column: 42,
                severity: .error,
                message: "the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: mapLine)
        ))
        #expect(mapRepair.name == "optionalMapTypeCheckFix")
        #expect(mapRepair.edit.replacement.contains("selectedCell?.col == col"))

        let characterSetLine = try line(containing: "CharacterSet.letters.contains")
        let characterSetRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: characterSetLine,
                column: 61,
                severity: .error,
                message: "cannot convert value of type 'String.Element' (aka 'Character') to expected argument type 'Unicode.Scalar'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: characterSetLine)
        ))
        #expect(characterSetRepair.name == "characterSetContainsCharacterFix")
        #expect(characterSetRepair.edit.replacement.contains("rangeOfCharacter(from: .letters)"))

        let arraySliceLine = try line(containing: "chars[0 < i]")
        let arraySliceRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: arraySliceLine,
                column: 36,
                severity: .error,
                message: "cannot convert value of type 'Bool' to expected argument type 'Int'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: arraySliceLine)
        ))
        #expect(arraySliceRepair.name == "malformedArraySliceFix")
        #expect(arraySliceRepair.edit.replacement.contains("chars[0..<i]"))
    }

    @Test
    func deterministicRepairsCoverLatestSpreadsheetLoopFailures() throws {
        let source = """
        import SwiftUI

        struct CellData {
          let id = UUID()
        }

        struct RowData {
          init(cellCount: Int) {
            self.cells = (0<cellCount).map { _ in CellData() }
          }
        }

        struct ContentView: View {
          @State private var sheet = SheetData(rows: 20, columns: 10)
          @State private var selectedCell = (row: 0, col: 0)
          private let columnHeaders: [String] = {
            var headers: [String] = []
            var current = "A"
            for _ in 0..<26 {
              headers.append(current)
              current = String(nextColumnString: current)
            }
            return headers
          }()
          let columns = Array("A"..."ZZ")

          var body: some View {
            VStack {
              Text("A")
                .onKeyPress(.enter) { .handled }
              if selectedCell.row< 99 {
                Text("B")
              }
              if selectedCell.row< 99 {
                Text("C")
              }
              guard selectedCell.row< 99, selectedCell.col< 25 else { return }
              Text("D")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: cell.alignment)
              Text("Row")
                .border(Color.gray.opacity(0.3))
                .overlay(
                  AlignmentGuide(.leading) { d in d[.leading] },
                  alignment: .leading
                )
              Text("Menu")
                .onContextMenu {
                  ContextMenu {
                    Button("Copy") { copyCell(at: rowIndex * defaultCols + colIndex) }
                    Button("Cut") { cutCell(at: rowIndex * defaultCols + colIndex) }
                    Button("Paste") { pasteCell(at: rowIndex * defaultCols + colIndex) }
                    Button("Delete") { deleteCell(at: rowIndex * defaultCols + colIndex) }
                  }
                }
            }
          }

          private func handleKeyPress(_ key: Key) {
            switch key {
            case .up:
              break
            default:
              break
            }
          }

          struct SheetData {
            let rows: Int
            let columns: Int
            private var data: [Int: [Int: CellData]] = [:]
          }
        }
        """

        func line(containing text: String) throws -> Int {
            let lines = source.components(separatedBy: .newlines)
            let index = try #require(lines.firstIndex { $0.contains(text) })
            return index + 1
        }

        let duplicatedRowLine = try line(containing: "if selectedCell.row< 99")
        let duplicatedRowRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: duplicatedRowLine,
                column: 34,
                severity: .error,
                message: "'<' is not a postfix unary operator",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: duplicatedRowLine)
        ))
        let duplicatedRowUpdated = try ContentViewRepairSupport.applyValidatedDeterministicEdit(
            duplicatedRowRepair.edit,
            to: source,
            snippets: [
                ContentViewRepairSnippet(
                    startLine: duplicatedRowLine,
                    endLine: duplicatedRowLine,
                    text: source.components(separatedBy: .newlines)[duplicatedRowLine - 1]
                )
            ],
            allowWholeSourceTargets: true
        )
        #expect(duplicatedRowRepair.name == "ifConditionOperatorSpacingFix")
        #expect(duplicatedRowUpdated.contains("if selectedCell.row < 99"))

        let enterLine = try line(containing: ".onKeyPress(.enter)")
        let enterRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: enterLine,
                column: 22,
                severity: .error,
                message: "type 'KeyEquivalent' has no member 'enter'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: enterLine)
        ))
        #expect(enterRepair.name == "invalidKeyEquivalentMemberFix")
        #expect(enterRepair.edit.replacement.contains(".onKeyPress(.return)"))

        let keyLine = try line(containing: "handleKeyPress")
        let keyRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: keyLine,
                column: 38,
                severity: .error,
                message: "cannot find type 'Key' in scope",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: keyLine)
        ))
        #expect(keyRepair.name == "unknownKeyTypeFix")
        #expect(keyRepair.edit.replacement.contains("KeyEquivalent"))

        let privateInitializerLine = try line(containing: "SheetData(rows")
        let privateInitializerRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: privateInitializerLine,
                column: 34,
                severity: .error,
                message: "'ContentView.SheetData' initializer is inaccessible due to 'private' protection level",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: privateInitializerLine)
        ))
        #expect(privateInitializerRepair.name == "privateMemberwiseInitializerFix")
        #expect(privateInitializerRepair.edit.replacement.contains("private(set) var data"))

        let alignmentLine = try line(containing: "alignment: cell.alignment")
        let alignmentRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: alignmentLine,
                column: 79,
                severity: .error,
                message: "cannot convert value of type 'HorizontalAlignment' to expected argument type 'Alignment'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: alignmentLine)
        ))
        #expect(alignmentRepair.name == "horizontalAlignmentFrameFix")
        #expect(alignmentRepair.edit.replacement.contains("Alignment(horizontal: cell.alignment, vertical: .center)"))

        let alignmentGuideLine = try line(containing: "AlignmentGuide")
        let alignmentGuideRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: alignmentGuideLine,
                column: 19,
                severity: .error,
                message: "cannot find 'AlignmentGuide' in scope",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: alignmentGuideLine)
        ))
        let alignmentGuideUpdated = try ContentViewRepairSupport.applyValidatedDeterministicEdit(
            alignmentGuideRepair.edit,
            to: source,
            snippets: [ContentViewRepairSupport.extractSnippet(from: source, around: alignmentGuideLine)]
        )
        #expect(alignmentGuideRepair.name == "invalidAlignmentGuideOverlayFix")
        #expect(!(alignmentGuideUpdated.contains("AlignmentGuide")))
        #expect(alignmentGuideUpdated.contains(".border(Color.gray.opacity(0.3))"))

        let contextMenuLine = try line(containing: "ContextMenu {")
        let contextMenuRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: contextMenuLine,
                column: 31,
                severity: .error,
                message: "the compiler is unable to type-check this expression in reasonable time; try breaking up the expression into distinct sub-expressions",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: contextMenuLine)
        ))
        let contextMenuUpdated = try ContentViewRepairSupport.applyValidatedDeterministicEdit(
            contextMenuRepair.edit,
            to: source,
            snippets: [ContentViewRepairSupport.extractSnippet(from: source, around: contextMenuLine)]
        )
        #expect(contextMenuRepair.name == "contextMenuIndexHoistTypeCheckFix")
        #expect(contextMenuUpdated.contains("let idx = rowIndex * defaultCols + colIndex"))
        #expect(contextMenuUpdated.contains("copyCell(at: idx)"))
        #expect(contextMenuUpdated.contains("deleteCell(at: idx)"))

        let guardLine = try line(containing: "guard selectedCell")
        let guardRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: guardLine,
                column: 28,
                severity: .error,
                message: "expected 'else' after 'guard' condition",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: guardLine)
        ))
        #expect(guardRepair.name == "ifConditionOperatorSpacingFix")
        #expect(guardRepair.edit.replacement.contains("row < 99"))
        #expect(guardRepair.edit.replacement.contains("col < 25"))

        let columnRangeLine = try line(containing: #"Array("A"..."ZZ")"#)
        let columnRangeRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: columnRangeLine,
                column: 23,
                severity: .error,
                message: "missing argument label 'arrayLiteral:' in call",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: columnRangeLine)
        ))
        #expect(columnRangeRepair.name == "stringClosedRangeAlphabetFix")
        #expect(columnRangeRepair.edit.replacement.contains("0..<702"))

        let stringWrapperLine = try line(containing: "String(nextColumnString")
        let stringWrapperRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: stringWrapperLine,
                column: 29,
                severity: .error,
                message: "extraneous argument label 'nextColumnString:' in call",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: stringWrapperLine)
        ))
        #expect(stringWrapperRepair.name == "extraneousStringWrapperLabelFix")
        #expect(stringWrapperRepair.edit.replacement.contains("nextColumnString(current)"))

        let cellsLine = try line(containing: "self.cells")
        let cellsRepair = try #require(ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: cellsLine,
                column: 10,
                severity: .error,
                message: "value of type 'RowData' has no member 'cells'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: cellsLine)
        ))
        #expect(cellsRepair.name == "missingStoredPropertyFromInitializerFix")
        #expect(cellsRepair.edit.replacement.contains("var cells: [CellData]"))
    }
}
