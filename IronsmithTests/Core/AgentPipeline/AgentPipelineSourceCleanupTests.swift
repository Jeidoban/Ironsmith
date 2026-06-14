import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func cleanedSourceStripsLeadingPreamble() {
        let response = """
        Here is the fixed ContentView.swift file:
        ```swift
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Hello")
            }
        }
        ```
        """

        let cleaned = SingleFileToolGenerationRuntime.cleanedSource(response)

        #expect(cleaned.hasPrefix("import SwiftUI"))
        #expect(!(cleaned.contains("Here is the fixed ContentView.swift file:")))
    }

    @Test
    func cleanedSourceStripsThinkingBlocksBeforeCode() {
        let response = """
        <think>
        I should first reason through the UI and data flow.
        </think>
        ```swift
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Hello")
            }
        }
        ```
        """

        let cleaned = SingleFileToolGenerationRuntime.cleanedSource(response)

        #expect(cleaned.hasPrefix("import SwiftUI"))
        #expect(!(cleaned.contains("<think>")))
        #expect(!(cleaned.contains("reason through the UI")))
    }

    @Test
    func cleanedSourceStripsGemmaThinkingChannelBeforeCode() {
        let response = """
        <|channel>thought
        I should plan the app and maybe show a sample:
        ```swift
        struct Scratch {}
        ```
        <channel|>```swift
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Hello")
            }
        }
        ```
        """

        let cleaned = SingleFileToolGenerationRuntime.cleanedSource(response)

        #expect(cleaned.hasPrefix("import SwiftUI"))
        #expect(!(cleaned.contains("<|channel>thought")))
        #expect(!(cleaned.contains("struct Scratch")))
    }

    @Test
    func contentViewSourceCleanupRemovesScaffoldingAndNormalizesImports() {
        let response = """
        Here is the file:
        ```swift
        @main
        struct GeneratedApp: App {
            var body: some Scene {
                WindowGroup {
                    ContentView()
                }
            }
        }

        import SwiftUI

        #Preview {
            ContentView()
        }

        struct ContentView: View {
            var body: some View {
                Text(Date().formatted())
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                }
            }
        }
        ```
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(response)

        #expect(cleaned.hasPrefix("import SwiftUI"))
        #expect(cleaned.contains("import Foundation"))
        #expect(cleaned.contains("import AppKit"))
        #expect(!(cleaned.contains("@main")))
        #expect(!(cleaned.contains("GeneratedApp")))
        #expect(!(cleaned.contains("#Preview")))
    }

    @Test
    func contentViewSourceCleanupAddsFoundationForUUID() {
        let source = """
        import SwiftUI

        struct Thing: Identifiable {
            let id = UUID()
        }
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(cleaned.contains("import Foundation"))
    }

    @Test
    func contentViewSourceCleanupRemovesCommonFoundationModelFootguns() {
        let source = """
        ```swift
        import SwiftUI

        struct MortgageState: ObservableObject {
            @Published var principal: Double = 0
        }

        struct MortgageCalculator: View {
            var body: some View {
                TextField("Principal", value: $principal, format: .number)
                    .keyboardType(.decimalPad)
            }
        }

        struct ContentView_Previews: PreviewProvider {
            static var previews: some View {
                MortgageCalculator()
            }
        }
        ```
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(!(cleaned.contains("```")))
        #expect(cleaned.contains("final class MortgageState: ObservableObject"))
        #expect(cleaned.contains("struct ContentView: View"))
        #expect(!(cleaned.contains(".keyboardType")))
        #expect(!(cleaned.contains("PreviewProvider")))
    }

    @Test
    func contentViewSourceCleanupChainsBareSwiftUIModifierCalls() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Form {
                    Rectangle()
                        fill(Color.white)
                        stroke(Color.gray, lineWidth: 1)

                    Button("Calculate") {
                        Text("Calculate")
                        frame(maxWidth: .infinity)
                    }
                    buttonStyle(.borderedProminent)

                    HStack {
                        Text("Monthly Payment")
                        Spacer()
                        Text("$123.45")
                        fontWeight(.bold)
                        foregroundStyle(.secondary)
                    }
                }
                padding()
                frame(minWidth: 400, minHeight: 300)
                navigationTitle("Mortgage Calculator")
                toolbar {
                    Button("Refresh") {}
                }
            }
        }
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(cleaned.contains("                .fill(Color.white)"))
        #expect(cleaned.contains("                .stroke(Color.gray, lineWidth: 1)"))
        #expect(cleaned.contains("                .frame(maxWidth: .infinity)"))
        #expect(cleaned.contains("            .buttonStyle(.borderedProminent)"))
        #expect(cleaned.contains("                .fontWeight(.bold)"))
        #expect(cleaned.contains("                .foregroundStyle(.secondary)"))
        #expect(cleaned.contains("        .padding()"))
        #expect(cleaned.contains("        .frame(minWidth: 400, minHeight: 300)"))
        #expect(cleaned.contains("        .navigationTitle(\"Mortgage Calculator\")"))
        #expect(cleaned.contains("        .toolbar {"))
    }

    @Test
    func contentViewSourceCleanupRemovesMemberScopeViewBlocksAndUIKitColors() {
        let source = """
        import SwiftUI

        struct ContentView: View {
          // MARK: - State
          @State private var brightness = 0.5

          // MARK: - Body
          var body: some View {
            Text(brightness, style: .number)
              .background(Color.systemGray6)
          }

          // MARK: - Actions
          Button("Change") {
            brightness = 1
          }
        }
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(!(cleaned.contains("Button(\"Change\")")))
        #expect(cleaned.contains("Color.gray.opacity(0.15)"))
        #expect(cleaned.contains(#"Text("\(brightness)")"#))
    }

    @Test
    func contentViewSourceCleanupWrapsLooseSwiftUIFragment() {
        let source = """
        import Foundation
        import SwiftUI

        // MARK: - State
        @State private var loanAmount = 0.0
        @State private var interestRate = 0.0
        @State private var years = 30
        @State private var monthlyPayment: String = ""

        // MARK: - Body
        VStack {
          TextField("Loan Amount", value: $loanAmount, format: .number)
          TextField("Interest Rate", value: $interestRate, format: .number)
          Text(monthlyPayment)
        }

        // MARK: - Helpers
        private func calculatePayment() {
          monthlyPayment = String(format: "%.2f", loanAmount)
        }
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(cleaned.hasPrefix("import SwiftUI"))
        #expect(cleaned.contains("struct ContentView: View {"))
        #expect(cleaned.contains("    @State private var loanAmount = 0.0"))
        #expect(cleaned.contains("    var body: some View {"))
        #expect(cleaned.contains("        VStack {"))
        #expect(cleaned.contains("    private func calculatePayment() {"))
        #expect(!(cleaned.contains("property wrappers are not yet supported")))
    }

    @Test
    func contentViewSourceCleanupDetectsPlaceholderScaffold() {
        let placeholder = ContentViewSourceCleanup.normalizedSource(
            """
            @State private var count = 0
            """
        )
        let realTool = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("Actual tool")
            }
        }
        """

        #expect(ContentViewSourceCleanup.isPlaceholderScaffold(placeholder))
        #expect(!(ContentViewSourceCleanup.isPlaceholderScaffold(realTool)))
    }

    @Test
    func contentViewSourceCleanupPromotesBoundTopLevelVarsToState() {
        let source = """
        import SwiftUI

        var loanAmount = 0.0
        var interestRate = 0.0

        VStack {
          TextField("Loan Amount", value: $loanAmount, format: .number)
          TextField("Interest Rate", value: $interestRate, format: .number)
        }
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(cleaned.contains("@State private var loanAmount = 0.0"))
        #expect(cleaned.contains("@State private var interestRate = 0.0"))
        #expect(cleaned.contains("struct ContentView: View"))
        #expect(!(cleaned.contains("\nvar loanAmount = 0.0")))
    }

    @Test
    func contentViewSourceCleanupMovesTopLevelVarsIntoExistingContentView() {
        let source = """
        import SwiftUI

        // MARK: - State
        var loanAmount: Double = 0.0
        var interestRate: Double = 0.0

        struct ContentView: View {
          var body: some View {
            VStack {
              TextField("Loan Amount", value: $loanAmount, format: .number)
              TextField("Interest Rate", value: $interestRate, format: .number)
            }
          }
        }
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(cleaned.contains("struct ContentView: View {\n  // MARK: - State"))
        #expect(cleaned.contains("  @State private var loanAmount: Double = 0.0"))
        #expect(cleaned.contains("  @State private var interestRate: Double = 0.0"))
        #expect(!(cleaned.contains("\nvar loanAmount: Double = 0.0")))
    }

    @Test
    func contentViewSourceCleanupKeepsHelperStructStoredPropertiesOutsideContentView() {
        let source = """
        import SwiftUI

        struct Pipe: Identifiable {
          let id = UUID()
          var x: CGFloat
          var gapY: CGFloat
          var passed: Bool = false
        }

        struct ContentView: View {
          // MARK: - State
          @State private var pipes: [Pipe] = []

          var body: some View {
            ForEach(pipes) { pipe in
              Text("\\(pipe.gapY)")
            }
          }
        }
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(cleaned.contains("struct Pipe: Identifiable {\n  let id = UUID()\n  var x: CGFloat\n  var gapY: CGFloat\n  var passed: Bool = false\n}"))
        #expect(!(cleaned.contains("@State private var x: CGFloat")))
        #expect(!(cleaned.contains("@State private var gapY: CGFloat")))
        #expect(!(cleaned.contains("@State private var passed: Bool = false")))
    }

    @Test
    func contentViewSourceCleanupMovesUnboundTopLevelVarsIntoExistingContentView() {
        let source = """
        import SwiftUI

        var monthlyPayment: Double = 1000.0
        var loanTerm: Int = 30

        struct ContentView: View {
          var body: some View {
            VStack {
              Text("Payment: \\(monthlyPayment)")
              Text("Term: \\(loanTerm)")
            }
          }
        }
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(cleaned.contains("  @State private var monthlyPayment: Double = 1000.0"))
        #expect(cleaned.contains("  @State private var loanTerm: Int = 30"))
        #expect(!(cleaned.contains("\nvar monthlyPayment: Double = 1000.0")))
    }

    @Test
    func contentViewSourceCleanupRemovesMemberScopeViewExpressionsOutsideBody() {
        let source = """
        import SwiftUI

        struct ContentView: View {
          @State private var name = ""

          TextField("Name", text: $name)
          Button("Submit") {
            name = "Sent"
          }

          var body: some View {
            Text(name)
          }
        }
        """

        let cleaned = ContentViewSourceCleanup.normalizedSource(source)

        #expect(!(cleaned.contains("TextField(\"Name\"")))
        #expect(!(cleaned.contains("Button(\"Submit\"")))
        #expect(cleaned.contains("Text(name)"))
    }
}
