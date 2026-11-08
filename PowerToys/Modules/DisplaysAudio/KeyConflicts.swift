import AppKit

/// Display apps that take the brightness or volume keys before this app sees them, when their own
/// key handling is on.
struct KeyConflict: Equatable {
    let bundleID: String
    let name: String
    let takesBrightnessKeys: Bool
    let takesVolumeKeys: Bool

    static let known: [KeyConflict] = [
        // Seen taking the volume keys but leaving brightness alone.
        KeyConflict(bundleID: "Qisda.DDPM", name: "Dell Display and Peripheral Manager", takesBrightnessKeys: false, takesVolumeKeys: true),
        KeyConflict(bundleID: "me.guillaumeb.MonitorControl", name: "MonitorControl", takesBrightnessKeys: true, takesVolumeKeys: true),
        KeyConflict(bundleID: "fyi.lunar.Lunar", name: "Lunar", takesBrightnessKeys: true, takesVolumeKeys: true),
        KeyConflict(bundleID: "pro.betterdisplay.BetterDisplay", name: "BetterDisplay", takesBrightnessKeys: true, takesVolumeKeys: true),
    ]

    /// The known apps among those running.
    static func running(in bundleIDs: Set<String>) -> [KeyConflict] {
        known.filter { bundleIDs.contains($0.bundleID) }
    }

    /// What to say under a keys switch, if any of `conflicts` may take its keys.
    static func warning(_ conflicts: [KeyConflict]) -> String? {
        guard !conflicts.isEmpty else { return nil }
        let names = ListFormatter.localizedString(byJoining: conflicts.map(\.name))
        let (verb, its) = conflicts.count == 1 ? ("is", "its") : ("are", "their")
        return
            "\(names) \(verb) running and may handle these keys first. Turn off \(its) key handling or quit \(conflicts.count == 1 ? "it" : "them")."
    }

    static func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }
}
