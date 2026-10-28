
/// A setting you can flip, or a one-off action, from a shortcut or the menu bar.
enum SystemToggle: String, CaseIterable, Identifiable {
    // Toggles
    case darkMode, hideDock, hideMenuBar
    case hideDesktopIcons, showHiddenFiles, showFileExtensions
    case wifi
    // Actions
    case sleepDisplay, startScreenSaver, ejectDisks, emptyTrash

    enum Group: CaseIterable, Identifiable {
        case appearance, finder, network, actions

        var id: Self { self }

        var title: String {
            switch self {
            case .appearance: "Appearance"
            case .finder: "Finder & desktop"
            case .network: "Network"
            case .actions: "Actions"
            }
        }

        var toggles: [SystemToggle] {
            SystemToggle.allCases.filter { $0.group == self }
        }
    }

    var id: Self { self }

    var group: Group {
        switch self {
        case .darkMode, .hideDock, .hideMenuBar: .appearance
        case .hideDesktopIcons, .showHiddenFiles, .showFileExtensions: .finder
        case .wifi: .network
        case .sleepDisplay, .startScreenSaver, .ejectDisks, .emptyTrash: .actions
        }
    }

    /// Actions run once; everything else has an on and off state.
    var isAction: Bool { group == .actions }

    var title: String {
        switch self {
        case .darkMode: "Dark mode"
        case .hideDock: "Hide the Dock"
        case .hideMenuBar: "Hide the menu bar"
        case .hideDesktopIcons: "Hide desktop icons"
        case .showHiddenFiles: "Show hidden files"
        case .showFileExtensions: "Show file extensions"
        case .wifi: "Wi‑Fi"
        case .sleepDisplay: "Sleep display"
        case .startScreenSaver: "Start screen saver"
        case .ejectDisks: "Eject disks"
        case .emptyTrash: "Empty Trash"
        }
    }

    /// The short label on a menu bar tile.
    var shortTitle: String {
        switch self {
        case .hideDock: "Dock"
        case .hideMenuBar: "Menu bar"
        case .hideDesktopIcons: "Desktop"
        case .showHiddenFiles: "Hidden files"
        case .showFileExtensions: "Extensions"
        case .sleepDisplay: "Sleep display"
        case .startScreenSaver: "Screen saver"
        default: title
        }
    }

    var hint: String {
        switch self {
        case .darkMode: "Switches the whole system between light and dark."
        case .hideDock: "The Dock slides in when you move to the screen edge."
        case .hideMenuBar: "The menu bar shows when you move to the top of the screen."
        case .hideDesktopIcons: "A clean desktop for screen sharing and recordings. Finder restarts to apply it."
        case .showHiddenFiles: "Shows dotfiles and other hidden items in Finder. Finder restarts to apply it."
        case .showFileExtensions: "Shows extensions such as .pdf on every file name. Finder restarts to apply it."
        case .wifi: "Turns Wi‑Fi on or off."
        case .sleepDisplay: "Turns the displays off. Locks too if your Mac asks for the password right away."
        case .startScreenSaver: "Starts the screen saver now."
        case .ejectDisks: "Safely ejects every external drive and disk image."
        case .emptyTrash: "Deletes everything in the Trash for good, after asking."
        }
    }

    var symbol: String {
        switch self {
        case .darkMode: "moon"
        case .hideDock: "dock.rectangle"
        case .hideMenuBar: "menubar.rectangle"
        case .hideDesktopIcons: "menubar.dock.rectangle"
        case .showHiddenFiles: "eye"
        case .showFileExtensions: "doc.text"
        case .wifi: "wifi"
        case .sleepDisplay: "display"
        case .startScreenSaver: "sparkles.tv"
        case .ejectDisks: "eject"
        case .emptyTrash: "trash"
        }
    }

    /// Goes through System Events or Finder, which asks for Automation the first time.
    var usesAutomation: Bool {
        switch self {
        case .darkMode, .hideDock, .hideMenuBar, .emptyTrash: true
        default: false
        }
    }

    /// Asks before running, because it can't be undone.
    var needsConfirmation: Bool { self == .emptyTrash }

    var shortcut: ShortcutDefinition {
        ShortcutDefinition(
            id: "systemToggles.\(rawValue)", module: .systemToggles,
            title: isAction ? title : "Toggle \(title.lowercasedFirst)",
            defaultHotKey: nil
        )
    }

    /// Tiles shown in the menu bar until the user picks their own.
    static let defaultMenuBarItems: [SystemToggle] = [.darkMode, .hideDesktopIcons]
}

private extension String {
    /// "Dark mode" → "dark mode", but "Wi‑Fi" stays as it is.
    var lowercasedFirst: String {
        guard let first, first.isUppercase, dropFirst().first?.isLowercase == true, !contains("‑") else { return self }
        return first.lowercased() + dropFirst()
    }
}
