import Foundation

extension URL {
    /// Where modules keep their files, in Application Support.
    nonisolated static var powerToysSupportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "PowerToys")
    }
}
