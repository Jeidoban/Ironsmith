import Testing

@testable import Ironsmith

extension ToolLibraryTests {
    @MainActor
    @Test
    func storePublisherLeavesNewListingCopyEmpty() async {
        let inferenceStore = InferenceStore(
            dependencies: Self.inferenceDependencies(
                accountClient: Self.ironsmithAccountClient(balanceCredits: 100)
            )
        )
        inferenceStore.ironsmithSession = Self.ironsmithSession()
        let publisher = ToolLibraryStorePublisher(
            storeClient: .unconfigured,
            iconClient: .live()
        )
        let tool = Tool(
            name: "Clipboard Cleaner",
            packageRootPath: "/tmp/ClipboardCleaner"
        )

        await publisher.beginPublishing(
            tool,
            inferenceStore: inferenceStore,
            tools: [tool]
        )

        #expect(publisher.publishName == tool.name)
        #expect(publisher.publishShortDescription.isEmpty)
        #expect(publisher.publishDescription.isEmpty)
        #expect(publisher.isShowingPublishSheet)
    }
}
