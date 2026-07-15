import Foundation
import Observation

@MainActor
@Observable
final class GenerationPreferencesStore {
    private enum Key {
        static let generatedPromptRefinementEnabled = "generation.generatedPromptRefinementEnabled"
        static let codingAgentPreference = "generation.agentPipelineProfile"
        static let reasoningEffort = "generation.reasoningEffort"
        static let imageGenerationProvider = "generation.imageGenerationProvider"
    }

    var generatedPromptRefinementEnabled: Bool {
        didSet {
            userDefaults.set(generatedPromptRefinementEnabled, forKey: Key.generatedPromptRefinementEnabled)
        }
    }
    var codingAgentPreference: ToolCodingAgentPreference {
        didSet {
            userDefaults.set(codingAgentPreference.rawValue, forKey: Key.codingAgentPreference)
        }
    }
    var reasoningEffort: ToolReasoningEffort {
        didSet {
            userDefaults.set(reasoningEffort.rawValue, forKey: Key.reasoningEffort)
        }
    }
    var imageGenerationProvider: ToolImageGenerationProvider {
        didSet {
            userDefaults.set(imageGenerationProvider.rawValue, forKey: Key.imageGenerationProvider)
        }
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
        self.generatedPromptRefinementEnabled = userDefaults.object(
            forKey: Key.generatedPromptRefinementEnabled
        ) == nil
            ? true
            : userDefaults.bool(forKey: Key.generatedPromptRefinementEnabled)
        self.codingAgentPreference = userDefaults
            .string(forKey: Key.codingAgentPreference)
            .flatMap(ToolCodingAgentPreference.init(rawValue:)) ?? .automatic
        self.reasoningEffort = userDefaults
            .string(forKey: Key.reasoningEffort)
            .flatMap(ToolReasoningEffort.init(rawValue:)) ?? .default
        self.imageGenerationProvider = userDefaults
            .string(forKey: Key.imageGenerationProvider)
            .flatMap(ToolImageGenerationProvider.init(rawValue:)) ?? .automatic
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
