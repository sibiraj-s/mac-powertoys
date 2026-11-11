# powertoys

## 1.4.2

### Patch Changes

- 33ddcf2: The menu bar icon no longer turns into a coffee cup while Awake is on. The Awake tile is highlighted while a connected display keeps the Mac awake, and tapping it, the Awake shortcut, or Stop pauses that hold until the display is unplugged
- 03a7c58: File Locksmith and Ports & Processes no longer signal a process whose ID was reused by another since it was listed

## 1.4.1

### Patch Changes

- 2b3d59f: App volume now works: macOS refused System Audio Recording even after it was allowed, because the app was missing the description macOS requires for it. If it still shows as needed after updating, turn PowerToys off and on again under System Audio Recording Only in System Settings
- fddbc45: Defaults Browser saves a new copy of a domain if its saved copy was deleted, instead of offering to restore a copy that's gone

## 1.4.0

### Minor Changes

- 8c93e85: Awake: a new "While a display is connected" switch keeps a laptop (not a desktop, whose screens are all external) awake whenever an external display is plugged in, separate from timed sessions, and lets it sleep again once the display is unplugged, even if that happened while the Mac was asleep. While it's holding the Mac awake, the menu bar icon shows the cup and Awake reads "Held by display"

### Patch Changes

- c4a8bea: Defaults Browser starts off on a fresh install
- 8d77e05: App updates: Chrome, Brave and VS Code are checked with their own update services, and apps with no other source are checked against Homebrew's public cask list, marked with an info symbol explaining where the version came from

## 1.3.0

### Minor Changes

- 9a6a975: Displays & Audio: Play together turns on several outputs at once, such as two pairs of Bluetooth headphones, as one PowerToys Multi-Output device, with a volume slider for each and one for them all in the menu bar, volume keys that change them all with Use volume keys on, and app volume working through it too
- a401786: Apps: a new module for the apps in your Applications folders. Uninstall one with its containers, settings, caches, logs, shared containers and launch agents, each with a checkbox, sorted by name, size or when it was last opened; untick the app to remove only its data and start it afresh. Everything goes to the Trash. Check for updates looks up newer versions in the App Store, apps' own Sparkle update feeds and Homebrew, without installing anything

### Patch Changes

- 89c25d9: Sidebar and Overview: modules are sorted by name within each group, and the groups now run System, Windows & input, Tools, Developer. Screen Ruler moves from Developer to Tools

## 1.2.0

### Minor Changes

- 0bce5ef: Ports & Processes: Listeners are labelled with the project they serve, the git repository they run in (worktrees by their repository), or else their working folder, in the menu bar and Settings, and can be searched by it

### Patch Changes

- 034f2f6: Menu bar: Opening Settings or clipboard history from the menu bar popup now closes the popup

## 1.1.0

### Minor Changes

- 65b7e23: Keep in menu bar when closed: Closing the window can hide the Dock icon while modules keep running in the menu bar, and right-clicking the menu bar icon shows a menu to quit

## 1.0.0

### Major Changes

- de99d1f: First stable release

## 0.1.0

### Minor Changes

- 7995b97: New Batch Rename module: Rename many files at once with find and replace or regular expressions, `{name}`, `{n}` and `{date}` (the date a photo was taken) in the new name, and case changes. A preview marks names that clash or can't be used, files can swap names, and the last rename can be undone
- f7a42a2: New Cleaner module: See CPU, memory and disk use, quit the busiest processes, and delete caches, logs, build data and unused Docker images to free space, and move data left by uninstalled apps to the Trash
- 8d71857: New Displays & Audio module: Switch speakers and microphones from the menu bar or a shortcut, mute the microphone everywhere (it stays muted when you switch mics), set each app's volume or mute it, and change external displays' brightness and speaker volume over DDC on Apple silicon, optionally with the keyboard's brightness, volume and mute keys (and F14/F15 or a volume knob), showing macOS's own indicator
- 7995b97: New File Locksmith module: See which processes are using a file, folder or disk, including a terminal whose working folder is on it, and quit or force quit them. Check as administrator to include system processes such as Spotlight, then eject the disk from the same page
- 7995b97: New Finder Extras module: Make a new file in the folder Finder is showing, copy the selected paths (in full, from ~, or quoted for Terminal), open the selected folder in Terminal, iTerm, Ghostty, Warp and other terminals, and save resized copies of selected images, each from a shortcut you assign or from a PowerToys submenu when you right-click files or empty space in Finder
- 4c83e16: First release: Zones, Clipboard, Awake, System Toggles, Hosts & Env, Ports & Processes, Launch Agents, Color Picker, Text Extractor and Defaults Browser
- 16950b6: New Keys module: Remap keys and shortcuts everywhere or in one app, or turn them off, and make Caps Lock Escape, Control or Hyper (⌃⌥⇧⌘), optionally Escape when tapped on its own
- bad4c36: New Pin & Crop module: Keep a live copy of any window floating above the others, or crop part of one into a floating live thumbnail. Double-click a pin to use the real window in its place
- 315a764: New Screen Ruler module: Freeze the screen and see the space between the nearest edges around the pointer; click to copy it, or drag over an area to copy its size, in points or pixels
- f4d12fe: New Scroll & Mouse module: Reverse scrolling for the mouse wheel and trackpad separately, smooth wheel scrolling, and Back, Forward or any keys on the middle and side buttons
- eae1611: New Window Switcher module: Switch between windows rather than apps, with previews, including minimized windows and those of hidden apps. Hold the shortcut's modifiers and tap its key to step through; let go to switch. Shows as a grid or a stack of cards, dims the screen around the selected window, and closes, minimizes, hides or quits from the keyboard

### Patch Changes

- 879e00a: Smaller downloads: The DMG now uses stronger compression, making the download about a quarter smaller
