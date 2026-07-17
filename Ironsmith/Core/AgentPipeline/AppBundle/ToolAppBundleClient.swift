import Foundation

struct ToolAppBundleClient {
    var buildInternalApp: (_ request: ToolAppBundleRequest) async throws -> URL
    var exportApp: (_ request: ToolAppBundleRequest, _ applicationsDirectoryURL: URL) async throws -> URL
    var launchApp: (_ appBundleURL: URL) async throws -> Void
    var terminateApp: (_ appBundleURL: URL) async throws -> Void
    var isAppRunning: (_ appBundleURL: URL) async -> Bool
    var appExists: (_ appBundleURL: URL) -> Bool

    init(
        buildInternalApp: @escaping (_ request: ToolAppBundleRequest) async throws -> URL,
        exportApp: @escaping (
            _ request: ToolAppBundleRequest,
            _ applicationsDirectoryURL: URL
        ) async throws -> URL,
        launchApp: @escaping (_ appBundleURL: URL) async throws -> Void,
        terminateApp: @escaping (_ appBundleURL: URL) async throws -> Void = { _ in },
        isAppRunning: @escaping (_ appBundleURL: URL) async -> Bool = { _ in false },
        appExists: @escaping (_ appBundleURL: URL) -> Bool
    ) {
        self.buildInternalApp = buildInternalApp
        self.exportApp = exportApp
        self.launchApp = launchApp
        self.terminateApp = terminateApp
        self.isAppRunning = isAppRunning
        self.appExists = appExists
    }

    static let applicationsDirectoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

    static func noOp() -> ToolAppBundleClient {
        ToolAppBundleClient(
            buildInternalApp: { request in request.internalAppBundleURL },
            exportApp: { request, applicationsDirectoryURL in
                applicationsDirectoryURL.appendingPathComponent(
                    "\(ToolNameSanitizer.appBundleName(from: request.displayName)).app",
                    isDirectory: true
                )
            },
            launchApp: { _ in },
            terminateApp: { _ in },
            isAppRunning: { _ in false },
            appExists: { _ in true }
        )
    }

    static func live(
        fileManager: FileManager = .default,
        fileClient: AgentFileClient = .live,
        processClient: SwiftPackageProcessClient = .live,
        iconClient: ToolIconClient? = nil
    ) -> ToolAppBundleClient {
        let iconClient = iconClient ?? ToolIconClient.cachedOnly()
        return ToolAppBundleClient(
            buildInternalApp: { request in
                try await buildApp(
                    request: request,
                    destinationAppURL: request.internalAppBundleURL,
                    showsInDock: false,
                    quitsOnLastWindowClose: request.appKind == .window,
                    fileManager: fileManager,
                    fileClient: fileClient,
                    processClient: processClient,
                    iconClient: iconClient
                )
            },
            exportApp: { request, applicationsDirectoryURL in
                let destinationURL = try exportDestinationURL(
                    for: request,
                    applicationsDirectoryURL: applicationsDirectoryURL,
                    fileManager: fileManager
                )
                return try await buildApp(
                    request: request,
                    destinationAppURL: destinationURL,
                    showsInDock: request.appKind == .window,
                    quitsOnLastWindowClose: false,
                    fileManager: fileManager,
                    fileClient: fileClient,
                    processClient: processClient,
                    iconClient: iconClient
                )
            },
            launchApp: { appBundleURL in
                try await processClient.launchApp(appBundleURL)
            },
            terminateApp: { appBundleURL in
                try await processClient.terminateApp(appBundleURL)
            },
            isAppRunning: { appBundleURL in
                await processClient.isAppRunning(appBundleURL)
            },
            appExists: { appBundleURL in
                isCompleteAppBundle(appBundleURL, fileManager: fileManager)
            }
        )
    }

    private static func buildApp(
        request: ToolAppBundleRequest,
        destinationAppURL: URL,
        showsInDock: Bool,
        quitsOnLastWindowClose: Bool,
        fileManager: FileManager,
        fileClient: AgentFileClient,
        processClient: SwiftPackageProcessClient,
        iconClient: ToolIconClient
    ) async throws -> URL {
        try writeFixedAppEntrySource(for: request, fileManager: fileManager)

        let buildResult = try await processClient.buildRelease(request.packageRootURL)
        guard buildResult.succeeded else {
            throw ToolAppBundleError.releaseBuildFailed(buildResult.combinedOutput)
        }

        let binDirectory = try await processClient.showReleaseBinPath(request.packageRootURL)
        let executableSourceURL = binDirectory.appendingPathComponent(request.executableName)
        guard fileManager.fileExists(atPath: executableSourceURL.path) else {
            throw ToolAppBundleError.missingExecutable(executableSourceURL.path)
        }

        try fileManager.createDirectory(
            at: destinationAppURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let stagedAppURL = temporarySiblingAppBundleURL(for: destinationAppURL, label: "staged")
        defer {
            try? fileManager.removeItem(at: stagedAppURL)
        }

        let contentsURL = stagedAppURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

        let executableDestinationURL = macOSURL.appendingPathComponent(request.executableName)
        try fileManager.copyItem(at: executableSourceURL, to: executableDestinationURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executableDestinationURL.path
        )

        let iconFileName = await copyIconIfAvailable(
            request: request,
            resourcesURL: resourcesURL,
            fileManager: fileManager,
            iconClient: iconClient
        )

        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        try writeInfoPlist(
            for: request,
            to: infoPlistURL,
            showsInDock: showsInDock,
            quitsOnLastWindowClose: quitsOnLastWindowClose,
            iconFileName: iconFileName
        )

        let entitlementsURL: URL?
        if request.sandboxEnabled {
            entitlementsURL = request.layout.sandboxEntitlementsURL
            try writeSandboxEntitlements(for: request, to: entitlementsURL!)
        } else {
            entitlementsURL = nil
            try? fileClient.removeItemIfExists(request.layout.sandboxEntitlementsURL)
        }

        let signResult = try await processClient.signAdHoc(stagedAppURL, entitlementsURL)
        guard signResult.succeeded else {
            throw ToolAppBundleError.signingFailed(signResult.combinedOutput)
        }

        let stagedVerifyResult = try await processClient.verifyCodeSignature(stagedAppURL)
        guard stagedVerifyResult.succeeded else {
            throw ToolAppBundleError.signatureVerificationFailed(stagedVerifyResult.combinedOutput)
        }

        let backupAppURL = try installStagedAppBundle(
            stagedAppURL,
            at: destinationAppURL,
            fileManager: fileManager
        )

        do {
            let verifyResult = try await processClient.verifyCodeSignature(destinationAppURL)
            guard verifyResult.succeeded else {
                throw ToolAppBundleError.signatureVerificationFailed(verifyResult.combinedOutput)
            }
        } catch {
            restoreAppBundleBackup(
                backupAppURL,
                destinationAppURL: destinationAppURL,
                fileManager: fileManager
            )
            throw error
        }

        removeAppBundleBackup(backupAppURL, fileManager: fileManager)

        await processClient.stripQuarantine(destinationAppURL)
        return destinationAppURL
    }

    private static func writeFixedAppEntrySource(
        for request: ToolAppBundleRequest,
        fileManager: FileManager
    ) throws {
        let layout = request.layout
        let appEntryURL = try layout.packageFileURL(for: layout.appEntrySourcePath)
        try fileManager.createDirectory(
            at: appEntryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try layout.fixedAppEntrySource(displayName: request.displayName, settings: request.settings)
            .write(to: appEntryURL, atomically: true, encoding: .utf8)
    }

    private static func temporarySiblingAppBundleURL(for destinationAppURL: URL, label: String) -> URL {
        let baseName = destinationAppURL.deletingPathExtension().lastPathComponent
        let identifier = UUID().uuidString.lowercased()
        return destinationAppURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(baseName).\(label).\(identifier).app", isDirectory: true)
    }

    private static func installStagedAppBundle(
        _ stagedAppURL: URL,
        at destinationAppURL: URL,
        fileManager: FileManager
    ) throws -> URL? {
        guard fileManager.fileExists(atPath: destinationAppURL.path) else {
            try fileManager.moveItem(at: stagedAppURL, to: destinationAppURL)
            return nil
        }

        let backupAppURL = temporarySiblingAppBundleURL(for: destinationAppURL, label: "backup")
        try fileManager.moveItem(at: destinationAppURL, to: backupAppURL)

        do {
            try fileManager.moveItem(at: stagedAppURL, to: destinationAppURL)
        } catch {
            try? fileManager.moveItem(at: backupAppURL, to: destinationAppURL)
            throw error
        }

        return backupAppURL
    }

    private static func restoreAppBundleBackup(
        _ backupAppURL: URL?,
        destinationAppURL: URL,
        fileManager: FileManager
    ) {
        do {
            if fileManager.fileExists(atPath: destinationAppURL.path) {
                try fileManager.removeItem(at: destinationAppURL)
            }
            if let backupAppURL, fileManager.fileExists(atPath: backupAppURL.path) {
                try fileManager.moveItem(at: backupAppURL, to: destinationAppURL)
            }
        } catch {
            AgentDiagnosticsLog.append(
                """
                Failed to restore previous app bundle after replacement failure.
                destination: \(destinationAppURL.path)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 500))
                """
            )
        }
    }

    private static func removeAppBundleBackup(_ backupAppURL: URL?, fileManager: FileManager) {
        guard let backupAppURL,
              fileManager.fileExists(atPath: backupAppURL.path)
        else {
            return
        }
        try? fileManager.removeItem(at: backupAppURL)
    }

    private static func writeInfoPlist(
        for request: ToolAppBundleRequest,
        to url: URL,
        showsInDock: Bool,
        quitsOnLastWindowClose: Bool,
        iconFileName: String?
    ) throws {
        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": request.displayName,
            "CFBundleExecutable": request.executableName,
            "CFBundleIdentifier": request.bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": request.displayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSApplicationCategoryType": "public.app-category.utilities",
            "LSMinimumSystemVersion": "26.0",
        ]

        if let iconFileName {
            plist["CFBundleIconFile"] = iconFileName
        }

        if !showsInDock {
            plist["LSUIElement"] = true
        }

        if quitsOnLastWindowClose {
            plist["IronsmithQuitOnLastWindowClose"] = true
        }

        for permission in request.resourcePermissions.enabledPermissions {
            for usageDescriptionKey in permission.usageDescriptionKeys {
                plist[usageDescriptionKey] = permission.usageDescription
            }
        }

        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private static func writeSandboxEntitlements(for request: ToolAppBundleRequest, to url: URL) throws {
        var entitlements: [String: Any] = [
            "com.apple.security.app-sandbox": true,
        ]
        for permission in request.sandboxPermissions.enabledPermissions {
            entitlements[permission.entitlementKey] = true
        }
        for permission in request.resourcePermissions.enabledPermissions {
            for entitlementKey in permission.sandboxEntitlementKeys {
                entitlements[entitlementKey] = true
            }
        }
        let data = try PropertyListSerialization.data(
            fromPropertyList: entitlements,
            format: .xml,
            options: 0
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func exportDestinationURL(
        for request: ToolAppBundleRequest,
        applicationsDirectoryURL: URL,
        fileManager: FileManager
    ) throws -> URL {
        try fileManager.createDirectory(at: applicationsDirectoryURL, withIntermediateDirectories: true)
        let baseName = safeAppName(request.displayName)
        var candidate = applicationsDirectoryURL.appendingPathComponent("\(baseName).app", isDirectory: true)

        if bundleIdentifier(at: candidate) == request.bundleIdentifier {
            return candidate
        }

        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = applicationsDirectoryURL.appendingPathComponent("\(baseName) \(suffix).app", isDirectory: true)
            if bundleIdentifier(at: candidate) == request.bundleIdentifier {
                return candidate
            }
            suffix += 1
        }

        return candidate
    }

    private static func bundleIdentifier(at appBundleURL: URL) -> String? {
        let plistURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else {
            return nil
        }
        return dictionary["CFBundleIdentifier"] as? String
    }

    private static func isCompleteAppBundle(_ appBundleURL: URL, fileManager: FileManager) -> Bool {
        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let plistURL = contentsURL.appendingPathComponent("Info.plist")
        guard fileManager.fileExists(atPath: plistURL.path),
              let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any],
              let executableName = dictionary["CFBundleExecutable"] as? String,
              !executableName.isEmpty
        else {
            return false
        }

        let executableURL = contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        return fileManager.isExecutableFile(atPath: executableURL.path)
    }

    private static func safeAppName(_ displayName: String) -> String {
        ToolNameSanitizer.appBundleName(from: displayName)
    }

    private static func copyIconIfAvailable(
        request: ToolAppBundleRequest,
        resourcesURL: URL,
        fileManager: FileManager,
        iconClient: ToolIconClient
    ) async -> String? {
        do {
            let sourceURL = try await iconClient.ensureIconAssets(
                ToolIconRequest(
                    displayName: request.displayName,
                    iconPrompt: request.iconPrompt,
                    layout: request.layout
                )
            )
            let pathExtension = sourceURL.pathExtension.isEmpty ? "icns" : sourceURL.pathExtension
            let iconFileName = "AppIcon.\(pathExtension)"
            let bundleIconURL = resourcesURL.appendingPathComponent(iconFileName)
            if fileManager.fileExists(atPath: bundleIconURL.path) {
                try fileManager.removeItem(at: bundleIconURL)
            }
            try fileManager.copyItem(at: sourceURL, to: bundleIconURL)
            return iconFileName
        } catch {
            AgentDiagnosticsLog.append(
                """
                App bundle icon step failed; continuing without a custom icon.
                displayName: \(request.displayName)
                error:
                \(AgentDiagnosticsLog.renderError(error, limit: 500))
                """
            )
            return nil
        }
    }
}
