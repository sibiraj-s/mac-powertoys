import Foundation

/// A well-known hidden setting, one switch or menu instead of a key to look up.
nonisolated struct DefaultsTweak: Identifiable, Hashable, Sendable {
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case dock = "Dock"
        case finder = "Finder"
        case screenshots = "Screenshots"
        case typingWindows = "Typing & windows"
        case filesDisks = "Files & disks"

        var id: Self { self }
    }

    /// What has to happen before a change shows.
    enum Restart: String, Hashable, Sendable {
        /// The process is restarted by quitting it, as `killall` does; launchd opens it again.
        case dock = "com.apple.dock"
        case finder = "com.apple.finder"
        /// Apps read it when they open.
        case apps
        case logOut
        case none

        var processName: String? {
            switch self {
            case .dock: "Dock"
            case .finder: "Finder"
            default: nil
            }
        }
    }

    enum Control: Hashable, Sendable {
        /// On writes `value`; off deletes the key, so the default comes back.
        case toggle(DefaultsValue)
        /// Choices with their values; the one with nil is the default, chosen by deleting the key.
        case choice([Choice])
    }

    struct Choice: Hashable, Sendable {
        let title: String
        let value: DefaultsValue?
    }

    let group: Group
    let title: String
    let hint: String
    let domain: String
    let key: String
    let control: Control
    let restart: Restart

    var id: String { "\(domain) \(key)" }

    /// The choice or switch position `stored` stands for. A value the list doesn't know, set
    /// some other way, is nil.
    func choice(for stored: DefaultsValue?) -> Choice? {
        guard case .choice(let choices) = control else { return nil }
        return choices.first { $0.value == stored }
    }

    func isOn(_ stored: DefaultsValue?) -> Bool {
        guard case .toggle(let value) = control else { return false }
        return stored == value
    }
}

extension DefaultsTweak {
    nonisolated static let all: [DefaultsTweak] = [
        // MARK: Dock
        .init(group: .dock, title: "Show the hidden Dock without a delay",
              hint: "When the Dock hides itself, it comes up as soon as the pointer reaches the edge.",
              domain: "com.apple.dock", key: "autohide-delay", control: .toggle(.real(0)), restart: .dock),
        .init(group: .dock, title: "Hide and show the Dock without animation",
              hint: "The Dock appears at once instead of sliding in.",
              domain: "com.apple.dock", key: "autohide-time-modifier", control: .toggle(.real(0)), restart: .dock),
        .init(group: .dock, title: "Dim the icons of hidden apps",
              hint: "Apps hidden with ⌘H show see-through in the Dock.",
              domain: "com.apple.dock", key: "showhidden", control: .toggle(.bool(true)), restart: .dock),
        .init(group: .dock, title: "Show only open apps",
              hint: "Leaves out apps kept in the Dock that aren't running.",
              domain: "com.apple.dock", key: "static-only", control: .toggle(.bool(true)), restart: .dock),
        .init(group: .dock, title: "Scroll up on an icon to show its windows",
              hint: "Scrolling up over an app in the Dock shows all its windows.",
              domain: "com.apple.dock", key: "scroll-to-open", control: .toggle(.bool(true)), restart: .dock),
        .init(group: .dock, title: "Hide other apps when switching from the Dock",
              hint: "Clicking an app in the Dock hides every other app's windows.",
              domain: "com.apple.dock", key: "single-app", control: .toggle(.bool(true)), restart: .dock),
        .init(group: .dock, title: "Don't bounce icons of opening apps",
              hint: "Apps open without their Dock icon bouncing.",
              domain: "com.apple.dock", key: "launchanim", control: .toggle(.bool(false)), restart: .dock),
        .init(group: .dock, title: "Minimize effect",
              hint: "Suck is an effect System Settings doesn't list.",
              domain: "com.apple.dock", key: "mineffect",
              control: .choice([
                  Choice(title: "Genie", value: nil),
                  Choice(title: "Scale", value: .string("scale")),
                  Choice(title: "Suck", value: .string("suck")),
              ]),
              restart: .dock),

        // MARK: Finder
        .init(group: .finder, title: "Show the full path in window titles",
              hint: "Finder windows are titled with the folder's whole path, like /Users/you/Projects.",
              domain: "com.apple.finder", key: "_FXShowPosixPathInTitle", control: .toggle(.bool(true)), restart: .finder),
        .init(group: .finder, title: "Add Quit Finder to the Finder menu",
              hint: "Lets you quit Finder with ⌘Q, which also hides the desktop icons until it's opened again.",
              domain: "com.apple.finder", key: "QuitMenuItem", control: .toggle(.bool(true)), restart: .finder),
        .init(group: .finder, title: "Turn off Finder animations",
              hint: "Windows and Get Info panels open without animating.",
              domain: "com.apple.finder", key: "DisableAllAnimations", control: .toggle(.bool(true)), restart: .finder),

        // MARK: Screenshots
        .init(group: .screenshots, title: "Leave out window shadows",
              hint: "Screenshots of a single window are just the window, without the shadow around it.",
              domain: "com.apple.screencapture", key: "disable-shadow", control: .toggle(.bool(true)), restart: .none),
        .init(group: .screenshots, title: "Leave the date and time out of file names",
              hint: "Files are named “Screenshot”, “Screenshot 1” and so on.",
              domain: "com.apple.screencapture", key: "include-date", control: .toggle(.bool(false)), restart: .none),
        .init(group: .screenshots, title: "File format",
              hint: "What screenshots are saved as.",
              domain: "com.apple.screencapture", key: "type",
              control: .choice([
                  Choice(title: "PNG", value: nil),
                  Choice(title: "JPEG", value: .string("jpg")),
                  Choice(title: "HEIC", value: .string("heic")),
                  Choice(title: "PDF", value: .string("pdf")),
                  Choice(title: "TIFF", value: .string("tiff")),
              ]),
              restart: .none),

        // MARK: Typing & windows
        .init(group: .typingWindows, title: "Hold a key to repeat it",
              hint: "Instead of showing accented letters. Apps pick it up when they open again.",
              domain: DefaultsDomain.global, key: "ApplePressAndHoldEnabled", control: .toggle(.bool(false)), restart: .apps),
        .init(group: .typingWindows, title: "Open windows without animation",
              hint: "New windows appear at once instead of zooming in. Apps pick it up when they open again.",
              domain: DefaultsDomain.global, key: "NSAutomaticWindowAnimationsEnabled", control: .toggle(.bool(false)), restart: .apps),
        .init(group: .typingWindows, title: "Save new documents on this Mac",
              hint: "Save dialogs start in a folder on this Mac instead of iCloud Drive. Apps pick it up when they open again.",
              domain: DefaultsDomain.global, key: "NSDocumentSaveNewDocumentsToCloud", control: .toggle(.bool(false)), restart: .apps),

        // MARK: Files & disks
        .init(group: .filesDisks, title: "Don't leave .DS_Store files on network drives",
              hint: "Finder stops writing its folder settings to shared drives. Takes effect after logging out.",
              domain: "com.apple.desktopservices", key: "DSDontWriteNetworkStores", control: .toggle(.bool(true)), restart: .logOut),
        .init(group: .filesDisks, title: "Don't leave .DS_Store files on USB drives",
              hint: "The same for external drives. Takes effect after logging out.",
              domain: "com.apple.desktopservices", key: "DSDontWriteUSBStores", control: .toggle(.bool(true)), restart: .logOut),
        .init(group: .filesDisks, title: "Don't offer new disks for Time Machine",
              hint: "Plugging in a disk no longer asks whether to back up to it.",
              domain: "com.apple.TimeMachine", key: "DoNotOfferNewDisksForBackup", control: .toggle(.bool(true)), restart: .none),
    ]

    nonisolated static func tweaks(in group: Group) -> [DefaultsTweak] {
        all.filter { $0.group == group }
    }
}
