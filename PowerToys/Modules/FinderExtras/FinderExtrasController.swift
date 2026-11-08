import AppKit
import Observation

/// Actions on Finder's selection or the folder it's showing, run from shortcuts or the settings.
@Observable
final class FinderExtrasController {
    /// Shared with the Finder menu extension.
    typealias Action = FinderAction

    enum PathStyle: String, CaseIterable, Identifiable {
        case full, home, quoted

        var id: Self { self }

        var title: String {
            switch self {
            case .full: "Full path"
            case .home: "From ~"
            case .quoted: "Quoted for Terminal"
            }
        }

        func format(_ url: URL) -> String {
            var path = url.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            switch self {
            case .full: return path
            case .home: return ProcessDetails.abbreviatingHome(path)
            case .quoted: return Command.shellQuoted(path)
            }
        }
    }

    /// Terminal apps that open a folder handed to them, by bundle ID.
    static let terminals: [(id: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("org.alacritty", "Alacritty"),
        ("com.github.wez.wezterm", "WezTerm"),
    ]

    var newFileName: String {
        didSet { defaults.set(newFileName, forKey: Self.newFileNameKey) }
    }
    var pathStyle: PathStyle {
        didSet { defaults.set(pathStyle.rawValue, forKey: Self.pathStyleKey) }
    }
    var terminalID: String {
        didSet { defaults.set(terminalID, forKey: Self.terminalKey) }
    }
    var imageSize: Int {
        didSet { defaults.set(imageSize, forKey: Self.imageSizeKey) }
    }
    /// What the last action did, or why it couldn't.
    private(set) var message: String?
    private(set) var isError = false

    static let newFileNameKey = "finderExtras.newFileName"
    static let pathStyleKey = "finderExtras.pathStyle"
    static let terminalKey = "finderExtras.terminal"
    static let imageSizeKey = "finderExtras.imageSize"

    private let defaults: UserDefaults
    @ObservationIgnored private let finder: any FinderAccess
    @ObservationIgnored private let pasteboard: NSPasteboard
    @ObservationIgnored private let reveal: ([URL]) -> Void
    @ObservationIgnored private let openFolder: (URL, String) async throws -> Void
    @ObservationIgnored private let fileManager: FileManager

    init(
        defaults: UserDefaults = .standard,
        finder: any FinderAccess = LiveFinder(),
        pasteboard: NSPasteboard = .general,
        reveal: @escaping ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) },
        openFolder: @escaping (URL, String) async throws -> Void = FinderExtrasController.open,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        self.finder = finder
        self.pasteboard = pasteboard
        self.reveal = reveal
        self.openFolder = openFolder
        self.fileManager = fileManager
        newFileName = defaults.string(forKey: Self.newFileNameKey) ?? "untitled.txt"
        pathStyle = defaults.string(forKey: Self.pathStyleKey).flatMap(PathStyle.init(rawValue:)) ?? .full
        terminalID = defaults.string(forKey: Self.terminalKey) ?? "com.apple.Terminal"
        imageSize = defaults.object(forKey: Self.imageSizeKey) as? Int ?? 1600
    }

    /// The terminals installed on this Mac, plus Terminal and the chosen one so the choice shows.
    static func installedTerminals(
        including chosen: String,
        isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    ) -> [(id: String, name: String)] {
        terminals.filter { $0.id == "com.apple.Terminal" || $0.id == chosen || isInstalled($0.id) }
    }

    /// Runs `action` on Finder's selection and folder, or on those `finder` gives, as when it's
    /// chosen from Finder's own menu.
    func perform(_ action: Action, on finder: (any FinderAccess)? = nil) async {
        let finder = finder ?? self.finder
        do {
            switch action {
            case .newFile: try await newFile(finder)
            case .copyPath: try await copyPath(finder)
            case .openInTerminal: try await openInTerminal(finder)
            case .resizeImages: try await resizeImages(finder)
            }
        } catch {
            show(error.localizedDescription, isError: true)
            // A shortcut runs with no window showing the message.
            NSSound.beep()
        }
    }

    private func newFile(_ finder: any FinderAccess) async throws {
        let name = newFileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":") else {
            throw CommandError(errorDescription: "Set a name for new files without / or :.")
        }
        let folder = try await finder.currentFolder()
        let url = ImageResizer.unique(
            folder.appending(path: name),
            exists: { [fileManager] in
                fileManager.fileExists(atPath: $0.path(percentEncoded: false))
            })
        guard fileManager.createFile(atPath: url.path(percentEncoded: false), contents: Data()) else {
            throw CommandError(errorDescription: "Couldn't make a file in \(folder.lastPathComponent).")
        }
        reveal([url])
        show("Made \(url.lastPathComponent).", isError: false)
    }

    private func copyPath(_ finder: any FinderAccess) async throws {
        var urls = try await finder.selection()
        if urls.isEmpty { urls = [try await finder.currentFolder()] }
        pasteboard.copy(urls.map(pathStyle.format).joined(separator: "\n"))
        show(urls.count == 1 ? "Copied \(pathStyle.format(urls[0]))." : "Copied \(urls.count) paths.", isError: false)
    }

    private func openInTerminal(_ finder: any FinderAccess) async throws {
        let selected = try await finder.selection().first
        let folder: URL
        if let selected {
            folder = selected.hasDirectoryPath ? selected : selected.deletingLastPathComponent()
        } else {
            folder = try await finder.currentFolder()
        }
        try await openFolder(folder, terminalID)
        show("Opened \(PathStyle.home.format(folder)).", isError: false)
    }

    private func resizeImages(_ finder: any FinderAccess) async throws {
        let images = try await finder.selection().filter(ImageResizer.isImage)
        guard !images.isEmpty else { throw CommandError(errorDescription: "Select some images in Finder first.") }
        let size = imageSize
        let outcomes = await Self.resize(images, longestSide: size)
        let made = outcomes.compactMap { if case .resized(let url) = $0 { url } else { nil } }
        let small = outcomes.count { $0 == .alreadySmall }
        let failures = outcomes.compactMap { if case .failed(let message) = $0 { message } else { nil } }
        if !made.isEmpty { reveal(made) }
        var parts: [String] = []
        if !made.isEmpty { parts.append("Made \(made.count) cop\(made.count == 1 ? "y" : "ies") at \(size)px.") }
        if small > 0 { parts.append("\(small) already \(size)px or smaller.") }
        parts += failures
        show(parts.joined(separator: " "), isError: !failures.isEmpty || made.isEmpty)
    }

    @concurrent
    private nonisolated static func resize(_ images: [URL], longestSide: Int) async -> [ImageResizer.Outcome] {
        images.map { ImageResizer.resize($0, longestSide: longestSide) }
    }

    private func show(_ text: String, isError: Bool) {
        message = text
        self.isError = isError
    }

    /// Opens `folder` in the app with `bundleID`; terminals open a new window there.
    static func open(_ folder: URL, inAppWithID bundleID: String) async throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw CommandError(errorDescription: "That terminal app isn't installed. Choose another in Finder Extras.")
        }
        _ = try await NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension FinderAction {
    var shortcut: ShortcutDefinition {
        ShortcutDefinition(id: "finderExtras.\(rawValue)", module: .finderExtras, title: title, defaultHotKey: nil)
    }
}

/// What Finder's menu was opened on, handed over by the extension.
nonisolated struct FinderMenuSnapshot: FinderAccess {
    let request: FinderMenuRequest

    func selection() async throws -> [URL] { request.selection }
    func currentFolder() async throws -> URL { request.folder }
}

/// Tells requests from the app's own Finder extension apart from other apps' and web pages'.
nonisolated enum FinderMenuSender {
    static let extensionName = "FinderExtension.appex"

    /// Whether the sending process runs from inside this app's bundled extension.
    static func isOwnExtension(executablePath: String?, appBundle: URL) -> Bool {
        guard let executablePath else { return false }
        let plugin = appBundle.appending(path: "Contents/PlugIns/\(extensionName)", directoryHint: .isDirectory)
            .resolvingSymlinksInPath().path(percentEncoded: false)
        let sender = URL(filePath: executablePath).resolvingSymlinksInPath().path(percentEncoded: false)
        return sender.hasPrefix(plugin.hasSuffix("/") ? plugin : plugin + "/")
    }
}
