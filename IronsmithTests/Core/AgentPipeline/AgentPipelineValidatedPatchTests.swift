import AnyLanguageModel
import Foundation
import ImageIO
import SwiftData
import Testing
@testable import Ironsmith

extension AgentPipelineTests {
    @Test
    func applyValidatedSearchReplacePatchAppliesSingleBlock() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let patch = """
        <<<<<<< SEARCH
                Text("One")
        =======
                Text("Two")
        >>>>>>> REPLACE
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated.contains("Text(\"Two\")"))
        #expect(!(updated.contains("Text(\"One\")")))
        let summary = ContentViewRepairSupport.sanitizedSearchReplacePatchSummary(patch)
        #expect(summary.contains("<<<<<<< SEARCH"))
        #expect(summary.contains("Text(\"One\")"))
    }

    @Test
    func applyValidatedSearchReplacePatchAppliesMultipleBlocksSequentially() throws {
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
        let patch = """
        <<<<<<< SEARCH
                    Text("One")
        =======
                    Text("First")
        >>>>>>> REPLACE
        <<<<<<< SEARCH
                    Text("Two")
        =======
                    Text("Second")
        >>>>>>> REPLACE
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 2
        )

        #expect(updated.contains("Text(\"First\")"))
        #expect(updated.contains("Text(\"Second\")"))
        #expect(!(updated.contains("Text(\"One\")")))
        #expect(!(updated.contains("Text(\"Two\")")))
    }

    @Test
    func applyValidatedSearchReplacePatchAllowsDeletion() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("Keep")
                    Text("Delete")
                }
            }
        }
        """
        let patch = """
        <<<<<<< SEARCH
                    Text("Delete")
        =======
        >>>>>>> REPLACE
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated.contains("Text(\"Keep\")"))
        #expect(!(updated.contains("Text(\"Delete\")")))
    }

    @Test
    func applyValidatedSearchReplacePatchAllowsInsertBefore() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("Second")
                }
            }
        }
        """
        let patch = """
        <<<<<<< INSERT_BEFORE
                    Text("Second")
        =======
                    Text("First")
        >>>>>>> INSERT
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated.contains("Text(\"First\")\n            Text(\"Second\")"))
    }

    @Test
    func applyValidatedSearchReplacePatchAllowsInsertAfter() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("First")
                }
            }
        }
        """
        let patch = """
        <<<<<<< INSERT_AFTER
                    Text("First")
        =======
                    Text("Second")
        >>>>>>> INSERT
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated.contains("Text(\"First\")\n            Text(\"Second\")"))
    }

    @Test
    func applySearchReplacePatchBestEffortAppliesValidBlocksAndSkipsInvalidBlocks() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                VStack {
                    Text("Old")
                    Text("Keep")
                }
            }
        }
        """
        let patch = """
        <<<<<<< SEARCH
                    Text("Old")
        =======
                    Text("New")
        >>>>>>> REPLACE
        <<<<<<< SEARCH
                    Text("Missing")
        =======
                    Text("Never")
        >>>>>>> REPLACE
        <<<<<<< SEARCH
        =======
                    Text("Empty")
        >>>>>>> REPLACE
        """

        let result = try ContentViewRepairSupport.applySearchReplacePatchBestEffort(
            patch,
            to: source,
            maximumPatchBlocks: 3
        )

        #expect(result.appliedBlockCount == 1)
        #expect(result.skippedBlocks.count == 2)
        #expect(result.source.contains("Text(\"New\")"))
        #expect(result.source.contains("Text(\"Keep\")"))
        #expect(!(result.source.contains("Text(\"Old\")")))
        #expect(!(result.source.contains("Text(\"Never\")")))
    }

    @Test
    func applyValidatedSearchReplacePatchUsesWhitespaceNormalizedLineBlockMatch() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                HStack   {
                    Text("One")
                }
            }
        }
        """
        let patch = """
        <<<<<<< SEARCH
                HStack {
                    Text("One")
                }
        =======
                VStack {
                    Text("Two")
                }
        >>>>>>> REPLACE
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated.contains("VStack"))
        #expect(updated.contains("Text(\"Two\")"))
        #expect(!(updated.contains("HStack")))
    }

    @Test
    func applyValidatedSearchReplacePatchUsesUniqueNearNormalizedLineBlockMatch() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            @State private var recordedNotes: [RecordedNote] = []
            @State private var recordStartDate: Date?
            @State private var activeRecordingNoteIDs: [Int: UUID] = [:]
            @State private var playbackTasks: [DispatchWorkItem] = []
        }
        """
        let patch = """
        <<<<<<< SEARCH
            @State private var recordedNotes: [RecordedNote] = []
            @State private var recordStartDate: Date?
            @State private var activeRecordingStarts: [Int: TimeInterval] = [:]
            @State private var playbackTasks: [DispatchWorkItem] = []
        =======
            @State private var recordedNotes: [RecordedNote] = []
            @State private var recordStartDate: Date?
            @State private var activeRecordingNoteIDs: [Int: UUID] = [:]
            @State private var heldNotes: Set<Int> = []
            @State private var playbackTasks: [DispatchWorkItem] = []
        >>>>>>> REPLACE
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated.contains("heldNotes"))
        #expect(updated.contains("activeRecordingNoteIDs"))
        #expect(!(updated.contains("activeRecordingStarts")))
    }

    @Test
    func applyValidatedSearchReplacePatchAllowsBroadLargeModelPatchWithinCharacterCap() throws {
        let source = (1...16)
            .map { #"Text("Old \#($0)")"# }
            .joined(separator: "\n")
        let patch = (1...16)
            .map { index in
                """
                <<<<<<< SEARCH
                Text("Old \(index)")
                =======
                Text("New \(index)")
                >>>>>>> REPLACE
                """
            }
            .joined(separator: "\n")

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: ToolGenerationRepairPolicy.largeModelPatchBlocksPerTurn
        )

        #expect(updated.contains(#"Text("New 16")"#))
        #expect(!(updated.contains(#"Text("Old 16")"#)))
    }

    @Test
    func applyValidatedSearchReplacePatchAllowsPatchAboveOldCharacterCap() throws {
        let longText = String(repeating: "a", count: 40_000)
        let source = "Text(\"\(longText)\")"
        let patch = """
        <<<<<<< SEARCH
        \(source)
        =======
        Text("Updated")
        >>>>>>> REPLACE
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated == #"Text("Updated")"#)
    }

    @Test
    func applyValidatedSearchReplacePatchRejectsAmbiguousDuplicateSearch() {
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
        let patch = """
        <<<<<<< SEARCH
                    Text("One")
        =======
                    Text("Two")
        >>>>>>> REPLACE
        """

        #expect(throws: ContentViewRepairSupport.SearchReplacePatchValidationError.self) {
            try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
                patch,
                to: source,
                maximumPatchBlocks: 1
            )
        }
    }

    @Test
    func applyValidatedSearchReplacePatchRejectsMissingSearch() {
        let source = "Text(\"One\")"
        let patch = """
        <<<<<<< SEARCH
        =======
        Text("Two")
        >>>>>>> REPLACE
        """

        #expect(throws: ContentViewRepairSupport.SearchReplacePatchValidationError.self) {
            try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
                patch,
                to: source,
                maximumPatchBlocks: 1
            )
        }
    }

    @Test
    func applyValidatedSearchReplacePatchRejectsBlockCap() {
        let source = """
        Text("One")
        Text("Two")
        """
        let patch = """
        <<<<<<< SEARCH
        Text("One")
        =======
        Text("First")
        >>>>>>> REPLACE
        <<<<<<< SEARCH
        Text("Two")
        =======
        Text("Second")
        >>>>>>> REPLACE
        """

        #expect(throws: ContentViewRepairSupport.SearchReplacePatchValidationError.self) {
            try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
                patch,
                to: source,
                maximumPatchBlocks: 1
            )
        }
    }

    @Test
    func applyValidatedSearchReplacePatchRejectsCharacterCap() {
        let longText = String(repeating: "a", count: ContentViewRepairSupport.maximumPatchCharacters + 1)
        let source = "Text(\"\(longText)\")"
        let patch = """
        <<<<<<< SEARCH
        \(source)
        =======
        Text("Updated")
        >>>>>>> REPLACE
        """

        #expect(throws: ContentViewRepairSupport.SearchReplacePatchValidationError.self) {
            try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
                patch,
                to: source,
                maximumPatchBlocks: 1
            )
        }
    }

    @Test
    func applyValidatedSearchReplacePatchAllowsMarkerTextInReplacement() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let patch = """
        <<<<<<< SEARCH
                Text("One")
        =======
                ======= Text("Two")
        >>>>>>> REPLACE
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated.contains("======= Text(\"Two\")"))
    }

    @Test
    func applyValidatedSearchReplacePatchPreservesProseAndFencesInsideReplacement() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let patch = #"""
        Here is the patch:
        <<<<<<< SEARCH
                Text("One")
        =======
                Text("""
                Note: keep this line
                ```swift
                let value = 1
                ```
                """)
        >>>>>>> REPLACE
        """#

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated.contains("Note: keep this line"))
        #expect(updated.contains("```swift"))
        #expect(updated.contains("let value = 1"))
        #expect(!(updated.contains("Here is the patch:")))
        #expect(!(updated.contains("Text(\"One\")")))
    }

    @Test
    func applyValidatedSearchReplacePatchStripsMarkdownFenceAndVisibleThinking() throws {
        let source = """
        import SwiftUI

        struct ContentView: View {
            var body: some View {
                Text("One")
            }
        }
        """
        let patch = """
        <|channel>thought
        I should inspect the source first.
        ```swift
        Text("not a patch")
        ```
        <channel|>```text
        <<<<<<< SEARCH
                Text("One")
        =======
                Text("Two")
        >>>>>>> REPLACE
        ```
        """

        let updated = try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
            patch,
            to: source,
            maximumPatchBlocks: 1
        )

        #expect(updated.contains("Text(\"Two\")"))
        #expect(!(updated.contains("Text(\"One\")")))
    }
}
