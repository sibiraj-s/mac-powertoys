import Foundation

enum ModuleID: String, CaseIterable, Identifiable, Codable, Sendable {
    // Tier 1 — MVP
    case zones, windowSwitcher, keys, clipboard, awake, systemToggles, scrollMouse
    // Tier 2 — power utilities
    case colorPicker, textExtractor, pinCrop, batchRename, fileLocksmith, finderExtras, displaysAudio, cleaner
    // Tier 3 — dev & presenter
    case workspaces, portsProcesses, hostsEnv, launchAgents, defaultsBrowser, presenterKit, screenRuler

    var id: Self { self }
}

enum ModuleCategory: String, CaseIterable, Identifiable {
    case windowsInput = "Windows & input"
    case system = "System"
    case tools = "Tools"
    case developer = "Dev & presenter"

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
}

enum ModuleCatalog {
    static let all: [ModuleDescriptor] = [
        // MARK: Tier 1 — MVP
        .init(
            id: .zones, name: "Zones",
            summary: "Snap windows into custom layouts per display. Hold ⇧ while dragging, or use shortcuts.",
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
            summary: "Remap keys and shortcuts everywhere or in one app, and turn Caps Lock into Hyper, Escape or Control.",
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
            summary: "Keep the Mac awake indefinitely, for a set time or until a time of day. Right-click the menu bar tile for durations.",
            symbol: "cup.and.saucer", category: .system, tier: .mvp,
            permissions: [], replaces: "Amphetamine, caffeinate", isImplemented: true),
        .init(
            id: .systemToggles, name: "System Toggles",
            summary: "Dark mode, hiding the Dock or desktop icons, hidden files, Wi‑Fi and quick actions, from a shortcut or the menu bar.",
            symbol: "switch.2", category: .system, tier: .mvp,
            permissions: [.automation], replaces: "One Switch, Shortcuts", isImplemented: true),
        .init(
            id: .scrollMouse, name: "Scroll & Mouse",
            summary: "Separate scroll direction for mouse and trackpad, smooth wheel scrolling, and other jobs for extra mouse buttons.",
            symbol: "computermouse", category: .windowsInput, tier: .mvp,
            permissions: [.accessibility], replaces: "Mos, LinearMouse", isImplemented: true),

        // MARK: Tier 2 — power utilities
        .init(
            id: .colorPicker, name: "Color Picker",
            summary:
                "Pick any color on screen with a magnifier, from a shortcut or the menu bar. Copy it as HEX, RGB, HSL or SwiftUI and AppKit code.",
            symbol: "eyedropper", category: .tools, tier: .utilities,
            permissions: [], replaces: "Digital Color Meter", isImplemented: true),
        .init(
            id: .textExtractor, name: "Text Extractor",
            summary:
                "Select any part of the screen and copy the text in it, from a shortcut or the menu bar. Reads QR codes and barcodes too.",
            symbol: "text.viewfinder", category: .tools, tier: .utilities,
            permissions: [.screenRecording], replaces: "TextSniper", isImplemented: true),
        .init(
            id: .pinCrop, name: "Pin & Crop",
            summary: "Keep a live copy of any window on top of the others, or crop part of one into a floating thumbnail.",
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
                "Make a new file in the folder Finder is showing, copy paths, open folders in a terminal and resize images, from shortcuts.",
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
            summary: "See CPU, memory and disk use, quit the busiest processes, and delete caches, logs and build data to free space.",
            symbol: "gauge.with.dots.needle.50percent", category: .system, tier: .utilities,
            permissions: [.admin], replaces: "Mole, CleanMyMac, iStat Menus", isImplemented: true),

        // MARK: Tier 3 — dev & presenter
        .init(
            id: .workspaces, name: "Workspaces",
            summary: "Launch a saved set of apps, URLs and terminals into a Zones layout in one action.",
            symbol: "square.grid.2x2", category: .developer, tier: .pro,
            permissions: [.accessibility], replaces: "Moom"),
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
            permissions: [], replaces: "defaults CLI", isImplemented: true),
        .init(
            id: .presenterKit, name: "Presenter Kit",
            summary: "Zoom, draw on screen, keystroke overlay, click rings and cursor spotlight.",
            symbol: "rectangle.inset.filled.and.person.filled", category: .developer, tier: .pro,
            permissions: [.accessibility, .screenRecording], replaces: "Presentify, KeyCastr"),
        .init(
            id: .screenRuler, name: "Screen Ruler",
            summary: "Measure pixels between edges. Hold ⌘ for the frontmost app's shortcut cheat sheet.",
            symbol: "ruler", category: .developer, tier: .pro,
            permissions: [.accessibility, .screenRecording], replaces: "xScope, KeyClu"),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func descriptor(_ id: ModuleID) -> ModuleDescriptor { byID[id]! }

    static func modules(in category: ModuleCategory) -> [ModuleDescriptor] {
        all.filter { $0.category == category }
    }
}
