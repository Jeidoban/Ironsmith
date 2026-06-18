import Foundation

struct ToolAppBundleRequest: Equatable, Sendable {
    let displayName: String
    let executableName: String
    let bundleIdentifier: String
    let packageRootURL: URL
    let sandboxEnabled: Bool
    let sandboxPermissions: GeneratedAppSandboxPermissions
    let resourcePermissions: GeneratedAppResourcePermissions
    let iconPrompt: String?

    init(
        displayName: String,
        executableName: String,
        bundleIdentifier: String,
        packageRootURL: URL,
        sandboxEnabled: Bool,
        sandboxPermissions: GeneratedAppSandboxPermissions = .default,
        resourcePermissions: GeneratedAppResourcePermissions = .none,
        iconPrompt: String? = nil
    ) {
        self.displayName = displayName
        self.executableName = executableName
        self.bundleIdentifier = bundleIdentifier
        self.packageRootURL = packageRootURL
        self.sandboxEnabled = sandboxEnabled
        self.sandboxPermissions = sandboxPermissions
        self.resourcePermissions = resourcePermissions
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
            sandboxPermissions: sandboxPermissions,
            resourcePermissions: resourcePermissions,
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
