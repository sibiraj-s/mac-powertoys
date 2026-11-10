import Foundation

extension URL {
    /// Where modules keep their files, in Application Support. Named after the app, so Debug
    /// builds ("PowerToys Dev") keep their files apart from the installed app's.
    nonisolated static var powerToysSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String)
    }

    /// The installed app's folder, used by every build for backups of things the whole system
    /// shares, such as /etc/hosts and the Dock's settings: there's one original of each, and a
    /// Debug build mustn't save the installed app's edits as its own original.
    nonisolated static var sharedSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "PowerToys")
    }
}
