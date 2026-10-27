import Foundation

enum ModuleID: String, CaseIterable, Identifiable, Codable, Sendable {
    // Tier 1 — MVP
    case zones, windowSwitcher, keys, menuBarManager, clipboard, awake, systemToggles, scrollMouse
    // Tier 2 — power utilities
    case colorPicker, textExtractor, pinCrop, batchRename, fileLocksmith, finderExtras, displaysAudio
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
    case mvp = 1, utilities, pro

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
        .init(id: .zones, name: "Zones",
              summary: "Snap windows into custom layouts per display. Hold ⇧ while dragging, or use shortcuts.",
              symbol: "rectangle.split.3x1", category: .windowsInput, tier: .mvp,
              permissions: [.accessibility], replaces: "Rectangle, Magnet", isImplemented: true),
        .init(id: .windowSwitcher, name: "Window Switcher",
              summary: "⌘⇥ that switches windows rather than apps, with live previews and minimized windows.",
              symbol: "macwindow.on.rectangle", category: .windowsInput, tier: .mvp,
              permissions: [.accessibility, .screenRecording], replaces: "AltTab"),
        .init(id: .keys, name: "Keys",
              summary: "Remap keys and shortcuts globally or per app. Caps Lock → Hyper, Fn-row tweaks, key chords.",
              symbol: "keyboard", category: .windowsInput, tier: .mvp,
              permissions: [.inputMonitoring], replaces: "Karabiner-Elements"),
        .init(id: .menuBarManager, name: "Menu Bar",
              summary: "Hide, reorder and overflow menu bar icons that disappear behind the notch.",
              symbol: "menubar.rectangle", category: .system, tier: .mvp,
              permissions: [.accessibility, .screenRecording], replaces: "Ice, Bartender"),
        .init(id: .clipboard, name: "Clipboard",
              summary: "Searchable history of the text, images and files you copy. Pin and preview items, and paste as plain text, Markdown or JSON.",
              symbol: "doc.on.clipboard", category: .tools, tier: .mvp,
              permissions: [.accessibility], replaces: "Maccy, Paste", isImplemented: true),
        .init(id: .awake, name: "Awake",
              summary: "Keep the Mac awake indefinitely, for a set time or until a time of day. Right-click the menu bar tile for durations.",
              symbol: "cup.and.saucer", category: .system, tier: .mvp,
              permissions: [], replaces: "Amphetamine, caffeinate", isImplemented: true),
        .init(id: .systemToggles, name: "System Toggles",
              summary: "Dark mode, hiding the Dock or desktop icons, hidden files, Wi‑Fi and quick actions, from a shortcut or the menu bar.",
              symbol: "switch.2", category: .system, tier: .mvp,
              permissions: [.automation], replaces: "One Switch, Shortcuts", isImplemented: true),
        .init(id: .scrollMouse, name: "Scroll & Mouse",
              summary: "Separate scroll direction for mouse and trackpad, smooth wheel scrolling, button mapping.",
              symbol: "computermouse", category: .windowsInput, tier: .mvp,
              permissions: [.accessibility], replaces: "Mos, LinearMouse"),

        // MARK: Tier 2 — power utilities
        .init(id: .colorPicker, name: "Color Picker",
              summary: "Global hotkey and magnifier. Copy as HEX, RGB, HSL or SwiftUI/NSColor, with history.",
              symbol: "eyedropper", category: .tools, tier: .utilities,
              permissions: [.screenRecording], replaces: "Digital Color Meter"),
        .init(id: .textExtractor, name: "Text Extractor",
              summary: "OCR any screen region straight to the clipboard.",
              symbol: "text.viewfinder", category: .tools, tier: .utilities,
              permissions: [.screenRecording], replaces: "TextSniper"),
        .init(id: .pinCrop, name: "Pin & Crop",
              summary: "Keep any window on top, or crop part of a window into a floating live thumbnail.",
              symbol: "pin", category: .windowsInput, tier: .utilities,
              permissions: [.accessibility, .screenRecording], replaces: "No native option"),
        .init(id: .batchRename, name: "Batch Rename",
              summary: "Regex find and replace, case changes, numbering and EXIF dates, with preview and undo.",
              symbol: "character.cursor.ibeam", category: .tools, tier: .utilities,
              permissions: [], replaces: "Finder Rename (literal only)"),
        .init(id: .fileLocksmith, name: "File Locksmith",
              summary: "Shows which process holds a file or blocks a disk eject, and lets you quit it.",
              symbol: "lock.doc", category: .tools, tier: .utilities,
              permissions: [.fullDiskAccess], replaces: "lsof in Terminal"),
        .init(id: .finderExtras, name: "Finder Extras",
              summary: "New File here, Copy Path, Open in Terminal, toggle hidden files, image resize.",
              symbol: "folder.badge.gearshape", category: .tools, tier: .utilities,
              permissions: [], replaces: "OpenInTerminal"),
        .init(id: .displaysAudio, name: "Displays & Audio",
              summary: "External monitor brightness via DDC, per-app volume, output switching, global mic mute.",
              symbol: "speaker.wave.2", category: .system, tier: .utilities,
              permissions: [.microphone], replaces: "MonitorControl, SoundSource"),

        // MARK: Tier 3 — dev & presenter
        .init(id: .workspaces, name: "Workspaces",
              summary: "Launch a saved set of apps, URLs and terminals into a Zones layout in one action.",
              symbol: "square.grid.2x2", category: .developer, tier: .pro,
              permissions: [.accessibility], replaces: "Moom"),
        .init(id: .portsProcesses, name: "Ports & Processes",
              summary: "See what is listening on :3000 and kill it from the menu bar.",
              symbol: "network", category: .developer, tier: .pro,
              permissions: [], replaces: "lsof -i, Activity Monitor"),
        .init(id: .hostsEnv, name: "Hosts & Env",
              summary: "Hosts file editor with profiles, plus a PATH and environment view across shells.",
              symbol: "server.rack", category: .developer, tier: .pro,
              permissions: [.admin], replaces: "Text editor + sudo"),
        .init(id: .launchAgents, name: "Launch Agents",
              summary: "List, toggle and inspect launchd agents, daemons and login items.",
              symbol: "gearshape.2", category: .developer, tier: .pro,
              permissions: [.admin], replaces: "Lingon, launchctl"),
        .init(id: .defaultsBrowser, name: "Defaults Browser",
              summary: "Browse and edit app preference plists and hidden defaults.",
              symbol: "list.bullet.rectangle", category: .developer, tier: .pro,
              permissions: [], replaces: "defaults CLI"),
        .init(id: .presenterKit, name: "Presenter Kit",
              summary: "Zoom, draw on screen, keystroke overlay, click rings and cursor spotlight.",
              symbol: "rectangle.inset.filled.and.person.filled", category: .developer, tier: .pro,
              permissions: [.accessibility, .screenRecording], replaces: "Presentify, KeyCastr"),
        .init(id: .screenRuler, name: "Screen Ruler",
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
