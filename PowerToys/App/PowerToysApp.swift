import SwiftUI

@main
struct PowerToysApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage("showsMenuBarIcon") private var showsMenuBarIcon = true

    var body: some Scene {
        Window(AppInfo.name, id: MainWindow.id) {
            MainView()
                .environment(appDelegate.state)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 700)
        .windowResizability(.contentMinSize)
        .commands {
            // The main window is where everything is configured, so ⌘, opens it.
            CommandGroup(replacing: .appSettings) {
                OpenMainWindowButton(title: "Settings…")
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: $showsMenuBarIcon) {
            MenuBarView()
                .environment(appDelegate.state)
        } label: {
            Image(systemName: appDelegate.state.awake.isActive ? "cup.and.saucer.fill" : "wrench.and.screwdriver")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Made here rather than in a view, so requests from Finder's menu that launch the app have
    /// somewhere to go before any window opens.
    let state = AppState()

    /// Closing the window keeps modules running; the app quits only from the menu or ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // Installed before launch finishes, so a request that launched the app isn't missed, and
    // again after, in case SwiftUI installed its own handler in between.
    func applicationWillFinishLaunching(_ notification: Notification) {
        installURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installURLHandler()
    }

    /// Replaces SwiftUI's handler, which would open a window for every URL.
    private func installURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(openURL(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    /// Runs an action chosen in Finder's menu. Any app or web page can open the app's URLs, so
    /// only those sent by its own bundled extension are acted on.
    @objc private func openURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text),
            let request = FinderMenuRequest(url: url)
        else { return }
        let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
        let sender = pid > 0 ? ProcessDetails.executablePath(pid) : nil
        guard FinderMenuSender.isOwnExtension(executablePath: sender, appBundle: Bundle.main.bundleURL) else {
            NSLog("Ignored a Finder menu request from \(sender ?? "an unknown sender")")
            return
        }
        state.handleFinderMenu(request)
    }
}

enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "PowerToys"
}

enum MainWindow {
    static let id = "main"
}

struct OpenMainWindowButton: View {
    let title: String

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
    }
}
