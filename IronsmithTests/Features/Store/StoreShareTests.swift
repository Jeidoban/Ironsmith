import Foundation
import Testing

@testable import Ironsmith

struct StoreShareTests {
    @Test
    func appWebsiteURLMatchesThePublicStorePage() {
        let appID = "11111111-2222-4333-8444-555555555555"

        #expect(
            IronsmithStoreConstants.appWebsiteURL(appID: appID).absoluteString
                == "https://ironsmith.app/store/apps/\(appID)"
        )
    }
}
