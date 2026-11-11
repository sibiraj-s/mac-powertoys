import AppKit
import Testing

@testable import PowerToys

struct AwakeControllerTests {
    private let store = TestDefaults()

    @Test func durationIntervals() {
        #expect(AwakeController.Duration.indefinitely.interval == nil)
        #expect(AwakeController.Duration.minutes15.interval == 900)
        #expect(AwakeController.Duration.minutes30.interval == 1_800)
        #expect(AwakeController.Duration.hour1.interval == 3_600)
        #expect(AwakeController.Duration.hours2.interval == 7_200)
        #expect(AwakeController.Duration.hours4.interval == 14_400)
    }

    @Test func indefiniteHasNoEndTime() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep())
        defer { awake.stop() }

        awake.start(.indefinitely)
        #expect(awake.isActive)
        #expect(awake.endsAt == nil)
    }

    @Test func timedSetsEndTime() throws {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep())
        defer { awake.stop() }

        awake.start(.hour1)
        let endsAt = try #require(awake.endsAt)
        #expect(abs(endsAt.timeIntervalSinceNow - 3_600) < 5)
    }

    @Test func stopClearsState() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep())
        awake.start(.minutes30)
        awake.stop()
        #expect(!awake.isActive)
        #expect(awake.endsAt == nil)
    }

    @Test func toggleReusesLastDuration() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep())
        defer { awake.stop() }

        awake.start(.hours2)
        awake.toggle()
        #expect(!awake.isActive)

        awake.toggle()
        #expect(awake.isActive)
        #expect(awake.lastDuration == .hours2)
        #expect(awake.endsAt != nil)
    }

    @Test func changingDisplaySettingKeepsEndTime() throws {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep())
        defer { awake.stop() }

        awake.start(.hour1)
        let before = try #require(awake.endsAt)
        awake.keepsDisplayOn = true
        #expect(awake.isActive)
        #expect(awake.endsAt == before)
    }

    @Test func displaySettingPersists() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep())
        awake.keepsDisplayOn = true
        #expect(AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep()).keepsDisplayOn)
    }
}

struct AwakeDisplayConnectedTests {
    private let store = TestDefaults()

    @Test func holdsOnlyWhileExternalDisplayConnected() {
        var connected = false
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { connected }, isLaptop: true)
        defer { awake.stopWatchingDisplays() }
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()
        #expect(!awake.isHeldByDisplay)

        connected = true
        awake.updateDisplayHold()
        #expect(awake.isHeldByDisplay)

        connected = false
        awake.updateDisplayHold()
        #expect(!awake.isHeldByDisplay)
    }

    @Test func wakeRechecksDisplays() {
        var connected = true
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { connected }, isLaptop: true)
        defer { awake.stopWatchingDisplays() }
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()
        #expect(awake.isHeldByDisplay)

        // Unplugged while asleep: no screen change arrives, only the wake.
        connected = false
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!awake.isHeldByDisplay)
    }

    @Test func settingOffReleasesHold() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { true }, isLaptop: true)
        defer { awake.stopWatchingDisplays() }
        awake.startWatchingDisplays()
        #expect(!awake.isHeldByDisplay)

        awake.whileDisplayConnected = true
        #expect(awake.isHeldByDisplay)
        awake.whileDisplayConnected = false
        #expect(!awake.isHeldByDisplay)
    }

    @Test func noHoldWhileNotWatching() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { true }, isLaptop: true)
        awake.whileDisplayConnected = true
        #expect(!awake.isHeldByDisplay)

        awake.startWatchingDisplays()
        #expect(awake.isHeldByDisplay)
        awake.stopWatchingDisplays()
        #expect(!awake.isHeldByDisplay)
    }

    @Test func turningOffPausesHoldUntilUnplugged() async throws {
        var connected = true
        let awake = AwakeController(
            defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { connected }, isLaptop: true, unplugGrace: 0.05)
        defer { awake.stopWatchingDisplays() }
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()
        #expect(awake.isKeepingAwake)

        awake.toggle()
        #expect(!awake.isKeepingAwake)
        awake.updateDisplayHold()
        #expect(!awake.isHeldByDisplay)

        awake.toggle()
        #expect(awake.isActive)
        awake.toggle()
        #expect(!awake.isKeepingAwake)

        #expect(awake.isDisplayHoldPaused)
        connected = false
        awake.updateDisplayHold()
        // Waits for the grace period to run out, however long a busy machine takes to get there.
        let deadline = Date.now.addingTimeInterval(5)
        while awake.isDisplayHoldPaused, Date.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!awake.isDisplayHoldPaused)
        connected = true
        awake.updateDisplayHold()
        #expect(awake.isHeldByDisplay)
    }

    /// After wake, a display can be missing for a moment; that isn't an unplug.
    @Test func briefDisplayDropoutKeepsPause() async throws {
        var connected = true
        let awake = AwakeController(
            defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { connected }, isLaptop: true, unplugGrace: 0.05)
        defer { awake.stopWatchingDisplays() }
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()
        awake.toggle()

        connected = false
        awake.updateDisplayHold()
        connected = true
        awake.updateDisplayHold()
        try await Task.sleep(for: .milliseconds(300))
        awake.updateDisplayHold()
        #expect(awake.isDisplayHoldPaused)
        #expect(!awake.isHeldByDisplay)
    }

    @Test func turningOffEndsSessionAndHoldTogether() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { true }, isLaptop: true)
        defer { awake.stopWatchingDisplays() }
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()
        awake.start(.indefinitely)

        awake.toggle()
        #expect(!awake.isActive)
        #expect(!awake.isHeldByDisplay)
    }

    @Test func holdSurvivesManualStopAndDisplaySetting() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { true }, isLaptop: true)
        defer { awake.stopWatchingDisplays() }
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()

        awake.start(.hour1)
        awake.stop()
        awake.keepsDisplayOn = true
        #expect(awake.isHeldByDisplay)
        #expect(!awake.isActive)
    }

    @Test func desktopNeverHolds() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { true }, isLaptop: false)
        defer { awake.stopWatchingDisplays() }
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()
        #expect(!awake.isHeldByDisplay)
    }

    @Test func settingPersists() {
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { false })
        awake.whileDisplayConnected = true
        #expect(AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep(), hasExternalDisplay: { false }).whileDisplayConnected)
    }
}

struct AwakeUntilTimeTests {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func laterTodayStaysToday() {
        let next = AwakeController.nextOccurrence(of: date(1, 18, 30), after: date(27, 9, 0), calendar: calendar)
        #expect(next == date(27, 18, 30))
    }

    @Test func earlierTimeRollsToTomorrow() {
        let next = AwakeController.nextOccurrence(of: date(1, 8, 0), after: date(27, 9, 0), calendar: calendar)
        #expect(next == date(28, 8, 0))
    }

    @Test func startUntilTimeSetsEndTime() throws {
        let store = TestDefaults()
        let awake = AwakeController(defaults: store.defaults, lidSleep: FakeLidSleep())
        defer { awake.stop() }

        let target = Date.now.addingTimeInterval(2 * 60 * 60)
        awake.start(untilTimeOfDay: target)
        let endsAt = try #require(awake.endsAt)
        #expect(awake.isActive)
        #expect(abs(endsAt.timeIntervalSince(target)) < 60)
    }
}

struct AwakeLidClosedTests {
    private let store = TestDefaults()

    /// What the battery reads, as `Hardware.batteryPercentOnBattery` would: nil on power.
    private final class Power {
        var percent: Int?
        var sleeps = 0
    }

    private func makeAwake(
        _ lid: FakeLidSleep, isLaptop: Bool = true, display: Bool = false, power: Power = Power()
    ) -> AwakeController {
        AwakeController(
            defaults: store.defaults, lidSleep: lid, hasExternalDisplay: { display }, isLaptop: isLaptop,
            batteryPercent: { power.percent }, sleepIfLidClosed: { power.sleeps += 1 })
    }

    @Test func lowBatteryLetsItSleepAndPluggingInResumes() {
        let lid = FakeLidSleep()
        let power = Power()
        power.percent = 50
        let awake = makeAwake(lid, power: power)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        #expect(lid.calls == [true])

        power.percent = 20
        awake.powerSourceChanged()
        #expect(lid.calls == [true])

        power.percent = 19
        awake.powerSourceChanged()
        #expect(lid.calls == [true, false])
        #expect(awake.isLidClosedPausedForBattery)
        #expect(power.sleeps == 1)
        #expect(awake.isActive)

        awake.powerSourceChanged()
        #expect(power.sleeps == 1)

        power.percent = 21
        awake.powerSourceChanged()
        #expect(lid.calls == [true, false])
        #expect(awake.isLidClosedPausedForBattery)

        power.percent = nil
        awake.powerSourceChanged()
        #expect(lid.calls == [true, false, true])
        #expect(!awake.isLidClosedPausedForBattery)
    }

    @Test func endingTheSessionSendsAClosedLaptopToSleep() {
        let lid = FakeLidSleep()
        let power = Power()
        let awake = makeAwake(lid, power: power)
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        #expect(power.sleeps == 0)
        awake.stop()
        #expect(power.sleeps == 1)
    }

    @Test func endingTheSessionLeavesAClamshellSetupAwake() {
        let lid = FakeLidSleep()
        let power = Power()
        let awake = makeAwake(lid, display: true, power: power)
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        awake.stop()
        #expect(lid.calls == [true, false])
        #expect(power.sleeps == 0)
    }

    @Test func theBatteryPauseOutlastsTheSession() {
        let lid = FakeLidSleep()
        let power = Power()
        power.percent = 19
        let awake = makeAwake(lid, power: power)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.hour1)
        awake.stop()
        power.percent = 25
        awake.start(.hour1)
        #expect(lid.calls.isEmpty)
        #expect(awake.isLidClosedPausedForBattery)

        awake.stop()
        power.percent = nil
        awake.start(.hour1)
        #expect(lid.calls == [true])
    }

    @Test func turningTheSwitchOffMidSessionDoesntSleepTheMac() {
        let lid = FakeLidSleep()
        let power = Power()
        let awake = makeAwake(lid, power: power)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        awake.setKeepsAwakeWithLidClosed(false)
        #expect(lid.calls == [true, false])
        #expect(power.sleeps == 0)
    }

    @Test func aRetryForAHelperThatsGoneStopsAndTurnsTheSwitchOff() async {
        let lid = FakeLidSleep()
        let awake = AwakeController(
            defaults: store.defaults, lidSleep: lid, isLaptop: true, batteryPercent: { nil }, sleepIfLidClosed: {},
            releaseRetryDelay: .milliseconds(20))
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        lid.works = false
        awake.stop()
        lid.isAllowed = false
        let deadline = Date.now.addingTimeInterval(2)
        while awake.keepsAwakeWithLidClosed, Date.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!awake.keepsAwakeWithLidClosed)
        #expect(lid.calls == [true, false])
    }

    @Test func startingOnLowBatteryNeverTurnsSleepOff() {
        let lid = FakeLidSleep()
        let power = Power()
        power.percent = 5
        let awake = makeAwake(lid, power: power)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        #expect(lid.calls.isEmpty)
        #expect(awake.isLidClosedPausedForBattery)
        #expect(power.sleeps == 0)
    }

    @Test func lowBatteryIsNoNewsWithoutASession() {
        let lid = FakeLidSleep()
        let power = Power()
        power.percent = 5
        let awake = makeAwake(lid, power: power)
        awake.setKeepsAwakeWithLidClosed(true)
        #expect(!awake.isLidClosedPausedForBattery)
    }

    @Test func changingTheSessionKeepsTheHold() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.hour1)
        awake.start(.hours2)
        awake.keepsDisplayOn = true
        #expect(lid.calls == [true])
        #expect(awake.isActive)
    }

    @Test func aRestartedHelperIsAskedAgain() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        lid.onInterrupted?()
        #expect(lid.calls == [true, true])
    }

    @Test func helperStaysWhileItCouldNotLetTheMacSleep() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        lid.works = false
        awake.setKeepsAwakeWithLidClosed(false)
        #expect(lid.disallowed == 0)
        #expect(awake.lidClosedProblem != nil)
        awake.stop()
    }

    @Test func aHelperRemovedInSettingsTurnsTheSwitchOff() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        awake.setKeepsAwakeWithLidClosed(true)
        lid.isAllowed = false
        #expect(!makeAwake(lid).keepsAwakeWithLidClosed)
        #expect(!makeAwake(lid).keepsAwakeWithLidClosed)
        _ = awake
    }

    @Test func turningOffMidSessionUnregistersOnceTheHoldIsGone() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        lid.works = false
        awake.setKeepsAwakeWithLidClosed(false)
        #expect(lid.disallowed == 0)
        lid.works = true
        awake.powerSourceChanged()
        #expect(lid.calls == [true, false, false])
        #expect(lid.disallowed == 1)
    }

    @Test func aFailedReleaseStillSendsAClosedLaptopToSleep() {
        let lid = FakeLidSleep()
        let power = Power()
        let awake = makeAwake(lid, power: power)
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        lid.works = false
        awake.stop()
        #expect(power.sleeps == 1)
    }

    @Test func launchingWithTheSwitchOffUnregistersTheHelper() {
        let lid = FakeLidSleep()
        lid.isAllowed = true
        _ = makeAwake(lid)
        #expect(lid.disallowed == 1)
        #expect(!lid.isAllowed)
    }

    @Test func helperTurnedOffInSettingsMidSessionTurnsTheSwitchOff() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        lid.isAllowed = false
        lid.onInterrupted?()
        #expect(!awake.keepsAwakeWithLidClosed)
        #expect(awake.lidClosedProblem != nil)
        #expect(lid.calls == [true])
    }

    @Test func aRestartAfterTurningOffMidSessionUnregisters() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        lid.works = false
        awake.setKeepsAwakeWithLidClosed(false)
        #expect(lid.disallowed == 0)
        lid.onInterrupted?()
        #expect(lid.disallowed == 1)
    }

    @Test func aFailedReleaseIsRetriedWithoutAPowerChange() async {
        let lid = FakeLidSleep()
        let awake = AwakeController(
            defaults: store.defaults, lidSleep: lid, isLaptop: true, batteryPercent: { nil }, sleepIfLidClosed: {},
            releaseRetryDelay: .milliseconds(20))
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        lid.works = false
        awake.stop()
        lid.works = true
        let deadline = Date.now.addingTimeInterval(2)
        while lid.calls.count < 3, Date.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(lid.calls == [true, false, false])
        #expect(awake.lidClosedProblem == nil)
    }

    @Test func failingToLetItSleepIsRetried() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        lid.works = false
        awake.stop()
        #expect(lid.calls == [true, false])
        lid.works = true
        awake.powerSourceChanged()
        #expect(lid.calls == [true, false, false])
        #expect(awake.lidClosedProblem == nil)
    }

    @Test func turningOnAllowsTheHelperAndIsRemembered() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        awake.setKeepsAwakeWithLidClosed(true)
        #expect(lid.isAllowed)
        #expect(awake.keepsAwakeWithLidClosed)
        #expect(makeAwake(lid).keepsAwakeWithLidClosed)
    }

    @Test func waitingForApprovalLeavesItOffAndSaysWhy() {
        let lid = FakeLidSleep()
        lid.needsApproval = true
        let awake = makeAwake(lid)
        awake.setKeepsAwakeWithLidClosed(true)
        #expect(!awake.keepsAwakeWithLidClosed)
        #expect(awake.lidClosedProblem == LidSleepNeedsApproval().errorDescription)
    }

    @Test func turningOffUnregistersTheHelper() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        awake.setKeepsAwakeWithLidClosed(true)
        awake.setKeepsAwakeWithLidClosed(false)
        #expect(!lid.isAllowed)
        #expect(lid.disallowed == 1)
    }

    @Test func sleepIsOffOnlyDuringASession() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        awake.setKeepsAwakeWithLidClosed(true)
        #expect(lid.calls.isEmpty)

        awake.start(.hour1)
        #expect(lid.calls == [true])
        awake.turnOff()
        #expect(lid.calls == [true, false])
    }

    @Test func turningTheSettingOffMidSessionLetsItSleep() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        awake.setKeepsAwakeWithLidClosed(false)
        #expect(lid.calls == [true, false])
        #expect(awake.isActive)
    }

    @Test func displayHoldCountsToo() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid, display: true)
        defer { awake.stopWatchingDisplays() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()
        #expect(lid.calls == [true])
        awake.stopWatchingDisplays()
        #expect(lid.calls == [true, false])
    }

    @Test func desktopsNeverTurnSleepOff() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid, isLaptop: false)
        defer { awake.stop() }
        awake.setKeepsAwakeWithLidClosed(true)
        awake.start(.indefinitely)
        #expect(lid.calls.isEmpty)
    }

    @Test func failureIsReportedAndRetried() {
        let lid = FakeLidSleep()
        let awake = makeAwake(lid)
        awake.setKeepsAwakeWithLidClosed(true)
        lid.works = false
        awake.start(.indefinitely)
        #expect(awake.lidClosedProblem != nil)
        #expect(lid.calls == [true])

        // Sleep never went off, so stopping has nothing to undo.
        lid.works = true
        awake.stop()
        #expect(lid.calls == [true])
        awake.start(.indefinitely)
        #expect(lid.calls == [true, true])
        #expect(awake.lidClosedProblem == nil)
        awake.stop()
    }

    @Test func serviceNameFollowsTheBundleID() {
        #expect(AwakeHelperService.name(appBundleID: "dev.sibiraj.powertoys") == "dev.sibiraj.powertoys.AwakeHelper")
    }
}
