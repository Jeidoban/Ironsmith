import Foundation
import Testing
@testable import Ironsmith

struct AppRoutingTests {
    @Test
    func appRouteParsesSettingsRootURL() throws {
        let url = try #require(URL(string: "com.jeidoban.ironsmith://settings"))

        #expect(IronsmithAppRoute(url: url) == .settings(.root))
    }

    @Test
    func appRouteParsesAddProviderURL() throws {
        let url = try #require(URL(string: "com.jeidoban.ironsmith://settings/add-provider"))

        #expect(IronsmithAppRoute(url: url) == .settings(.addProvider(initialKind: nil)))
    }

    @Test
    func appRouteParsesAddProviderURLWithInitialKind() throws {
        let url = try #require(URL(string: "com.jeidoban.ironsmith://settings/add-provider?kind=openai"))

        #expect(IronsmithAppRoute(url: url) == .settings(.addProvider(initialKind: .openAI)))
    }

    @Test
    func appRouteKeepsAddProviderURLWhenInitialKindIsInvalid() throws {
        let url = try #require(URL(string: "com.jeidoban.ironsmith://settings/add-provider?kind=bogus"))

        #expect(IronsmithAppRoute(url: url) == .settings(.addProvider(initialKind: nil)))
    }

    @Test
    func appRouteParsesProviderEditorURL() throws {
        let url = try #require(URL(string: "com.jeidoban.ironsmith://settings/provider/ironsmith"))

        #expect(IronsmithAppRoute(url: url) == .settings(.editProvider(identifier: "ironsmith")))
    }

    @Test
    func appRouteParsesIronsmithCreditsURL() throws {
        let url = try #require(URL(string: "com.jeidoban.ironsmith://settings/provider/ironsmith/credits"))

        #expect(IronsmithAppRoute(url: url) == .settings(.buyIronsmithCredits))
    }

    @Test
    func appRouteParsesModelSelectionURL() throws {
        let url = try #require(URL(string: "com.jeidoban.ironsmith://settings/model-selection"))

        #expect(IronsmithAppRoute(url: url) == .settings(.modelSelection))
    }

    @Test
    func appRouteIgnoresOAuthCallbackURL() throws {
        let url = try #require(URL(string: "com.jeidoban.ironsmith://auth/callback?code=test"))

        #expect(IronsmithAppRoute(url: url) == nil)
    }

    @Test
    func appRouteRejectsUnsupportedURLs() throws {
        let invalidSchemeURL = try #require(URL(string: "https://settings"))
        let unknownPathURL = try #require(URL(string: "com.jeidoban.ironsmith://settings/unknown"))
        let unknownHostURL = try #require(URL(string: "com.jeidoban.ironsmith://tools"))

        #expect(IronsmithAppRoute(url: invalidSchemeURL) == nil)
        #expect(IronsmithAppRoute(url: unknownPathURL) == nil)
        #expect(IronsmithAppRoute(url: unknownHostURL) == nil)
    }

    @MainActor
    @Test
    func routeStoreOpensSettingsAndStoresPendingRoute() {
        let capture = SettingsWindowOpenCapture()
        let store = IronsmithRouteStore(openSettingsWindow: {
            capture.open()
        })

        store.open(.settings(.addProvider(initialKind: .openAI)))

        #expect(capture.openCount == 1)
        #expect(store.pendingSettingsRoute == .addProvider(initialKind: .openAI))
        #expect(store.consumeSettingsRoute() == .addProvider(initialKind: .openAI))
        #expect(store.pendingSettingsRoute == nil)
    }

    @MainActor
    @Test
    func routeStoreHandlesSupportedURL() throws {
        let capture = SettingsWindowOpenCapture()
        let store = IronsmithRouteStore(openSettingsWindow: {
            capture.open()
        })
        let url = try #require(URL(string: "com.jeidoban.ironsmith://settings/provider/openai"))

        #expect(store.handle(url))
        #expect(capture.openCount == 1)
        #expect(store.pendingSettingsRoute == .editProvider(identifier: "openai"))
    }

    @MainActor
    @Test
    func routeStoreIgnoresUnsupportedURL() throws {
        let capture = SettingsWindowOpenCapture()
        let store = IronsmithRouteStore(openSettingsWindow: {
            capture.open()
        })
        let url = try #require(URL(string: "com.jeidoban.ironsmith://auth/callback?code=test"))

        #expect(!store.handle(url))
        #expect(capture.openCount == 0)
        #expect(store.pendingSettingsRoute == nil)
    }
}

@MainActor
private final class SettingsWindowOpenCapture {
    private(set) var openCount = 0

    func open() {
        openCount += 1
    }
}
