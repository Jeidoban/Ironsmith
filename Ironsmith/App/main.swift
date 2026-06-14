import AppKit

// Making sure swift doesn't kill the delegate and has a continuious reference.
@MainActor private var applicationDelegate: IronsmithAppDelegate?

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = IronsmithAppDelegate()
    applicationDelegate = delegate
    application.delegate = delegate
    application.run()
}
