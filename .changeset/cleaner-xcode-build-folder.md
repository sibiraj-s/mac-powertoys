---
'powertoys': patch
---

Cleaner's "Xcode build data" now also empties the build folder Xcode is set to use, when you've moved it from the usual DerivedData folder. Apps built there are also removed from macOS's list of apps, so they stop piling up as extra entries in System Settings.
