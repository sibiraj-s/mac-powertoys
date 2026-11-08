import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PowerToys

struct FinderExtrasTests {
    private let store = TestDefaults()
    private let pasteboard = NSPasteboard.withUniqueName()

    private func controller(
        _ finder: FakeFinder, revealed: ((([URL]) -> Void))? = nil,
        openFolder: @escaping (URL, String) async throws -> Void = { _, _ in }
    ) -> FinderExtrasController {
        FinderExtrasController(
            defaults: store.defaults, finder: finder, pasteboard: pasteboard, reveal: revealed ?? { _ in },
            openFolder: openFolder)
    }

    @Test func formatsPaths() {
        let home = URL(filePath: NSHomeDirectory()).appending(path: "My Files/it's.txt")
        #expect(FinderExtrasController.PathStyle.full.format(home) == NSHomeDirectory() + "/My Files/it's.txt")
        #expect(FinderExtrasController.PathStyle.home.format(home) == "~/My Files/it's.txt")
        #expect(FinderExtrasController.PathStyle.quoted.format(home) == "'\(NSHomeDirectory())/My Files/it'\\''s.txt'")
        // Folders lose the trailing slash, except the root.
        #expect(FinderExtrasController.PathStyle.full.format(URL(filePath: "/tmp/x/", directoryHint: .isDirectory)) == "/tmp/x")
        #expect(FinderExtrasController.PathStyle.full.format(URL(filePath: "/", directoryHint: .isDirectory)) == "/")
    }

    @Test func makesNewFilesNumberedLikeFinder() async {
        let folder = TemporaryFolder()
        var revealed: [URL] = []
        let extras = controller(FakeFinder(folder: folder.url), revealed: { revealed += $0 })
        await extras.perform(.newFile)
        await extras.perform(.newFile)
        #expect(folder.names == ["untitled 2.txt", "untitled.txt"])
        #expect(revealed.map(\.lastPathComponent) == ["untitled.txt", "untitled 2.txt"])
        #expect(!extras.isError)

        for bad in ["bad/name", "..", "."] {
            extras.newFileName = bad
            await extras.perform(.newFile)
            #expect(extras.isError)
        }
        #expect(folder.names.count == 2)
    }

    @Test func copiesSelectedPathsOrTheFolder() async {
        let extras = controller(FakeFinder(selected: [URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/b c.txt")]))
        await extras.perform(.copyPath)
        #expect(pasteboard.string(forType: .string) == "/tmp/a.txt\n/tmp/b c.txt")

        let none = controller(FakeFinder(folder: URL(filePath: "/tmp/project/", directoryHint: .isDirectory)))
        none.pathStyle = .quoted
        await none.perform(.copyPath)
        #expect(pasteboard.string(forType: .string) == "'/tmp/project'")
    }

    @Test func opensTheSelectedFolderOrAFilesFolder() async {
        var opened: [(URL, String)] = []
        let open: (URL, String) async throws -> Void = { opened.append(($0, $1)) }

        let folder = URL(filePath: "/tmp/project/", directoryHint: .isDirectory)
        await controller(FakeFinder(selected: [folder]), openFolder: open).perform(.openInTerminal)
        await controller(FakeFinder(selected: [URL(filePath: "/tmp/project/main.swift")]), openFolder: open).perform(.openInTerminal)
        await controller(FakeFinder(folder: URL(filePath: "/tmp/other/", directoryHint: .isDirectory)), openFolder: open)
            .perform(.openInTerminal)
        #expect(opened.map { $0.0.path(percentEncoded: false) } == ["/tmp/project/", "/tmp/project/", "/tmp/other/"])
        #expect(opened.allSatisfy { $0.1 == "com.apple.Terminal" })
    }

    @Test func finderProblemsAreShown() async {
        let extras = controller(FakeFinder(failure: CommandError(errorDescription: "Allow it")))
        await extras.perform(.copyPath)
        #expect(extras.message == "Allow it")
        #expect(extras.isError)
    }

    @Test func remembersOptions() {
        let first = controller(FakeFinder())
        first.pathStyle = .home
        first.imageSize = 640
        first.terminalID = "com.mitchellh.ghostty"
        first.newFileName = "notes.md"
        let second = controller(FakeFinder())
        #expect(second.pathStyle == .home)
        #expect(second.imageSize == 640)
        #expect(second.terminalID == "com.mitchellh.ghostty")
        #expect(second.newFileName == "notes.md")
    }

    @Test func listsInstalledTerminalsAndTheChosenOne() {
        let ids = FinderExtrasController.installedTerminals(including: "org.alacritty", isInstalled: { $0 == "com.googlecode.iterm2" })
            .map(\.id)
        #expect(ids == ["com.apple.Terminal", "com.googlecode.iterm2", "org.alacritty"])
    }

    @Test func resizesImageCopies() async throws {
        let folder = TemporaryFolder()
        let original = folder.url.appending(path: "wide.png")
        try writePNG(width: 200, height: 100, to: original)
        let small = folder.url.appending(path: "small.png")
        try writePNG(width: 30, height: 30, to: small)

        let extras = controller(FakeFinder(selected: [original, small, folder.url.appending(path: "notes.txt")]))
        extras.imageSize = 50
        await extras.perform(.resizeImages)
        #expect(folder.names == ["small.png", "wide 50px.png", "wide.png"])
        #expect(extras.message == "Made 1 copy at 50px. 1 already 50px or smaller.")

        let copy = try #require(CGImageSourceCreateWithURL(folder.url.appending(path: "wide 50px.png") as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(copy, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 50)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 25)

        // A second copy at the same size gets a number.
        await extras.perform(.resizeImages)
        #expect(folder.names.contains("wide 50px 2.png"))
    }

    @Test func resizingNeedsImages() async {
        let extras = controller(FakeFinder(selected: [URL(filePath: "/tmp/notes.txt")]))
        await extras.perform(.resizeImages)
        #expect(extras.message == "Select some images in Finder first.")
    }

    @Test func uniqueNamesNumberLikeFinder() {
        let taken: Set<String> = ["a.txt", "a 2.txt", "Makefile"]
        let exists = { (url: URL) in taken.contains(url.lastPathComponent) }
        #expect(ImageResizer.unique(URL(filePath: "/x/a.txt"), exists: exists).lastPathComponent == "a 3.txt")
        #expect(ImageResizer.unique(URL(filePath: "/x/b.txt"), exists: exists).lastPathComponent == "b.txt")
        #expect(ImageResizer.unique(URL(filePath: "/x/Makefile"), exists: exists).lastPathComponent == "Makefile 2")
    }

    @Test func shortcutsStartUnsetAndBelongToTheModule() {
        for action in FinderExtrasController.Action.allCases {
            #expect(action.shortcut.defaultHotKey == nil)
            #expect(action.shortcut.module == .finderExtras)
        }
    }

    private func writePNG(width: Int, height: Int, to url: URL) throws {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

struct FinderMenuRequestTests {
    @Test func survivesTheTripAsAURL() throws {
        let request = FinderMenuRequest(
            action: .resizeImages,
            selection: [URL(filePath: "/Users/me/Photos & Videos/café 1.jpg"), URL(filePath: "/tmp/dir/", directoryHint: .isDirectory)],
            folder: URL(filePath: "/Users/me/Photos & Videos/", directoryHint: .isDirectory))
        let decoded = try #require(FinderMenuRequest(url: request.url))
        #expect(decoded == request)
        // Selected folders stay folders, so Open in Terminal opens them rather than their parent.
        #expect(decoded.selection[1].hasDirectoryPath)
        #expect(!decoded.selection[0].hasDirectoryPath)
        #expect(decoded.folder.hasDirectoryPath)
    }

    @Test func rejectsMalformedRequests() throws {
        let urls = [
            "https://run?action=copyPath&folder=/tmp",
            "powertoys-finder://other?action=copyPath&folder=/tmp",
            "powertoys-finder://run?action=formatDisk&folder=/tmp",
            "powertoys-finder://run?action=copyPath",
            "powertoys-finder://run?action=copyPath&folder=tmp",
            "powertoys-finder://run?action=copyPath&folder=/tmp&item=relative.txt",
        ]
        for text in urls {
            let url = try #require(URL(string: text))
            #expect(FinderMenuRequest(url: url) == nil, "\(text)")
        }
    }

    @Test func acceptsOnlyTheBundledExtension() {
        let app = URL(filePath: "/Applications/PowerToys.app", directoryHint: .isDirectory)
        let plugin = "/Applications/PowerToys.app/Contents/PlugIns/FinderExtension.appex"
        #expect(FinderMenuSender.isOwnExtension(executablePath: "\(plugin)/Contents/MacOS/FinderExtension", appBundle: app))
        #expect(!FinderMenuSender.isOwnExtension(executablePath: "/Applications/PowerToys.app/Contents/MacOS/PowerToys", appBundle: app))
        #expect(!FinderMenuSender.isOwnExtension(executablePath: "\(plugin)-copy/Contents/MacOS/FinderExtension", appBundle: app))
        #expect(!FinderMenuSender.isOwnExtension(executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", appBundle: app))
        #expect(!FinderMenuSender.isOwnExtension(executablePath: nil, appBundle: app))
    }

    @Test func actionsRunOnWhatTheMenuWasOpenedOn() async {
        let defaults = TestDefaults()
        let pasteboard = NSPasteboard.withUniqueName()
        // Finder itself isn't asked: the menu already said what's selected.
        let extras = FinderExtrasController(
            defaults: defaults.defaults, finder: FakeFinder(failure: CommandError(errorDescription: "Asked Finder")),
            pasteboard: pasteboard, reveal: { _ in }, openFolder: { _, _ in })
        let request = FinderMenuRequest(
            action: .copyPath, selection: [], folder: URL(filePath: "/tmp/project/", directoryHint: .isDirectory))
        await extras.perform(request.action, on: FinderMenuSnapshot(request: request))
        #expect(pasteboard.string(forType: .string) == "/tmp/project")
        #expect(!extras.isError)
    }

    /// The extension can't use the app's code, so it keeps its own copies of these.
    @Test func extensionNamesMatchTheApp() {
        #expect(FinderMenuRequest.appBundleID == Bundle.main.bundleIdentifier)
        #expect(FinderMenuRequest.enabledModulesKey == AppState.enabledModulesKey)
        #expect(FinderMenuRequest.moduleID == ModuleID.finderExtras.rawValue)
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes == [FinderMenuRequest.scheme])
    }

    @Test func menuRequestsWaitForTheModule() {
        let store = TestDefaults()
        let state = AppState.testing(defaults: store.defaults, hotKeys: FakeHotKeys(), system: FakeSystemSettings())
        #expect(!state.isEnabled(.finderExtras))
        // Off: nothing runs, so nothing is copied or made.
        state.handleFinderMenu(
            FinderMenuRequest(action: .newFile, selection: [], folder: URL(filePath: "/nonexistent/", directoryHint: .isDirectory)))
        #expect(state.finderExtras.message == nil)
    }
}
