import Foundation

/// The Finder Extras actions, shared by the app and its Finder menu extension.
nonisolated enum FinderAction: String, CaseIterable, Identifiable, Sendable {
    case newFile, copyPath, openInTerminal, resizeImages

    var id: Self { self }

    var title: String {
        switch self {
        case .newFile: "New file here"
        case .copyPath: "Copy path"
        case .openInTerminal: "Open in Terminal"
        case .resizeImages: "Resize images"
        }
    }

    /// The title in Finder's menu, in its title case.
    var menuTitle: String {
        switch self {
        case .newFile: "New File Here"
        case .copyPath: "Copy Path"
        case .openInTerminal: "Open in Terminal"
        case .resizeImages: "Resize Images"
        }
    }

    var hint: String {
        switch self {
        case .newFile: "Makes an empty file in the folder Finder is showing and selects it."
        case .copyPath: "The paths of the selected items, one per line, or of the folder Finder is showing."
        case .openInTerminal: "The selected folder, or the folder Finder is showing."
        case .resizeImages: "Saves smaller copies of the selected images next to them."
        }
    }

    var symbol: String {
        switch self {
        case .newFile: "doc.badge.plus"
        case .copyPath: "doc.on.doc"
        case .openInTerminal: "terminal"
        case .resizeImages: "photo"
        }
    }
}

/// An action chosen in Finder's menu, with what it was chosen on, passed from the extension to
/// the app as a URL. The extension starts the app first when it isn't running.
nonisolated struct FinderMenuRequest: Equatable, Sendable {
    static let scheme = "powertoys-finder"
    static let enabledModulesKey = "enabledModules"
    static let moduleID = "finderExtras"

    let action: FinderAction
    let selection: [URL]
    /// The folder the menu was opened in.
    let folder: URL

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = "run"
        components.queryItems =
            [URLQueryItem(name: "action", value: action.rawValue), URLQueryItem(name: "folder", value: folder.path(percentEncoded: false))]
            + selection.map { URLQueryItem(name: "item", value: $0.path(percentEncoded: false)) }
        return components.url!
    }

    init(action: FinderAction, selection: [URL], folder: URL) {
        self.action = action
        self.selection = selection
        self.folder = folder
    }

    /// Nil for URLs that aren't a well-formed request, such as relative paths.
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host() == "run",
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            let action = items.first(where: { $0.name == "action" })?.value.flatMap(FinderAction.init(rawValue:)),
            let folder = items.first(where: { $0.name == "folder" })?.value, folder.hasPrefix("/")
        else { return nil }
        let paths = items.filter { $0.name == "item" }.compactMap(\.value)
        guard paths.allSatisfy({ $0.hasPrefix("/") }) else { return nil }
        self.action = action
        self.folder = URL(filePath: folder, directoryHint: .isDirectory)
        selection = paths.map { URL(filePath: $0) }
    }
}
