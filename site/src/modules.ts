/// The app's modules, grouped as its sidebar groups them. Summaries are the app's own
/// (ModuleCatalog in PowerToys/Core/Module.swift); keep the two in step.
export type Module = {
  id: string;
  name: string;
  summary: string;
};

export type ModuleGroup = { name: string; modules: Module[] };

export const moduleGroups: ModuleGroup[] = [
  {
    name: 'Windows & input',
    modules: [
      {
        id: 'zones',
        name: 'Zones',
        summary:
          'Snap windows into halves, thirds or a grid, with a layout for each display. Hold ⇧ while dragging, or use shortcuts.',
      },
      {
        id: 'window-switcher',
        name: 'Window Switcher',
        summary:
          'Switch between windows rather than apps, with previews, including minimized windows and those of hidden apps.',
      },
      {
        id: 'keys',
        name: 'Keys',
        summary:
          'Remap keys and shortcuts or turn them off, everywhere or in one app, and turn Caps Lock into Hyper, Escape or Control.',
      },
      {
        id: 'scroll-mouse',
        name: 'Scroll & Mouse',
        summary:
          'Set the scroll direction separately for the mouse and trackpad, smooth out wheel scrolling, and make extra mouse buttons go Back, Forward or press keys.',
      },
      {
        id: 'pin-crop',
        name: 'Pin & Crop',
        summary:
          'Keep a live copy of a window, or just part of one, floating above the others on every Space.',
      },
    ],
  },
  {
    name: 'System',
    modules: [
      {
        id: 'awake',
        name: 'Awake',
        summary:
          'Keep the Mac awake indefinitely, for a set time or until a time of day, with or without the display on.',
      },
      {
        id: 'system-toggles',
        name: 'System Toggles',
        summary:
          'Switch dark mode, Dock and menu bar hiding, desktop icons, hidden files and Wi‑Fi, or eject disks and empty the Trash, from a shortcut or the menu bar.',
      },
      {
        id: 'displays-audio',
        name: 'Displays & Audio',
        summary:
          "Switch speakers and microphones, mute the microphone from a shortcut, set each app's volume, and change external displays' brightness and speaker volume.",
      },
      {
        id: 'cleaner',
        name: 'Cleaner',
        summary:
          'See CPU, memory and disk use, quit the busiest processes, and free space by deleting caches, logs, build data and what uninstalled apps left behind.',
      },
    ],
  },
  {
    name: 'Tools',
    modules: [
      {
        id: 'clipboard',
        name: 'Clipboard',
        summary:
          'Searchable history of the text, images and files you copy. Pin and preview items, and paste as plain text, Markdown or JSON.',
      },
      {
        id: 'color-picker',
        name: 'Color Picker',
        summary:
          'Pick any color on screen with a magnifier, from a shortcut or the menu bar. Copy it as HEX, RGB, HSL, HSB, or SwiftUI, AppKit or UIKit code.',
      },
      {
        id: 'text-extractor',
        name: 'Text Extractor',
        summary:
          'Select part of the screen or a window and copy the text in it, from a shortcut or the menu bar. Reads QR codes and barcodes too.',
      },
      {
        id: 'batch-rename',
        name: 'Batch Rename',
        summary:
          'Rename many files at once with find and replace or regex, case changes, numbering and photo dates, with a preview and undo.',
      },
      {
        id: 'file-locksmith',
        name: 'File Locksmith',
        summary:
          "See which processes are using a file, folder or disk, such as one that won't eject, and quit them.",
      },
      {
        id: 'finder-extras',
        name: 'Finder Extras',
        summary:
          "Make a new file in the folder Finder is showing, copy paths, open folders in a terminal and resize images, from shortcuts or Finder's right-click menu.",
      },
    ],
  },
  {
    name: 'Developer',
    modules: [
      {
        id: 'ports-processes',
        name: 'Ports & Processes',
        summary:
          "See what's listening on each port, such as :3000, with its command and folder, and quit it here or from the menu bar.",
      },
      {
        id: 'hosts-env',
        name: 'Hosts & Env',
        summary:
          'Edit /etc/hosts with groups you switch on and off together, and see PATH and the environment each shell and apps start with.',
      },
      {
        id: 'launch-agents',
        name: 'Launch Agents',
        summary:
          "See the launchd agents and daemons on your Mac: what they run and when, whether they're running, and turn them on or off.",
      },
      {
        id: 'defaults-browser',
        name: 'Defaults Browser',
        summary:
          'Browse and change the settings apps keep, hidden ones included, with a copy saved before the first change. Copy any key as a defaults command.',
      },
      {
        id: 'screen-ruler',
        name: 'Screen Ruler',
        summary:
          'Measure the space between edges on screen, or drag over an area, and copy its size in points or pixels.',
      },
    ],
  },
];
