import SwiftUI

@main
struct PowerToysApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var state = AppState()
    @AppStorage("showsMenuBarIcon") private var showsMenuBarIcon = true

    var body: some Scene {
        Window(AppInfo.name, id: MainWindow.id) {
            MainView()
                .environment(state)
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
                .environment(state)
        } label: {
            Image(systemName: state.awake.isActive ? "cup.and.saucer.fill" : "wrench.and.screwdriver")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Closing the window keeps modules running; the app quits only from the menu or ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
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
