# PowerToys

A modular menu bar app for macOS that fills the gaps power users usually cover with a handful of separate utilities. Each module turns on separately and asks for permissions only when you enable it.

Design: [Feature map, Settings and menu bar mockups](https://claude.ai/artifact/3zBSiCkd4YyfG8PbhGf4hh)

## Requirements

- macOS 15+
- Xcode 26+ (the project uses folder-synced groups and Swift 6 with MainActor default isolation)

## Build

```sh
open PowerToys.xcodeproj
# or
xcodebuild -project PowerToys.xcodeproj -scheme PowerToys -derivedDataPath build/DerivedData build

# tests (⌘U in Xcode)
xcodebuild test -project PowerToys.xcodeproj -scheme PowerToys -derivedDataPath build/DerivedData
```

### Signing

Builds are signed ad hoc by default (`Signing.xcconfig`). macOS ties permission grants to the signature, and an ad hoc signature changes with every build, so Accessibility and Screen Recording have to be granted again after each rebuild. To keep them, create a gitignored `Local.xcconfig` next to it:

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Developer ID Application
DEVELOPMENT_TEAM = <your team ID>
```

It is a regular app with a Dock icon and a main window, plus a menu bar icon for quick toggles. Closing the window keeps it running in the menu bar. It is not sandboxed: Accessibility APIs and event taps don't work in the sandbox, so it ships outside the Mac App Store.

## Layout

```
PowerToys/
  App/            App entry point, scenes
  Core/           Module catalog, permissions, app state
  Modules/<Name>/ One folder per module's logic
  UI/MenuBar/     Menu bar dropdown
  UI/Main/        Main window (sidebar, overview, permissions, module pages)
PowerToysTests/  Unit tests (Swift Testing), hosted in the app
PowerToys.entitlements   Signing entitlements (not sandboxed)
```

New files under `PowerToys/` are picked up by Xcode automatically, with no project file edits needed.

## Adding a module

1. The module's entry lives in `ModuleCatalog.all` (`Core/Module.swift`). Set `isImplemented: true` once it works.
2. Put its logic in `Modules/<Name>/` and give `AppState` an instance if it holds state.
3. Add its settings view to the `switch` in `ModuleDetailView.settings`.
4. For global shortcuts, give each action a `ShortcutDefinition` (stable ID, title, default keys), add it to `ShortcutCatalog.all`, and call `shortcuts.activate` while the module is on. Show it with `ShortcutRow`, which lets people record their own keys; changes are saved and re-registered automatically.

## Status

| Module | State |
| --- | --- |
| Zones | Halves, thirds, focus and 2×2 layouts per display; ⇧-drag to snap (⌥ to span), restore on unsnap; ⌃⌥ shortcuts for next/previous zone, fill, next display, switch layout, restore |
| Clipboard | History (⌃⌥V) of text, links, colors, images and files with search (including text in images), filters, pins and a preview pane; paste, copy, open, show in Finder or save images; paste as plain text, Markdown or JSON; ⌃⌥⇧V pastes as plain text. Can remove old items from the history, and empty the clipboard a set time after each copy. Kept on this Mac, skipping concealed items |
| Awake | Working (optional toggle shortcut): indefinitely, 15 min to 4 h, or until a time of day; optional display-on. Points to [Vigil](https://github.com/sibiraj-s/vigil) for triggers and automation |
| System Toggles | Dark mode (⌃⌥D), hide the Dock, menu bar or desktop icons, show hidden files or file extensions, Wi‑Fi; sleep display, screen saver, eject disks, empty Trash. Each can have a shortcut and a menu bar tile |
| Hosts & Env | Edit /etc/hosts: switch entries on and off, group them to switch together (groups are marker comments, so they work without the app), flags entries an earlier line overrides; saves with an admin prompt, flushes DNS, keeps the original. PATH and variables of a new zsh, bash or fish login shell and of apps, with missing and duplicate PATH folders flagged and secrets hidden |
| Other 17 | Listed in the main window with permissions and status, not built yet |
