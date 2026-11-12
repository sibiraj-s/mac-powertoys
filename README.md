# PowerToys

A collection of tools for macOS in one app. Each module turns on separately, asks for permissions only when you enable it, and takes no global shortcut until you assign one.

It's a regular app with a Dock icon and a main window where each module has its own page, plus a menu bar icon for quick toggles. Closing the window keeps it running in the menu bar.

## Modules

- **Zones** – Snap windows to halves, thirds, focus or 2×2 layouts per display. ⇧-drag to snap (⌥ to span), with shortcuts for moving between zones and displays.
- **Lanes** – Keep each display's windows in one row that scrolls sideways, like a scrolling window manager. New windows open beside the one you're using and keep the widths you give them; shortcuts move along the row, reorder windows, stack them and step through widths. Drag a window to another place in the row, or hold keys you choose and swipe or turn the wheel to scroll it. Turning it off puts every window back.
- **Clipboard** – Searchable history of text, links, colors, images and files, with pins, a preview pane and paste as plain text, Markdown or JSON. Stays on this Mac and skips concealed items.
- **Awake** – Keep the Mac awake indefinitely, for a set time or until a time of day, optionally with the display on. See [Vigil](https://github.com/sibiraj-s/vigil) for triggers and automation.
- **System Toggles** – Dark mode, Dock and menu bar hiding, desktop icons, hidden files, Wi‑Fi, screen saver, eject disks, empty Trash and more, each with an optional shortcut and menu bar tile.
- **Hosts & Env** – Edit `/etc/hosts` with on/off entries and groups; inspect PATH and environment variables for zsh, bash, fish and apps, with missing and duplicate PATH folders flagged.
- **Ports & Processes** – TCP listeners with their process, folder and uptime; quit or force quit, open in a browser, and spot ports open to the network.
- **Launch Agents** – Browse agents and daemons, see what each runs and when, and load, unload, start, stop or restart them.
- **Color Picker** – Pick any color on screen and copy it as HEX, RGB, HSL, HSB, SwiftUI, NSColor or UIColor. Keeps the last 24 colors.
- **Text Extractor** – Select part of the screen or a window and copy its text, or read QR codes and barcodes. Recognition runs locally with Vision.
- **Cleaner** – CPU, memory and disk use at a glance, quit the busiest processes, and delete caches, logs, Xcode and package build data, and unused Docker images and build cache, with a list to untick anything you want to keep. Data left by apps you uninstalled can be moved to the Trash, item by item.
- **Apps** – Uninstall apps along with their settings, caches, containers and launch agents, or remove only their data, all to the Trash. Check which apps have newer versions in the App Store, their own Sparkle update feeds or Homebrew; nothing is downloaded or installed.
- **Scroll & Mouse** – Reverse scrolling for the mouse wheel and trackpad separately, smooth wheel scrolling, and Back, Forward or any keys on the middle and side buttons.
- **Pin & Crop** – Keep a live copy of any window floating above the others, or drag over part of one to crop it into a live thumbnail. Pins follow you across Spaces; double-click one to bring its window forward, right-click for opacity.
- **Window Switcher** – Switch between windows rather than apps, with previews, including minimized windows and those of hidden apps. Hold your shortcut's modifiers and tap its key to step through; let go to switch. Shows as a grid or a stack of cards, dims the screen around the selected window, and closes, minimizes, hides or quits from the keyboard.
- **Keys** – Remap keys and shortcuts everywhere or in one app, or turn them off, and make Caps Lock Escape, Control or Hyper (⌃⌥⇧⌘), optionally Escape when tapped on its own.
- **Displays & Audio** – Switch speakers and microphones from the menu bar or a shortcut, mute the microphone everywhere (it stays muted when you switch mics), set each app's volume or mute it, and change external displays' brightness and speaker volume over DDC on Apple silicon, optionally with the keyboard's brightness, volume and mute keys (and F14/F15 or a volume knob), showing macOS's own indicator.
- **Batch Rename** – Rename many files at once with find and replace or regular expressions, `{name}`, `{n}` and `{date}` (when a photo was taken) in the new name, and case changes. The preview marks names that clash or can't be used; files can swap names, and the last rename can be undone.
- **File Locksmith** – See which processes are using a file, folder or disk, such as one that won't eject, and quit or force quit them. Check as administrator to include system processes like Spotlight, then eject from the same page.
- **Finder Extras** – New file in the folder Finder is showing, copy paths, open the selected folder in your terminal, and save resized copies of images, from a shortcut you assign or a PowerToys submenu in Finder's right-click menu (turn on the extension once in System Settings).
- **Screen Ruler** – Freeze the screen and see the space between the nearest edges around the pointer; click to copy it, or drag over an area to copy its size, in points or pixels. The edge tolerance can be set.
- **Defaults Browser** – Browse, edit and back up preference domains, copy keys as `defaults` commands, and flip well-known hidden settings for the Dock, Finder and more.

## Requirements

- macOS 15+
- Xcode 26+ (folder-synced groups, Swift 6 with MainActor default isolation)

The app isn't sandboxed, since Accessibility APIs and event taps don't work in the sandbox, so it ships outside the Mac App Store.

## License

[MIT](LICENSE)
