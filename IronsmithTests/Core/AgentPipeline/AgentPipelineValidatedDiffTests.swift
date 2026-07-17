import Foundation
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func applyValidatedDiffAppliesUnifiedHunkWithUniqueContext() throws {
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
        @@ -3,5 +3,5 @@
         struct ContentView: View {
             var body: some View {
        -        Text("One")
        +        Text("Two")
             }
         }
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(
            diff,
            to: source,
            maximumHunks: 1
        )

        #expect(updated.contains("Text(\"Two\")"))
        #expect(!(updated.contains("Text(\"One\")")))
    }

    @Test
    func applyValidatedDiffIgnoresIncorrectHunkCounts() throws {
        let source = """
        struct ContentView {
            let title = "One"
            let subtitle = "Keep"
        }
        """
        let diff = """
        --- a/ContentView.swift
        +++ b/ContentView.swift
        @@ -30,7 +30,7 @@
         struct ContentView {
        -    let title = "One"
        +    let title = "Two"
             let subtitle = "Keep"
         }
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(
            diff,
            to: source,
            maximumHunks: 1
        )

        #expect(updated.contains("let title = \"Two\""))
    }

    @Test
    func applyValidatedDiffAcceptsHeaderWithoutRangesAndMissingContextMarkers() throws {
        let source = """
        struct ContentView {
            let title = "One"
            let subtitle = "Keep"
        }
        """
        let diff = """
        --- ContentView.swift
        +++ ContentView.swift
        @@
        struct ContentView {
        -    let title = "One"
        +    let title = "Two"
            let subtitle = "Keep"
        }
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(
            diff,
            to: source,
            maximumHunks: 1
        )

        #expect(updated.contains("let title = \"Two\""))
        #expect(updated.contains("let subtitle = \"Keep\""))
    }

    @Test
    func applyValidatedDiffAcceptsApplyPatchEnvelopeAndCommonIndentation() throws {
        let source = """
        struct ContentView {
            let title = "One"
        }
        """
        let diff = """
        Here is the diff:
        ```diff
            *** Begin Patch
            *** Update File: Sources/App/ContentView.swift
            @@
            -    let title = "One"
            +    let title = "Two"
            *** End Patch
        ```
        """

        let updated = try ContentViewRepairSupport.applyValidatedDiff(
            diff,
            to: source,
            maximumHunks: 1
        )

        #expect(updated.contains("let title = \"Two\""))
    }

    @Test
    func applyValidatedDiffRejectsAnotherFile() {
        let diff = """
        --- a/Package.swift
        +++ b/Package.swift
        @@ -1 +1 @@
        -let old = true
        +let new = true
        """

        #expect(throws: ContentViewRepairSupport.UnifiedDiffValidationError.self) {
            try ContentViewRepairSupport.applyValidatedDiff(
                diff,
                to: "let old = true",
                maximumHunks: 1
            )
        }
    }

    @Test
    func applyValidatedDiffRejectsAmbiguousContext() {
        let source = """
        Text("One")
        Text("One")
        """
        let diff = """
        @@
        -Text("One")
        +Text("Two")
        """

        #expect(throws: ContentViewRepairSupport.UnifiedDiffValidationError.self) {
            try ContentViewRepairSupport.applyValidatedDiff(
                diff,
                to: source,
                maximumHunks: 1
            )
        }
    }

    @Test
    func applyCompletedDiffHunksOnlyAppliesProvablyCompleteHunks() throws {
        let source = """
        Text("One")
        Text("Two")
        """
        let interruptedDiff = """
        --- a/ContentView.swift
        +++ b/ContentView.swift
        @@ -1 +1 @@
        -Text("One")
        +Text("First")
        @@ -2 +2 @@
        -Text("Two")
        +Text("
        """

        let application = try ContentViewRepairSupport.applyCompletedDiffHunks(
            interruptedDiff,
            to: source,
            maximumHunks: 1
        )
        let result = try #require(application)

        #expect(result.source.contains("Text(\"First\")"))
        #expect(result.source.contains("Text(\"Two\")"))
        #expect(result.appliedHunkCount == 1)
    }
}
