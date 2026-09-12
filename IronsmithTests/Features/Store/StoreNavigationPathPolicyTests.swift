import Testing
@testable import Ironsmith

struct StoreNavigationPathPolicyTests {
    @Test
    func programmaticSidebarChangePreservesDeepLinkedDetailOnce() {
        var policy = StoreNavigationPathPolicy()

        policy.preservePathForNextSidebarChange(true)
        let clearsProgrammaticChange = policy.shouldClearPathForSidebarChange()
        let clearsFollowingUserChange = policy.shouldClearPathForSidebarChange()

        #expect(!clearsProgrammaticChange)
        #expect(clearsFollowingUserChange)
    }

    @Test
    func unchangedSidebarDoesNotConsumeAFutureUserChange() {
        var policy = StoreNavigationPathPolicy()

        policy.preservePathForNextSidebarChange(false)
        let clearsUserChange = policy.shouldClearPathForSidebarChange()

        #expect(clearsUserChange)
    }
}
