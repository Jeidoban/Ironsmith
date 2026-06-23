import Foundation

struct ToolAppBundleRequest: Equatable, Sendable {
    let displayName: String
    let executableName: String
    let bundleIdentifier: String
    let packageRootURL: URL
    let settings: ToolGenerationSettings
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

    var sandboxPermissions: GeneratedAppSandboxPermissions {
        settings.sandboxPermissions
    }

    var resourcePermissions: GeneratedAppResourcePermissions {
        settings.resourcePermissions
    }

    init(
        displayName: String,
        executableName: String,
        bundleIdentifier: String,
        packageRootURL: URL,
        settings: ToolGenerationSettings,
        iconPrompt: String? = nil
    ) {
        self.displayName = displayName
        self.executableName = executableName
        self.bundleIdentifier = bundleIdentifier
        self.packageRootURL = packageRootURL
        self.settings = settings
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

    static func forTool(_ tool: Tool, defaults: ToolGenerationSettings) -> ToolAppBundleRequest {
        ToolAppBundleRequest(
            displayName: tool.name,
            executableName: tool.executableName,
            bundleIdentifier: tool.bundleIdentifier,
            packageRootURL: tool.packageRootURL,
            settings: tool.generationSettings(defaults: defaults),
            iconPrompt: nil
        )
    }

    static func forToolPreservingExistingBundlePermissions(_ tool: Tool) -> ToolAppBundleRequest {
        let defaults = ToolGenerationSettings(
            appKind: tool.appKind,
            menuBarSystemImage: tool.validatedMenuBarSystemImage,
            sandboxEnabled: tool.sandboxEnabled,
            sandboxPermissions: GeneratedAppSandboxPermissions.inferred(
                fromPackageAt: tool.packageRootURL,
                sandboxEnabled: tool.sandboxEnabled
            ),
            resourcePermissions: GeneratedAppResourcePermissions.inferred(fromAppBundleAt: tool.appBundleURL)
        )
        return forTool(tool, defaults: defaults)
    }
}
