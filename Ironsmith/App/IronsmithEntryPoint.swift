import AppKit

@main
@MainActor
enum IronsmithEntryPoint {
    // NSApplication holds its delegate weakly, so retain it for the app's lifetime.
    private static var applicationDelegate: IronsmithAppDelegate?

    static func main() {
        let application = NSApplication.shared
        let delegate = IronsmithAppDelegate()
        applicationDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}
