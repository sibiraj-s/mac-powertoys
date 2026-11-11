// PowerToys' Awake helper. launchd runs it as root once the app registers it, from the plist in
// Contents/Library/LaunchDaemons, whose only argument is the app's bundle ID. It does one thing:
// turn system sleep off and back on, for the app signed with that ID by the same team as this helper.

import Foundation
import Security
import Synchronization

/// Which connections want sleep off. Sleep is off while any does.
nonisolated final class SleepHolds: Sendable {
    private let state = Mutex<(holders: Set<UUID>, isClosing: Bool)>(([], false))

    /// Applies the result every time, not only when it changes, so a pmset that failed before gets another go.
    func set(_ disabled: Bool, for id: UUID) -> Bool {
        state.withLock { state in
            // Shutting down: no new hold may turn sleep off after `releaseAll` turned it on.
            if state.isClosing { return !disabled }
            if disabled { state.holders.insert(id) } else { state.holders.remove(id) }
            return Self.pmset(disableSleep: !state.holders.isEmpty)
        }
    }

    /// Lets every hold go, turns sleep back on and refuses holds from then on, for a helper about to exit.
    func releaseAll() {
        state.withLock { state in
            state.holders.removeAll()
            state.isClosing = true
            _ = Self.pmset(disableSleep: false)
        }
    }

    static func pmset(disableSleep: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", disableSleep ? "1" : "0"]
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

nonisolated final class Session: NSObject, AwakeHelperProtocol {
    let id = UUID()
    let holds: SleepHolds

    init(holds: SleepHolds) {
        self.holds = holds
    }

    func setSleepDisabled(_ disabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        reply(holds.set(disabled, for: id))
    }
}

nonisolated final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let clientRequirement: String?
    let holds = SleepHolds()

    init(clientRequirement: String?) {
        self.clientRequirement = clientRequirement
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Unsigned or ad hoc builds have no team to check callers against, so nothing may connect.
        guard let clientRequirement else { return false }
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: AwakeHelperProtocol.self)
        let session = Session(holds: holds)
        connection.exportedObject = session
        let id = session.id
        let holds = holds
        // The app quit, crashed or let go: its hold ends with it.
        connection.invalidationHandler = { _ = holds.set(false, for: id) }
        connection.resume()
        return true
    }
}

/// The app with `bundleID`, signed by the team that signed this helper.
nonisolated func clientRequirement(bundleID: String) -> String? {
    guard bundleID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }) else { return nil }
    var code: SecCode?
    var staticCode: SecStaticCode?
    var info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
        SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
        SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    else { return nil }
    return "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(team)\""
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: AwakeHelper <app bundle ID>\n".utf8))
    exit(64)
}
// `disablesleep` outlives this process, so sleep left off by a helper that crashed, or by a Mac
// that lost power, comes back on here. Nothing holds it yet: launchd starts the helper at boot
// (RunAtLoad) or for a new connection.
_ = SleepHolds.pmset(disableSleep: false)
// launchd stops the helper with SIGTERM when it's turned off in System Settings, unregistered,
// replaced by an update or the Mac shuts down; sleep comes back on before it goes.
signal(SIGTERM, SIG_IGN)
let delegate = ListenerDelegate(clientRequirement: clientRequirement(bundleID: arguments[1]))
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    delegate.holds.releaseAll()
    exit(0)
}
termination.resume()
let listener = NSXPCListener(machServiceName: AwakeHelperService.name(appBundleID: arguments[1]))
listener.delegate = delegate
listener.resume()
dispatchMain()
