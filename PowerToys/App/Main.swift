import AppKit

@main
enum Main {
    static func main() {
        if TestHost.isActive {
            // The tests run inside the app, so it's launched for them: it only has to be there to
            // load them into. Nothing starts, and it never shows in the Dock or the menu bar.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            app.run()
        } else {
            PowerToysApp.main()
        }
    }
}

/// Whether this process was launched by Xcode to run the unit tests in. It shares its bundle
/// identifier, and so its settings, with the development build, whose modules it would otherwise
/// start a second copy of.
enum TestHost {
    nonisolated static var isActive: Bool {
        let environment = ProcessInfo.processInfo.environment
        return ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains {
            environment[$0] != nil
        }
    }
}
