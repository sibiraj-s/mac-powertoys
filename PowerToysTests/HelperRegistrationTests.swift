import Foundation
import ServiceManagement
import Testing

@testable import PowerToys

/// Stands in for `SMAppService`, following its status the way launchd and System Settings would.
final class FakeDaemon: DaemonService {
    var status: SMAppService.Status
    /// What registering leads to: approval pending, or allowed straight away.
    var statusAfterRegister: SMAppService.Status = .enabled
    private(set) var registered = 0
    private(set) var unregistered = 0

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func register() throws {
        registered += 1
        status = statusAfterRegister
        // Like SMAppService, it throws while waiting for approval.
        if status == .requiresApproval { throw CocoaError(.featureUnsupported) }
    }

    func unregister() throws {
        unregistered += 1
        status = .notRegistered
    }
}

/// A daemon whose plist is missing, as in a broken build.
final class BrokenDaemon: DaemonService {
    var status: SMAppService.Status { .notFound }
    func register() throws { throw CocoaError(.fileNoSuchFile) }
    func unregister() throws {}
}

struct HelperRegistrationTests {
    private let store = TestDefaults()

    private func registration(
        _ service: FakeDaemon?, retired: FakeDaemon? = nil, openedSettings: (() -> Void)? = nil
    ) -> HelperRegistration {
        HelperRegistration(service: service, retired: retired, defaults: store.defaults, openSystemSettings: openedSettings ?? {})
    }

    @Test func allowingRegistersTheHelper() throws {
        let daemon = FakeDaemon()
        let helper = registration(daemon)
        try helper.allow(for: .lidSleep)
        #expect(helper.isAllowed)
        #expect(daemon.registered == 1)
        #expect(helper.uses == [.lidSleep])
    }

    @Test func waitingForApprovalOpensSystemSettingsAndThrows() {
        let daemon = FakeDaemon()
        daemon.statusAfterRegister = .requiresApproval
        var opened = 0
        let helper = registration(daemon, openedSettings: { opened += 1 })
        #expect(throws: HelperNeedsApproval.self) { try helper.allow(for: .network) }
        #expect(opened == 1)
        #expect(!helper.isAllowed)
        #expect(helper.uses == [.network])
    }

    /// Lid sleep's switch stays off while it waits, and each try is the user turning it on again.
    @Test func lidSleepOpensSystemSettingsEachTryWithoutHoldingTheHelper() {
        let daemon = FakeDaemon()
        daemon.statusAfterRegister = .requiresApproval
        var opened = 0
        let helper = registration(daemon, openedSettings: { opened += 1 })
        #expect(throws: HelperNeedsApproval.self) { try helper.allow(for: .lidSleep) }
        #expect(throws: HelperNeedsApproval.self) { try helper.allow(for: .lidSleep) }
        #expect(opened == 2)
        #expect(helper.uses.isEmpty)
    }

    /// With lid sleep's switch off after a try that needed approval, the Network module turning
    /// off leaves nothing using the helper, so it goes.
    @Test func aLidSleepTryWaitingForApprovalDoesntKeepTheHelper() throws {
        let daemon = FakeDaemon(status: .enabled)
        let helper = registration(daemon)
        try helper.allow(for: .network)
        daemon.status = .requiresApproval
        daemon.statusAfterRegister = .requiresApproval
        #expect(throws: HelperNeedsApproval.self) { try helper.allow(for: .lidSleep) }
        helper.release(.network)
        #expect(daemon.unregistered == 1)
    }

    /// Shortcuts and menu choices made while it waits don't bring System Settings back each time.
    @Test func systemSettingsOpensOnceWhileTheHelperWaits() {
        let daemon = FakeDaemon()
        daemon.statusAfterRegister = .requiresApproval
        var opened = 0
        let helper = registration(daemon, openedSettings: { opened += 1 })
        #expect(throws: HelperNeedsApproval.self) { try helper.allow(for: .network) }
        #expect(throws: HelperNeedsApproval.self) { try helper.allow(for: .network) }
        #expect(opened == 1)
    }

    /// Approved later in System Settings, while the app wasn't asking: another feature letting go
    /// at the next launch mustn't take it away.
    @Test func aHelperApprovedLaterStaysForTheFeatureThatAskedForIt() {
        let daemon = FakeDaemon()
        daemon.statusAfterRegister = .requiresApproval
        let helper = registration(daemon)
        #expect(throws: HelperNeedsApproval.self) { try helper.allow(for: .network) }
        daemon.status = .enabled
        registration(daemon).release(.lidSleep)
        #expect(daemon.unregistered == 0)
        #expect(helper.isAllowed)
    }

    @Test func turningTheFeatureOffWithdrawsARequestStillWaitingForApproval() {
        let daemon = FakeDaemon()
        daemon.statusAfterRegister = .requiresApproval
        let helper = registration(daemon)
        #expect(throws: HelperNeedsApproval.self) { try helper.allow(for: .network) }
        helper.release(.network)
        #expect(daemon.unregistered == 1)
        #expect(helper.uses.isEmpty)
    }

    @Test func allowingAnAllowedHelperRecordsTheUseWithoutRegisteringAgain() throws {
        let daemon = FakeDaemon(status: .enabled)
        let helper = registration(daemon)
        try helper.allow(for: .network)
        #expect(daemon.registered == 0)
        #expect(helper.uses == [.network])
    }

    @Test func aSecondFeatureKeepsTheHelperWhenTheFirstLetsGo() throws {
        let daemon = FakeDaemon()
        let helper = registration(daemon)
        try helper.allow(for: .lidSleep)
        // Network starts using the helper lid sleep already got allowed.
        try helper.allow(for: .network)
        helper.release(.lidSleep)
        #expect(daemon.unregistered == 0)
        #expect(helper.isAllowed)
    }

    /// A registration that fails outright, not for approval, doesn't record the feature as
    /// using the helper, which would keep it registered after the others let go.
    @Test func aFailedRegistrationIsntRecorded() {
        let helper = HelperRegistration(service: BrokenDaemon(), retired: nil, defaults: store.defaults, openSystemSettings: {})
        #expect(throws: CocoaError.self) { try helper.allow(for: .network) }
        #expect(helper.uses.isEmpty)
    }

    @Test func aBuildWithoutAHelperSaysSo() {
        #expect(throws: CommandError.self) { try registration(nil).allow(for: .lidSleep) }
    }

    @Test func staysRegisteredUntilTheLastUseLetsGo() throws {
        let daemon = FakeDaemon()
        let helper = registration(daemon)
        try helper.allow(for: .lidSleep)
        try helper.allow(for: .network)
        helper.release(.lidSleep)
        #expect(daemon.unregistered == 0)
        #expect(helper.isAllowed)
        helper.release(.network)
        #expect(daemon.unregistered == 1)
        #expect(!helper.isAllowed)
    }

    @Test func releasingAnUnregisteredHelperLeavesItAlone() {
        let daemon = FakeDaemon()
        registration(daemon).release(.lidSleep)
        #expect(daemon.unregistered == 0)
    }

    @Test func usesOutlastTheApp() throws {
        let daemon = FakeDaemon()
        try registration(daemon).allow(for: .network)
        // Next launch: lid sleep is off, but the network still needs the helper.
        let next = registration(daemon)
        next.release(.lidSleep)
        #expect(next.uses == [.network])
        #expect(daemon.unregistered == 0)
    }

    @Test func retiresAnAllowedOldHelper() {
        let old = FakeDaemon(status: .enabled)
        #expect(registration(FakeDaemon(), retired: old).retireOldHelper())
        #expect(old.unregistered == 1)
    }

    @Test func retiresAnOldHelperStillWaitingForApproval() {
        let old = FakeDaemon(status: .requiresApproval)
        #expect(!registration(FakeDaemon(), retired: old).retireOldHelper())
        #expect(old.unregistered == 1)
    }

    @Test func leavesAnOldHelperThatWasNeverRegistered() {
        let old = FakeDaemon(status: .notRegistered)
        #expect(!registration(FakeDaemon(), retired: old).retireOldHelper())
        #expect(old.unregistered == 0)
    }
}
