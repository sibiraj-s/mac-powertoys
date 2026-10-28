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

## Build

```sh
open PowerToys.xcodeproj

# or from the command line
xcodebuild -project PowerToys.xcodeproj -scheme PowerToys -derivedDataPath build/DerivedData build

# tests (⌘U in Xcode)
xcodebuild test -project PowerToys.xcodeproj -scheme PowerToys -derivedDataPath build/DerivedData
```

### Signing

Builds are signed ad hoc by default (`Signing.xcconfig`). macOS ties permission grants to the signature, and an ad hoc signature changes with every build, so Accessibility and Screen Recording must be granted again after each rebuild. To keep them, create a gitignored `Local.xcconfig` next to it:

```
CODE_SIGN_STYLE = Manual
CODE_SIGN_IDENTITY = Developer ID Application
DEVELOPMENT_TEAM = <your team ID>
```

## Release

`scripts/build.sh [version]` builds a Release for Apple Silicon and packages it as `build/PowerToys-<version>.dmg`. With `APPLE_TEAM_ID`, `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID` set, in the environment or a gitignored `.env`, it signs with your Developer ID certificate and notarizes; otherwise it signs ad hoc.

Versions come from [Changesets](.changeset/README.md): add one with `npx changeset` alongside each user-facing change. On `master`, the Release workflow keeps a "Release powertoys@<version>" pull request open. Merging it builds, signs and notarizes the DMG, then tags `v<version>` and attaches the DMG to the GitHub Release. It needs these repository secrets: `APPLE_TEAM_ID`, `DEVELOPER_ID_CERTIFICATE_P12` (base64), `DEVELOPER_ID_CERTIFICATE_PASSWORD`, `NOTARY_KEY` (the .p8's contents), `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`.

## Adding a module

1. Add its entry to `ModuleCatalog.all` (`Core/Module.swift`) and set `isImplemented: true` once it works.
2. Put its logic in `Modules/<Name>/`, and give `AppState` an instance if it holds state.
3. Add its settings view to the `switch` in `ModuleDetailView.settings`.
4. For global shortcuts, give each action a `ShortcutDefinition` with a stable ID, a title and `defaultHotKey: nil`, add it to `ShortcutCatalog.all`, and call `shortcuts.activate` while the module is on. Show it with `ShortcutRow`, which records, saves and re-registers keys.

## License

[MIT](LICENSE)
