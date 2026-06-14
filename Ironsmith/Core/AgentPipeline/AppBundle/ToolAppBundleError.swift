import Foundation

enum ToolAppBundleError: LocalizedError, Equatable {
    case releaseBuildFailed(String)
    case missingExecutable(String)
    case signingFailed(String)
    case signatureVerificationFailed(String)
    case iconGenerationProducedNoImage
    case iconEncodingFailed

    var errorDescription: String? {
        switch self {
        case .releaseBuildFailed(let output):
            return output.isEmpty ? "The generated app failed to build in release mode." : output
        case .missingExecutable(let path):
            return "The release build did not produce the expected executable at \(path)."
        case .signingFailed(let output):
            return output.isEmpty ? "Ironsmith could not sign the generated app bundle." : output
        case .signatureVerificationFailed(let output):
            return output.isEmpty ? "The generated app bundle did not pass code signature verification." : output
        case .iconGenerationProducedNoImage:
            return "Image Playground did not return an icon image."
        case .iconEncodingFailed:
            return "Ironsmith could not encode the generated app icon."
        }
    }
}
