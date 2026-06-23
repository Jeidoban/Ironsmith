import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func applyValidatedDiffAppliesUnifiedHunkWithContext() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let diff = """
        --- a/ContentView.swift
        +++ b/ContentView.swift
        @@ -3,7 +3,7 @@
         struct ContentView: View {
             var body: some View {
        -        Text("One")
        +        Text("Two")
             }
         }
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: 1)

        #expect(updated.contains("Text(\"Two\")"))
        #expect(!(updated.contains("Text(\"One\")")))
        let summary = ContentViewRepairSupport.sanitizedRepairDiffSummary(diff)
        #expect(!(summary.contains("<|channel>thought")))
        #expect(!(summary.contains("Text(\"not a diff\")")))
        #expect(summary.contains("-        Text(\"One\")"))
    }

    @Test
    func applyValidatedDiffPreservesMultiplePlainDiffHunks() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                ZStack {
                    Color.black
                    Canvas { context, size in
                        let midX = size.width / 2
                        var line = Path()
                        line.move(to: CGPoint(x: midX, y: 0))
                        line.addLine(to: CGPoint(x: midX, y: size.height))
                        context.stroke(line, with: .color(.white.opacity(0.2)), lineWidth: 2)
                        let ballRect = CGRect(x: 10, y: 10, width: 12, height: 12)
                        context.fill(Path(ballRect), with: .color(.white))
                    }
                    Text("0")
                        .foregroundColor(.white.opacity(0.3))
                }
            }
        }
        """
        let diff = """
        --- ContentView.swift
        +++ ContentView.swift
        @@
                 ZStack {
        -            Color.black
        +            Color.white
                     Canvas { context, size in
        @@
                         line.move(to: CGPoint(x: midX, y: 0))
                         line.addLine(to: CGPoint(x: midX, y: size.height))
        -                context.stroke(line, with: .color(.white.opacity(0.2)), lineWidth: 2)
        +                context.stroke(line, with: .color(.black.opacity(0.2)), lineWidth: 2)
                         let ballRect = CGRect(x: 10, y: 10, width: 12, height: 12)
        @@
                         let ballRect = CGRect(x: 10, y: 10, width: 12, height: 12)
        -                context.fill(Path(ballRect), with: .color(.white))
        +                context.fill(Path(ballRect), with: .color(.black))
                     }
        @@
                     Text("0")
        -                .foregroundColor(.white.opacity(0.3))
        +                .foregroundColor(.black.opacity(0.3))
                 }
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: 4)

        #expect(updated.contains("Color.white"))
        #expect(updated.contains(".color(.black.opacity(0.2))"))
        #expect(updated.contains(".color(.black))"))
        #expect(updated.contains(".foregroundColor(.black.opacity(0.3))"))
        #expect(!(updated.contains("Color.black")))
    }

    @Test
    func applyValidatedDiffIgnoresContextOnlySeparatorHunks() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
          // MARK: - State
          @State private var pulse = false

          private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

          // MARK: - Body
          var body: some View {
            VStack(spacing: 14) {
              Text("Cookie")
            }
          }
        }
        """
        let diff = """
        --- ContentView.swift
        +++ ContentView.swift
        @@
         struct ContentView: View {
           // MARK: - State
           @State private var pulse = false
        @@
           private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        +
        +  private let punkAccent = Color.pink
         
           // MARK: - Body
           var body: some View {
        -    VStack(spacing: 14) {
        +    VStack(spacing: 10) {
               Text("Cookie")
             }
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: 1)

        #expect(updated.contains("private let punkAccent = Color.pink"))
        #expect(updated.contains("VStack(spacing: 10)"))
        #expect(!(updated.contains("VStack(spacing: 14)")))
    }

    @Test
    func applyValidatedDiffAllowsUnlimitedHunksWhenUnbounded() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("One")
                    Text("Two")
                    Text("Three")
                    Text("Four")
                    Text("Five")
                }
            }
        }
        """
        let diff = """
        --- ContentView.swift
        +++ ContentView.swift
        @@
        -            Text("One")
        +            Text("First")
        @@
        -            Text("Two")
        +            Text("Second")
        @@
        -            Text("Three")
        +            Text("Third")
        @@
        -            Text("Four")
        +            Text("Fourth")
        @@
        -            Text("Five")
        +            Text("Fifth")
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: nil)

        #expect(updated.contains("Text(\"First\")"))
        #expect(updated.contains("Text(\"Fifth\")"))
        #expect(!(updated.contains("Text(\"One\")")))
        #expect(!(updated.contains("Text(\"Five\")")))
    }

    @Test
    func applyValidatedDiffKeepsCharacterCapOnlyWhenBounded() throws {
        let longText = String(repeating: "a", count: ContentViewRepairSupport.maximumDiffCharacters + 1)
        let source = [
            "import SwiftUI",
            "",
            "struct ContentView: View {",
            "    var body: some View {",
            "        Text(\"\(longText)\")",
            "    }",
            "}",
        ].joined(separator: "\n")
        let diff = [
            "--- ContentView.swift",
            "+++ ContentView.swift",
            "@@",
            "-        Text(\"\(longText)\")",
            "+        Text(\"Updated\")",
        ].joined(separator: "\n")

        let updated = try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: nil)

        #expect(updated.contains("Text(\"Updated\")"))
        #expect(throws: ToolGenerationError.invalidRepairPatch) {
            try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: 1)
        }
    }

    @Test
    func applyValidatedDiffRejectsDiffWithOnlyContextHunks() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let diff = """
        --- ContentView.swift
        +++ ContentView.swift
        @@
         struct ContentView: View {
             var body: some View {
        """

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
            try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: nil)
        }
    }

    @Test
    func applyValidatedDiffStripsApplyPatchEnvelope() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
          var body: some View {
            NavigationView {
              VStack(spacing: 12) {
                Text("MemoryKeeper")
              }
              .padding()
              .navigationTitle("MemoryKeeper")
            }
            .frame(minWidth: 760, minHeight: 520)
          }
        }
        """
        let diff = """
        *** Begin Patch
        *** Update File: Sources/MemoryKeeper/ContentView.swift
        @@
          var body: some View {
        -    NavigationView {
        -      VStack(spacing: 12) {
        -        Text("MemoryKeeper")
        -      }
        -      .padding()
        -      .navigationTitle("MemoryKeeper")
        -    }
        +    VStack(spacing: 12) {
        +      Text("MemoryKeeper")
        +    }
        +    .padding()
            .frame(minWidth: 760, minHeight: 520)
          }
        *** End of File
        *** End Patch
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: nil)
        let summary = ContentViewRepairSupport.sanitizedRepairDiffSummary(diff)

        #expect(!(updated.contains("NavigationView")))
        #expect(updated.contains("VStack(spacing: 12)"))
        #expect(!(summary.contains("*** End Patch")))
        #expect(!(summary.contains("*** End of File")))
    }

    @Test
    func applyValidatedDiffStripsMarkdownFenceAndProse() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let diff = """
        Here is the diff:
        ```diff
        @@ -3,7 +3,7 @@
         struct ContentView: View {
             var body: some View {
        -        Text("One")
        +        Text("Two")
             }
         }
        ```
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: 1)

        #expect(updated.contains("Text(\"Two\")"))
    }

    @Test
    func applyValidatedDiffIgnoresVisibleThinkingAndUsesFinalDiffFence() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let diff = """
        <|channel>thought
        I should inspect the Swift first.
        ```swift
        Text("not a diff")
        ```
        Here is a bad scratch diff:
        ```diff
        @@ -1,1 +1,1 @@
        -missing
        +wrong
        ```
        <channel|>```diff
        --- ContentView.swift
        +++ ContentView.swift
        @@ -3,7 +3,7 @@
         struct ContentView: View {
             var body: some View {
        -        Text("One")
        +        Text("Two")
             }
         }
        ```
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: 1)

        #expect(updated.contains("Text(\"Two\")"))
        #expect(!(updated.contains("Text(\"One\")")))
    }

    @Test
    func applyValidatedDiffRejectsAmbiguousContext() {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("One")
                    Text("One")
                }
            }
        }
        """
        let diff = """
        @@ -1,3 +1,3 @@
        -        Text("One")
        +        Text("Two")
        """

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
            try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: 1)
        }
    }

    @Test
    func applyValidatedDiffAllowsLargeUniqueHunk() throws {
        let rows = (1...85).map { "            Text(\"Row \($0)\")" }
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
        \(rows.joined(separator: "\n"))
                    Text("Old Footer")
                }
            }
        }
        """
        let hunk = (["@@"] + rows.map { " \($0)" } + [
            "-            Text(\"Old Footer\")",
            "+            Text(\"New Footer\")"
        ]).joined(separator: "\n")
        let diff = """
        --- ContentView.swift
        +++ ContentView.swift
        \(hunk)
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(diff, to: source, maximumHunks: 1)

        #expect(hunk.components(separatedBy: .newlines).count > 80)
        #expect(updated.contains("Text(\"New Footer\")"))
        #expect(!(updated.contains("Text(\"Old Footer\")")))
    }
}
