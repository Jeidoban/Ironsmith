import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func missingStoredPropertyRepairInfersTypesWithoutStringFallbacks() throws {
        let source = """
        import SwiftUI

        struct Habit: Identifiable {
          let id = UUID()
        }

        struct ContentView: View {
          @State private var habits: [Habit] = []
          @State private var newHabitName = ""

          var body: some View {
            Text("\\(habits.count)")
          }

          func addHabit() {
            habits.append(Habit(name: newHabitName, completedToday: false, streak: 0))
          }

          func toggleHabitCompletion(for habit: Habit) {
            let wasCompleted = habit.completedToday
            let newStreak = wasCompleted ? max(0, habit.streak - 1) : habit.streak + 1
            _ = newStreak
          }
        }
        """

        let habitLineIndex = try #require(source.components(separatedBy: .newlines).firstIndex { $0.contains("Habit(name:") })
        let habitLine = habitLineIndex + 1

        func repair(for member: String) throws -> ContentViewDeterministicRepair {
            try #require(ContentViewRepairSupport.makeDeterministicRepair(
                for: SwiftCompilerDiagnostic(
                    relativePath: "Sources/Demo/ContentView.swift",
                    line: habitLine,
                    column: 26,
                    severity: .error,
                    message: "value of type 'Habit' has no member '\(member)'",
                    supportingLines: []
                ),
                source: source,
                snippet: ContentViewRepairSupport.extractSnippet(from: source, around: habitLine)
            ))
        }

        #expect(try repair(for: "name").edit.replacement.contains("var name: String"))
        #expect(try repair(for: "completedToday").edit.replacement.contains("var completedToday: Bool"))
        #expect(try repair(for: "streak").edit.replacement.contains("var streak: Int"))
    }

    @Test
    func missingStoredPropertyRepairInfersCGFloatForLayoutConstructorArguments() throws {
        let source = """
        import SwiftUI

        struct Pipe: Identifiable {
          let id = UUID()
        }

        struct ContentView: View {
          @State private var pipes: [Pipe] = []
          private let gameWidth: CGFloat = 640

          var body: some View {
            ForEach(pipes) { pipe in
              Text("\\(pipe.x), \\(pipe.gapY)")
            }
          }

          func resetGame() {
            pipes = [
              Pipe(x: gameWidth + 100, gapY: CGFloat.random(in: 120...380))
            ]
          }
        }
        """

        let pipeLineIndex = try #require(source.components(separatedBy: .newlines).firstIndex { $0.contains("Pipe(x:") })
        let pipeLine = pipeLineIndex + 1

        func repair(for member: String) throws -> ContentViewDeterministicRepair {
            try #require(ContentViewRepairSupport.makeDeterministicRepair(
                for: SwiftCompilerDiagnostic(
                    relativePath: "Sources/Demo/ContentView.swift",
                    line: pipeLine,
                    column: 16,
                    severity: .error,
                    message: "value of type 'Pipe' has no member '\(member)'",
                    supportingLines: []
                ),
                source: source,
                snippet: ContentViewRepairSupport.extractSnippet(from: source, around: pipeLine)
            ))
        }

        #expect(try repair(for: "x").edit.replacement.contains("var x: CGFloat"))
        #expect(try repair(for: "gapY").edit.replacement.contains("var gapY: CGFloat"))
    }

    @Test
    func missingStoredPropertyRepairSkipsUnknownTypes() throws {
        let source = """
        struct Widget {
          let id = UUID()
        }

        struct ContentView {
          func makeWidget() -> Widget {
            Widget(value: makeValue())
          }
        }
        """

        let widgetLineIndex = try #require(source.components(separatedBy: .newlines).firstIndex { $0.contains("Widget(value:") })
        let widgetLine = widgetLineIndex + 1
        let repair = ContentViewRepairSupport.makeDeterministicRepair(
            for: SwiftCompilerDiagnostic(
                relativePath: "Sources/Demo/ContentView.swift",
                line: widgetLine,
                column: 12,
                severity: .error,
                message: "value of type 'Widget' has no member 'value'",
                supportingLines: []
            ),
            source: source,
            snippet: ContentViewRepairSupport.extractSnippet(from: source, around: widgetLine)
        )

        #expect(repair == nil)
    }
}
