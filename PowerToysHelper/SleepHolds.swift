import Foundation
import Synchronization

/// Which connections want sleep off. Sleep is off while any does.
nonisolated final class SleepHolds: Sendable {
    /// `closed` holds connections that have gone, whose late requests are refused.
    private let state = Mutex<(holders: Set<UUID>, isClosing: Bool, closed: Set<UUID>)>(([], false, []))

    /// Applies the result every time, not only when it changes, so a pmset that failed before gets another go.
    func set(_ disabled: Bool, for id: UUID) -> Bool {
        state.withLock { state in
            // Shutting down: no new hold may turn sleep off after `releaseAll` turned it on.
            if state.isClosing { return !disabled }
            // Its connection closed already: XPC can deliver a request after the handler for that
            // ran, and nothing would let go of a hold taken then.
            if state.closed.contains(id) { return !disabled }
            if disabled { state.holders.insert(id) } else { state.holders.remove(id) }
            return Self.pmset(disableSleep: !state.holders.isEmpty)
        }
    }

    /// Lets go of `id`'s hold when its connection closes. A connection that never held sleep off,
    /// such as the Network module's, changes nothing.
    func release(_ id: UUID) {
        state.withLock { state in
            state.closed.insert(id)
            guard state.holders.remove(id) != nil else { return }
            _ = Self.pmset(disableSleep: !state.holders.isEmpty)
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
        Tool.run("/usr/bin/pmset", ["-a", "disablesleep", disableSleep ? "1" : "0"]).status == 0
    }
}
