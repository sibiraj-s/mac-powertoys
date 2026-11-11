import Foundation

/// What PowerToys asks of its Awake helper, which runs as root, over XPC.
@objc nonisolated protocol AwakeHelperProtocol {
    /// Turns system sleep off or back on with `pmset -a disablesleep`. Sleep comes back on by itself
    /// when the connection that turned it off closes, so a crashed app can't leave it off.
    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void)
}

nonisolated enum AwakeHelperService {
    /// Also the launchd label and the plist's name, so the Debug and installed apps each get their own.
    static func name(appBundleID: String) -> String { appBundleID + ".AwakeHelper" }
}
