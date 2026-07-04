import Foundation
import Observation

@MainActor
@Observable
final class GenerationPreferencesStore {
    static let availableKVCacheBits = [2, 3, 4, 6, 8]

    private enum Key {
        static let customOptionsEnabled = "generation.customOptionsEnabled"
        static let temperature = "generation.temperature"
        static let maximumResponseTokens = "generation.maximumResponseTokens"
        static let mlxKVCacheMaxSize = "generation.mlxKVCacheMaxSize"
        static let mlxKVCacheBitsEnabled = "generation.mlxKVCacheBitsEnabled"
        static let mlxKVCacheBits = "generation.mlxKVCacheBits"
        static let generatedPromptRefinementEnabled = "generation.generatedPromptRefinementEnabled"
        static let agentPipelineProfile = "generation.agentPipelineProfile"
    }

    var customOptionsEnabled: Bool {
        didSet { userDefaults.set(customOptionsEnabled, forKey: Key.customOptionsEnabled) }
    }
    var generatedPromptRefinementEnabled: Bool {
        didSet {
            userDefaults.set(generatedPromptRefinementEnabled, forKey: Key.generatedPromptRefinementEnabled)
        }
    }
    var agentPipelineProfile: AgentPipelineProfilePreference {
        didSet {
            userDefaults.set(agentPipelineProfile.rawValue, forKey: Key.agentPipelineProfile)
        }
    }
    var temperature: Double {
        didSet { userDefaults.set(temperature, forKey: Key.temperature) }
    }
    var maximumResponseTokens: Int {
        didSet { userDefaults.set(maximumResponseTokens, forKey: Key.maximumResponseTokens) }
    }
    var mlxKVCacheMaxSize: Int {
        didSet { userDefaults.set(mlxKVCacheMaxSize, forKey: Key.mlxKVCacheMaxSize) }
    }
    var mlxKVCacheBitsEnabled: Bool {
        didSet { userDefaults.set(mlxKVCacheBitsEnabled, forKey: Key.mlxKVCacheBitsEnabled) }
    }
    var mlxKVCacheBits: Int {
        didSet { userDefaults.set(mlxKVCacheBits, forKey: Key.mlxKVCacheBits) }
    }
    var generatedAppMicrophoneAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                generatedAppMicrophoneAccessEnabled,
                forKey: GeneratedAppResourcePermission.microphone.userDefaultsKey
            )
        }
    }
    var generatedAppCameraAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                generatedAppCameraAccessEnabled,
                forKey: GeneratedAppResourcePermission.camera.userDefaultsKey
            )
        }
    }
    var generatedAppLocationAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                generatedAppLocationAccessEnabled,
                forKey: GeneratedAppResourcePermission.location.userDefaultsKey
            )
        }
    }
    var generatedAppContactsAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                generatedAppContactsAccessEnabled,
                forKey: GeneratedAppResourcePermission.contacts.userDefaultsKey
            )
        }
    }
    var generatedAppCalendarAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                generatedAppCalendarAccessEnabled,
                forKey: GeneratedAppResourcePermission.calendar.userDefaultsKey
            )
        }
    }
    var generatedAppPhotoLibraryAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                generatedAppPhotoLibraryAccessEnabled,
                forKey: GeneratedAppResourcePermission.photoLibrary.userDefaultsKey
            )
        }
    }
    var generatedAppAppleEventsAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                generatedAppAppleEventsAccessEnabled,
                forKey: GeneratedAppResourcePermission.appleEvents.userDefaultsKey
            )
        }
    }
    var generatedAppInternetAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                generatedAppInternetAccessEnabled,
                forKey: GeneratedAppSandboxPermission.internet.userDefaultsKey
            )
        }
    }
    var generatedAppUserSelectedFileAccessEnabled: Bool {
        didSet {
            userDefaults.set(
                generatedAppUserSelectedFileAccessEnabled,
                forKey: GeneratedAppSandboxPermission.userSelectedFiles.userDefaultsKey
            )
        }
    }

    var generatedAppResourcePermissions: GeneratedAppResourcePermissions {
        GeneratedAppResourcePermissions(
            GeneratedAppResourcePermission.allCases.filter { isGeneratedAppResourcePermissionEnabled($0) }
        )
    }

    var generatedAppSandboxPermissions: GeneratedAppSandboxPermissions {
        GeneratedAppSandboxPermissions(
            GeneratedAppSandboxPermission.allCases.filter { isGeneratedAppSandboxPermissionEnabled($0) }
        )
    }

    @ObservationIgnored private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.customOptionsEnabled = userDefaults.bool(forKey: Key.customOptionsEnabled)
        self.generatedPromptRefinementEnabled = userDefaults.object(
            forKey: Key.generatedPromptRefinementEnabled
        ) == nil
            ? true
            : userDefaults.bool(forKey: Key.generatedPromptRefinementEnabled)
        self.agentPipelineProfile = userDefaults
            .string(forKey: Key.agentPipelineProfile)
            .flatMap(AgentPipelineProfilePreference.init(rawValue:)) ?? .automatic
        self.temperature = userDefaults.object(forKey: Key.temperature) == nil
            ? ModelGenerationDefaults.foundation.temperature ?? 0.7
            : userDefaults.double(forKey: Key.temperature)
        self.maximumResponseTokens = userDefaults.object(forKey: Key.maximumResponseTokens) == nil
            ? ModelGenerationDefaults.remoteMaximumResponseTokens
            : userDefaults.integer(forKey: Key.maximumResponseTokens)
        self.mlxKVCacheMaxSize = userDefaults.object(forKey: Key.mlxKVCacheMaxSize) == nil
            ? ModelGenerationDefaults.qwenDefaults.mlxKVCacheMaxSize ?? 4096
            : userDefaults.integer(forKey: Key.mlxKVCacheMaxSize)
        self.mlxKVCacheBitsEnabled = userDefaults.bool(forKey: Key.mlxKVCacheBitsEnabled)
        self.mlxKVCacheBits = userDefaults.object(forKey: Key.mlxKVCacheBits) == nil
            ? ModelGenerationDefaults.qwenDefaults.mlxKVCacheBits ?? 4
            : userDefaults.integer(forKey: Key.mlxKVCacheBits)
        self.generatedAppMicrophoneAccessEnabled = userDefaults.bool(
            forKey: GeneratedAppResourcePermission.microphone.userDefaultsKey
        )
        self.generatedAppCameraAccessEnabled = userDefaults.bool(
            forKey: GeneratedAppResourcePermission.camera.userDefaultsKey
        )
        self.generatedAppLocationAccessEnabled = userDefaults.bool(
            forKey: GeneratedAppResourcePermission.location.userDefaultsKey
        )
        self.generatedAppContactsAccessEnabled = userDefaults.bool(
            forKey: GeneratedAppResourcePermission.contacts.userDefaultsKey
        )
        self.generatedAppCalendarAccessEnabled = userDefaults.bool(
            forKey: GeneratedAppResourcePermission.calendar.userDefaultsKey
        )
        self.generatedAppPhotoLibraryAccessEnabled = userDefaults.bool(
            forKey: GeneratedAppResourcePermission.photoLibrary.userDefaultsKey
        )
        self.generatedAppAppleEventsAccessEnabled = userDefaults.bool(
            forKey: GeneratedAppResourcePermission.appleEvents.userDefaultsKey
        )
        self.generatedAppInternetAccessEnabled = userDefaults.object(
            forKey: GeneratedAppSandboxPermission.internet.userDefaultsKey
        ) == nil
            ? true
            : userDefaults.bool(forKey: GeneratedAppSandboxPermission.internet.userDefaultsKey)
        self.generatedAppUserSelectedFileAccessEnabled = userDefaults.object(
            forKey: GeneratedAppSandboxPermission.userSelectedFiles.userDefaultsKey
        ) == nil
            ? true
            : userDefaults.bool(forKey: GeneratedAppSandboxPermission.userSelectedFiles.userDefaultsKey)
    }

    func isGeneratedAppResourcePermissionEnabled(_ permission: GeneratedAppResourcePermission) -> Bool {
        switch permission {
        case .microphone:
            return generatedAppMicrophoneAccessEnabled
        case .camera:
            return generatedAppCameraAccessEnabled
        case .location:
            return generatedAppLocationAccessEnabled
        case .contacts:
            return generatedAppContactsAccessEnabled
        case .calendar:
            return generatedAppCalendarAccessEnabled
        case .photoLibrary:
            return generatedAppPhotoLibraryAccessEnabled
        case .appleEvents:
            return generatedAppAppleEventsAccessEnabled
        }
    }

    func setGeneratedAppResourcePermission(_ permission: GeneratedAppResourcePermission, enabled: Bool) {
        switch permission {
        case .microphone:
            generatedAppMicrophoneAccessEnabled = enabled
        case .camera:
            generatedAppCameraAccessEnabled = enabled
        case .location:
            generatedAppLocationAccessEnabled = enabled
        case .contacts:
            generatedAppContactsAccessEnabled = enabled
        case .calendar:
            generatedAppCalendarAccessEnabled = enabled
        case .photoLibrary:
            generatedAppPhotoLibraryAccessEnabled = enabled
        case .appleEvents:
            generatedAppAppleEventsAccessEnabled = enabled
        }
    }

    func isGeneratedAppSandboxPermissionEnabled(_ permission: GeneratedAppSandboxPermission) -> Bool {
        switch permission {
        case .internet:
            return generatedAppInternetAccessEnabled
        case .userSelectedFiles:
            return generatedAppUserSelectedFileAccessEnabled
        }
    }

    func setGeneratedAppSandboxPermission(_ permission: GeneratedAppSandboxPermission, enabled: Bool) {
        switch permission {
        case .internet:
            generatedAppInternetAccessEnabled = enabled
        case .userSelectedFiles:
            generatedAppUserSelectedFileAccessEnabled = enabled
        }
    }
}
