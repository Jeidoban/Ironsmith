import Darwin
import Foundation

enum IronsmithRuntimeEnvironment {
    nonisolated static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["IRONSMITH_RUNNING_TESTS"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }

    nonisolated static var isAppleSiliconMac: Bool {
        #if arch(arm64)
        true
        #else
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
        #endif
    }
}
