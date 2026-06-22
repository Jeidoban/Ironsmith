import Foundation

struct ToolAppBundleRequest: Equatable, Sendable {
    let displayName: String
    let executableName: String
    let bundleIdentifier: String
    let packageRootURL: URL
    let settings: ToolGenerationSettings
    let sandboxPermissions: GeneratedAppSandboxPermissions
    let resourcePermissions: GeneratedAppResourcePermissions
    let iconPrompt: String?

    var appKind: ToolAppKind {
        settings.appKind
    }

    var menuBarSystemImage: String {
        settings.menuBarSystemImage
    }

    var sandboxEnabled: Bool {
        settings.sandboxEnabled
    }

    init(
        displayName: String,
        executableName: String,
        bundleIdentifier: String,
        packageRootURL: URL,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions = .default,
        resourcePermissions: GeneratedAppResourcePermissions = .none,
        appKind: ToolAppKind = .window,
        menuBarSystemImage: String = ToolMenuBarSymbol.fallback,
        settings: ToolGenerationSettings? = nil,
        iconPrompt: String? = nil
    ) {
        self.displayName = displayName
        self.executableName = executableName
        self.bundleIdentifier = bundleIdentifier
        self.packageRootURL = packageRootURL
        let resolvedSettings = settings ?? ToolGenerationSettings(
            appKind: appKind,
            menuBarSystemImage: menuBarSystemImage,
            sandboxEnabled: sandboxEnabled,
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions
        )
        self.settings = resolvedSettings
        self.sandboxPermissions = resolvedSettings.sandboxPermissions
        self.resourcePermissions = resolvedSettings.resourcePermissions
        self.iconPrompt = iconPrompt
    }

    var layout: ToolPackageLayout {
        ToolPackageLayout(packageRootURL: packageRootURL, executableName: executableName)
    }

    var internalAppBundleURL: URL {
        packageRootURL.appendingPathComponent(
            "\(ToolNameSanitizer.appBundleName(from: displayName)).app",
            isDirectory: true
        )
    }

    static func forTool(
        _ tool: Tool,
        sandboxPermissions: GeneratedAppSandboxPermissions = .default,
        resourcePermissions: GeneratedAppResourcePermissions = .none
    ) -> ToolAppBundleRequest {
        ToolAppBundleRequest(
            displayName: tool.name,
            executableName: tool.executableName,
            bundleIdentifier: tool.bundleIdentifier,
            packageRootURL: tool.packageRootURL,
            sandboxEnabled: tool.sandboxEnabled,
            settings: tool.generationSettings(
                defaultSandboxPermissions: sandboxPermissions,
                defaultResourcePermissions: resourcePermissions
            ),
            iconPrompt: nil
        )
    }

    static func forToolPreservingExistingBundlePermissions(_ tool: Tool) -> ToolAppBundleRequest {
        forTool(
            tool,
            sandboxPermissions: GeneratedAppSandboxPermissions.inferred(
                fromPackageAt: tool.packageRootURL,
                sandboxEnabled: tool.sandboxEnabled
            ),
            resourcePermissions: GeneratedAppResourcePermissions.inferred(fromAppBundleAt: tool.appBundleURL)
        )
    }
}
