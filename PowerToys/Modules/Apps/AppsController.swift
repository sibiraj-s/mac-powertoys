import Foundation

/// The Apps module: one list of installed apps, which can be uninstalled or checked for updates.
final class AppsController {
    let list: InstalledAppList
    let uninstaller: AppUninstaller
    let updates: AppUpdateChecker

    init(list: InstalledAppList, uninstaller: AppUninstaller, updates: AppUpdateChecker) {
        self.list = list
        self.uninstaller = uninstaller
        self.updates = updates
    }

    convenience init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let list = InstalledAppList(folders: AppUninstall.appFolders(home: home))
        self.init(list: list, uninstaller: AppUninstaller(list: list, home: home), updates: AppUpdateChecker(list: list))
    }
}
