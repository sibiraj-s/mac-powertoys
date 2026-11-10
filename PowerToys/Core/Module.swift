import Foundation

enum ModuleID: String, CaseIterable, Identifiable, Codable, Sendable {
    // Tier 1 — MVP
    case zones, windowSwitcher, keys, clipboard, awake, systemToggles, scrollMouse
    // Tier 2 — power utilities
    case colorPicker, textExtractor, pinCrop, batchRename, fileLocksmith, finderExtras, displaysAudio, cleaner, apps
    // Tier 3 — developer
    case portsProcesses, hostsEnv, launchAgents, defaultsBrowser, screenRuler

    var id: Self { self }
}

enum ModuleCategory: String, CaseIterable, Identifiable {
    // Declaration order is the sidebar and overview order.
    case system = "System"
    case windowsInput = "Windows & input"
    case tools = "Tools"
    case developer = "Developer"

    var id: Self { self }
}

enum ModuleTier: Int, Comparable {
    case mvp = 1
    case utilities, pro

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ModuleDescriptor: Identifiable {
    let id: ModuleID
    let name: String
    let summary: String
    let symbol: String
    let category: ModuleCategory
    let tier: ModuleTier
    let permissions: [Permission]
    /// What people use for this today; shown on modules that aren't built yet.
    let replaces: String
    var isImplemented = false
    /// Stays off on first launch even though it needs no permission.
    var offByDefault = false
}

enum ModuleCatalog {
    static let all: [ModuleDescriptor] = [
        // MARK: Tier 1 — MVP
        .init(
            id: .zones, name: "Zones",
            summary: "Snap windows into halves, thirds or a grid, with a layout for each display. Hold ⇧ while dragging, or use shortcuts.",
            symbol: "rectangle.split.3x1", category: .windowsInput, tier: .mvp,
            permissions: [.accessibility], replaces: "Rectangle, Magnet", isImplemented: true),
        .init(
            id: .windowSwitcher, name: "Window Switcher",
            summary:
                "Switch between windows rather than apps, with previews, including minimized windows and those of hidden apps.",
            symbol: "macwindow.on.rectangle", category: .windowsInput, tier: .mvp,
            // Screen Recording only adds previews, so turning the module on doesn't ask for it.
            permissions: [.accessibility], replaces: "AltTab", isImplemented: true),
        .init(
            id: .keys, name: "Keys",
            summary:
                "Remap keys and shortcuts or turn them off, everywhere or in one app, and turn Caps Lock into Hyper, Escape or Control.",
            symbol: "keyboard", category: .windowsInput, tier: .mvp,
            permissions: [.accessibility], replaces: "Karabiner-Elements", isImplemented: true),
        .init(
            id: .clipboard, name: "Clipboard",
            summary:
                "Searchable history of the text, images and files you copy. Pin and preview items, and paste as plain text, Markdown or JSON.",
            symbol: "doc.on.clipboard", category: .tools, tier: .mvp,
            permissions: [.accessibility], replaces: "Maccy, Paste", isImplemented: true),
        .init(
            id: .awake, name: "Awake",
            summary: "Keep the Mac awake indefinitely, for a set time or until a time of day, with or without the display on.",
            symbol: "cup.and.saucer", category: .system, tier: .mvp,
            permissions: [], replaces: "Amphetamine, caffeinate", isImplemented: true),
        .init(
            id: .systemToggles, name: "System Toggles",
            summary:
                "Switch dark mode, Dock and menu bar hiding, desktop icons, hidden files and Wi‑Fi, or eject disks and empty the Trash, from a shortcut or the menu bar.",
            symbol: "switch.2", category: .system, tier: .mvp,
            permissions: [.automation], replaces: "One Switch, Shortcuts", isImplemented: true),
        .init(
            id: .scrollMouse, name: "Scroll & Mouse",
            summary:
                "Set the scroll direction separately for the mouse and trackpad, smooth out wheel scrolling, and make extra mouse buttons go Back, Forward or press keys.",
            symbol: "computermouse", category: .windowsInput, tier: .mvp,
            permissions: [.accessibility], replaces: "Mos, LinearMouse", isImplemented: true),

        // MARK: Tier 2 — power utilities
        .init(
            id: .colorPicker, name: "Color Picker",
            summary:
                "Pick any color on screen with a magnifier, from a shortcut or the menu bar. Copy it as HEX, RGB, HSL, HSB, or SwiftUI, AppKit or UIKit code.",
            symbol: "eyedropper", category: .tools, tier: .utilities,
            permissions: [], replaces: "Digital Color Meter", isImplemented: true),
        .init(
            id: .textExtractor, name: "Text Extractor",
            summary:
                "Select part of the screen or a window and copy the text in it, from a shortcut or the menu bar. Reads QR codes and barcodes too.",
            symbol: "text.viewfinder", category: .tools, tier: .utilities,
            permissions: [.screenRecording], replaces: "TextSniper", isImplemented: true),
        .init(
            id: .pinCrop, name: "Pin & Crop",
            summary: "Keep a live copy of a window, or just part of one, floating above the others on every Space.",
            symbol: "pin", category: .windowsInput, tier: .utilities,
            permissions: [.screenRecording], replaces: "No native option", isImplemented: true),
        .init(
            id: .batchRename, name: "Batch Rename",
            summary:
                "Rename many files at once with find and replace or regex, case changes, numbering and photo dates, with a preview and undo.",
            symbol: "character.cursor.ibeam", category: .tools, tier: .utilities,
            permissions: [.automation], replaces: "Finder Rename (literal only)", isImplemented: true),
        .init(
            id: .fileLocksmith, name: "File Locksmith",
            summary: "See which processes are using a file, folder or disk, such as one that won't eject, and quit them.",
            symbol: "lock.doc", category: .tools, tier: .utilities,
            permissions: [.automation], replaces: "lsof in Terminal", isImplemented: true),
        .init(
            id: .finderExtras, name: "Finder Extras",
            summary:
                "Make a new file in the folder Finder is showing, copy paths, open folders in a terminal and resize images, from shortcuts or Finder's right-click menu.",
            symbol: "folder.badge.gearshape", category: .tools, tier: .utilities,
            permissions: [.automation], replaces: "OpenInTerminal", isImplemented: true),
        .init(
            id: .displaysAudio, name: "Displays & Audio",
            summary:
                "Switch speakers and microphones, mute the microphone from a shortcut, set each app's volume, and change external displays' brightness and speaker volume.",
            symbol: "speaker.wave.2", category: .system, tier: .utilities,
            // System Audio Recording is only for per-app volume, and is asked for when an app's volume is first changed.
            permissions: [], replaces: "MonitorControl, SoundSource", isImplemented: true),
        .init(
            id: .cleaner, name: "Cleaner",
            summary:
                "See CPU, memory and disk use, quit the busiest processes, and free space by deleting caches, logs, build data and what uninstalled apps left behind.",
            symbol: "gauge.with.dots.needle.50percent", category: .system, tier: .utilities,
            permissions: [.admin], replaces: "Mole, CleanMyMac, iStat Menus", isImplemented: true),
        .init(
            id: .apps, name: "Apps",
            summary:
                "Uninstall apps with their settings, caches and data, and see which have updates in the App Store, their own update feeds or Homebrew.",
            symbol: "square.grid.2x2", category: .system, tier: .utilities,
            permissions: [], replaces: "AppCleaner, MacUpdater", isImplemented: true),

        // MARK: Tier 3 — developer
        .init(
            id: .portsProcesses, name: "Ports & Processes",
            summary:
                "See what's listening on each port, such as :3000, with its command and folder, and quit it here or from the menu bar.",
            symbol: "network", category: .developer, tier: .pro,
            permissions: [], replaces: "lsof -i, Activity Monitor", isImplemented: true),
        .init(
            id: .hostsEnv, name: "Hosts & Env",
            summary:
                "Edit /etc/hosts with groups you switch on and off together, and see PATH and the environment each shell and apps start with.",
            symbol: "server.rack", category: .developer, tier: .pro,
            permissions: [.admin], replaces: "Text editor + sudo", isImplemented: true),
        .init(
            id: .launchAgents, name: "Launch Agents",
            summary:
                "See the launchd agents and daemons on your Mac: what they run and when, whether they're running, and turn them on or off.",
            symbol: "gearshape.2", category: .developer, tier: .pro,
            permissions: [.admin], replaces: "Lingon, launchctl", isImplemented: true),
        .init(
            id: .defaultsBrowser, name: "Defaults Browser",
            summary:
                "Browse and change the settings apps keep, hidden ones included, with a copy saved before the first change. Copy any key as a defaults command.",
            symbol: "list.bullet.rectangle", category: .developer, tier: .pro,
            permissions: [], replaces: "defaults CLI", isImplemented: true, offByDefault: true),
        .init(
            id: .screenRuler, name: "Screen Ruler",
            summary: "Measure the space between edges on screen, or drag over an area, and copy its size in points or pixels.",
            symbol: "ruler", category: .tools, tier: .pro,
            permissions: [.screenRecording], replaces: "xScope", isImplemented: true),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptor(_ id: ModuleID) -> ModuleDescriptor { byID[id]! }

    static func modules(in category: ModuleCategory) -> [ModuleDescriptor] {
        all.filter { $0.category == category }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
