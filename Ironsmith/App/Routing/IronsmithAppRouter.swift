import AppKit
import Foundation
import Observation

enum IronsmithAppRoute: Equatable {
    case settings(IronsmithSettingsRoute)

    init?(url: URL) {
        guard let settingsRoute = IronsmithSettingsRoute(url: url) else {
            return nil
        }
        self = .settings(settingsRoute)
    }
}

enum IronsmithSettingsRoute: Equatable {
    case root
    case addProvider(initialKind: ProviderKind?)
    case editProvider(identifier: String)
    case buyIronsmithCredits
    case modelSelection

    init?(url: URL) {
        guard url.scheme == IronsmithOAuthRedirect.appCallbackScheme else {
            return nil
        }

        let host = url.host()
        let path = url.pathComponents.filter { $0 != "/" }

        if host == "auth", path == ["callback"] {
            return nil
        }

        guard host == "settings" else {
            return nil
        }

        switch path {
        case []:
            self = .root
        case ["add-provider"]:
            self = .addProvider(initialKind: Self.providerKindQueryValue(from: url))
        case ["model-selection"]:
            self = .modelSelection
        case ["provider", ProviderKind.ironsmith.rawValue, "credits"]:
            self = .buyIronsmithCredits
        default:
            if path.count == 2, path[0] == "provider" {
                self = .editProvider(identifier: path[1])
                return
            }
            return nil
        }
    }

    private static func providerKindQueryValue(from url: URL) -> ProviderKind? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "kind" }?
            .value
            .flatMap(ProviderKind.init(rawValue:))
    }
}

@MainActor
@Observable
final class IronsmithRouteStore {
    private let openSettingsWindow: @MainActor @Sendable () -> Void
    private(set) var pendingSettingsRoute: IronsmithSettingsRoute?

    init(
        openSettingsWindow: @escaping @MainActor @Sendable () -> Void
    ) {
        self.openSettingsWindow = openSettingsWindow
    }

    func open(_ route: IronsmithAppRoute) {
        switch route {
        case .settings(let settingsRoute):
            pendingSettingsRoute = settingsRoute
            openSettingsWindow()
        }
    }

    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard let route = IronsmithAppRoute(url: url) else {
            return false
        }
        open(route)
        return true
    }

    func consumeSettingsRoute() -> IronsmithSettingsRoute? {
        defer { pendingSettingsRoute = nil }
        return pendingSettingsRoute
    }
}
