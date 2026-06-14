import Foundation

nonisolated enum GeneratedAppResourcePermission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case camera
    case location
    case contacts
    case calendar
    case photoLibrary
    case appleEvents

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .microphone: return "Microphone"
        case .camera: return "Camera"
        case .location: return "Location"
        case .contacts: return "Contacts"
        case .calendar: return "Calendar"
        case .photoLibrary: return "Photo Library"
        case .appleEvents: return "Apple Events"
        }
    }

    var userDefaultsKey: String {
        "generation.generatedAppResourcePermissions.v1.\(rawValue)"
    }

    var usageDescriptionKeys: [String] {
        switch self {
        case .microphone:
            return ["NSMicrophoneUsageDescription"]
        case .camera:
            return ["NSCameraUsageDescription"]
        case .location:
            return ["NSLocationUsageDescription"]
        case .contacts:
            return ["NSContactsUsageDescription"]
        case .calendar:
            return ["NSCalendarsFullAccessUsageDescription", "NSCalendarsUsageDescription"]
        case .photoLibrary:
            return ["NSPhotoLibraryUsageDescription", "NSPhotoLibraryAddUsageDescription"]
        case .appleEvents:
            return ["NSAppleEventsUsageDescription"]
        }
    }

    var usageDescription: String {
        switch self {
        case .microphone:
            return "This app needs microphone access for features you requested."
        case .camera:
            return "This app needs camera access for features you requested."
        case .location:
            return "This app needs location access for features you requested."
        case .contacts:
            return "This app needs contacts access for features you requested."
        case .calendar:
            return "This app needs calendar access for features you requested."
        case .photoLibrary:
            return "This app needs photo library access for features you requested."
        case .appleEvents:
            return "This app needs Apple Events access for features you requested."
        }
    }

    var sandboxEntitlementKeys: [String] {
        switch self {
        case .microphone:
            return ["com.apple.security.device.audio-input"]
        case .camera:
            return ["com.apple.security.device.camera"]
        case .location:
            return ["com.apple.security.personal-information.location"]
        case .contacts:
            return ["com.apple.security.personal-information.addressbook"]
        case .calendar:
            return ["com.apple.security.personal-information.calendars"]
        case .photoLibrary:
            return ["com.apple.security.personal-information.photos-library"]
        case .appleEvents:
            return ["com.apple.security.automation.apple-events"]
        }
    }

    var enablementWarningTitle: String? {
        switch self {
        case .contacts, .calendar, .photoLibrary, .appleEvents:
            return "Allow \(displayName) access?"
        case .microphone, .camera, .location:
            return nil
        }
    }

    var enablementWarningMessage: String? {
        switch self {
        case .contacts:
            return "Generated apps will be able to read, create, edit and delete contact cards."
        case .calendar:
            return "Generated apps will be able to read, create, edit and delete calendar events."
        case .photoLibrary:
            return "Generated apps will be able to read, create, edit and delete photos, videos and photo metadata."
        case .appleEvents:
            return "Generated apps may control approved apps and read, change, or delete data those apps expose to automation."
        case .microphone, .camera, .location:
            return nil
        }
    }
}

nonisolated struct GeneratedAppResourcePermissions: Equatable, Sendable {
    var enabled: Set<GeneratedAppResourcePermission>

    init(_ enabled: some Sequence<GeneratedAppResourcePermission> = []) {
        self.enabled = Set(enabled)
    }

    nonisolated static var none: GeneratedAppResourcePermissions {
        GeneratedAppResourcePermissions()
    }

    var enabledPermissions: [GeneratedAppResourcePermission] {
        GeneratedAppResourcePermission.allCases.filter { enabled.contains($0) }
    }

    func contains(_ permission: GeneratedAppResourcePermission) -> Bool {
        enabled.contains(permission)
    }

    static func inferred(fromAppBundleAt appBundleURL: URL) -> GeneratedAppResourcePermissions {
        let plistURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else {
            return .none
        }

        return GeneratedAppResourcePermissions(
            GeneratedAppResourcePermission.allCases.filter { permission in
                permission.usageDescriptionKeys.contains { dictionary[$0] != nil }
            }
        )
    }
}

nonisolated enum GeneratedAppSandboxPermission: String, CaseIterable, Identifiable, Sendable {
    case internet
    case userSelectedFiles

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .internet: return "Internet"
        case .userSelectedFiles: return "User-selected files"
        }
    }

    var userDefaultsKey: String {
        "generation.generatedAppSandboxPermissions.v1.\(rawValue)"
    }

    var entitlementKey: String {
        switch self {
        case .internet: return "com.apple.security.network.client"
        case .userSelectedFiles: return "com.apple.security.files.user-selected.read-write"
        }
    }
}

nonisolated struct GeneratedAppSandboxPermissions: Equatable, Sendable {
    var enabled: Set<GeneratedAppSandboxPermission>

    init(_ enabled: some Sequence<GeneratedAppSandboxPermission> = GeneratedAppSandboxPermission.allCases) {
        self.enabled = Set(enabled)
    }

    nonisolated static var `default`: GeneratedAppSandboxPermissions {
        GeneratedAppSandboxPermissions()
    }

    nonisolated static var none: GeneratedAppSandboxPermissions {
        GeneratedAppSandboxPermissions([])
    }

    var enabledPermissions: [GeneratedAppSandboxPermission] {
        GeneratedAppSandboxPermission.allCases.filter { enabled.contains($0) }
    }

    func contains(_ permission: GeneratedAppSandboxPermission) -> Bool {
        enabled.contains(permission)
    }

    static func inferred(
        fromPackageAt packageRootURL: URL,
        sandboxEnabled: Bool
    ) -> GeneratedAppSandboxPermissions {
        guard sandboxEnabled else {
            return .none
        }

        let entitlementsURL = ToolPackageLayout.sandboxEntitlementsURL(for: packageRootURL)
        guard let data = try? Data(contentsOf: entitlementsURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any]
        else {
            return .default
        }

        return GeneratedAppSandboxPermissions(
            GeneratedAppSandboxPermission.allCases.filter { permission in
                dictionary[permission.entitlementKey] as? Bool == true
            }
        )
    }
}
