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

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
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

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
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

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
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

        #expect(throws: ToolGenerationError.invalidRepairPatch) {
            try ContentViewRepairSupport.applyValidatedSearchReplacePatch(
                patch,
                to: source,
                maximumPatchBlocks: 1
            )
        }
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
