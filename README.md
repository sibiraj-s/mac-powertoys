# PowerToys

A collection of tools for macOS in one app. Each module turns on separately, asks for permissions only when you enable it, and takes no global shortcut until you assign one.

It's a regular app with a Dock icon and a main window where each module has its own page, plus a menu bar icon for quick toggles. Closing the window keeps it running in the menu bar.

## Modules

- **Zones** – Snap windows to halves, thirds, focus or 2×2 layouts per display. ⇧-drag to snap (⌥ to span), with shortcuts for moving between zones and displays.
- **Clipboard** – Searchable history of text, links, colors, images and files, with pins, a preview pane and paste as plain text, Markdown or JSON. Stays on this Mac and skips concealed items.
- **Awake** – Keep the Mac awake indefinitely, for a set time or until a time of day, optionally with the display on. See [Vigil](https://github.com/sibiraj-s/vigil) for triggers and automation.
- **System Toggles** – Dark mode, Dock and menu bar hiding, desktop icons, hidden files, Wi‑Fi, screen saver, eject disks, empty Trash and more, each with an optional shortcut and menu bar tile.
- **Hosts & Env** – Edit `/etc/hosts` with on/off entries and groups; inspect PATH and environment variables for zsh, bash, fish and apps, with missing and duplicate PATH folders flagged.
- **Ports & Processes** – TCP listeners with their process, folder and uptime; quit or force quit, open in a browser, and spot ports open to the network.
- **Launch Agents** – Browse agents and daemons, see what each runs and when, and load, unload, start, stop or restart them.
- **Color Picker** – Pick any color on screen and copy it as HEX, RGB, HSL, HSB, SwiftUI, NSColor or UIColor. Keeps the last 24 colors.
- **Text Extractor** – Select part of the screen or a window and copy its text, or read QR codes and barcodes. Recognition runs locally with Vision.
- **Defaults Browser** – Browse, edit and back up preference domains, copy keys as `defaults` commands, and flip well-known hidden settings for the Dock, Finder and more.

12 more modules are listed in the app but not built yet.

## Requirements

- macOS 15+
- Xcode 26+ (folder-synced groups, Swift 6 with MainActor default isolation)

The app isn't sandboxed, since Accessibility APIs and event taps don't work in the sandbox, so it ships outside the Mac App Store.

## License

[MIT](LICENSE)
