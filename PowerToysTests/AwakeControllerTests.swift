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
        let awake = AwakeController(defaults: store.defaults)
        defer { awake.stop() }

        awake.start(.indefinitely)
        #expect(awake.isActive)
        #expect(awake.endsAt == nil)
    }

    @Test func timedSetsEndTime() throws {
        let awake = AwakeController(defaults: store.defaults)
        defer { awake.stop() }

        awake.start(.hour1)
        let endsAt = try #require(awake.endsAt)
        #expect(abs(endsAt.timeIntervalSinceNow - 3_600) < 5)
    }

    @Test func stopClearsState() {
        let awake = AwakeController(defaults: store.defaults)
        awake.start(.minutes30)
        awake.stop()
        #expect(!awake.isActive)
        #expect(awake.endsAt == nil)
    }

    @Test func toggleReusesLastDuration() {
        let awake = AwakeController(defaults: store.defaults)
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
        let awake = AwakeController(defaults: store.defaults)
        defer { awake.stop() }

        awake.start(.hour1)
        let before = try #require(awake.endsAt)
        awake.keepsDisplayOn = true
        #expect(awake.isActive)
        #expect(awake.endsAt == before)
    }

    @Test func displaySettingPersists() {
        let awake = AwakeController(defaults: store.defaults)
        awake.keepsDisplayOn = true
        #expect(AwakeController(defaults: store.defaults).keepsDisplayOn)
    }
}

struct AwakeDisplayConnectedTests {
    private let store = TestDefaults()

    @Test func holdsOnlyWhileExternalDisplayConnected() {
        var connected = false
        let awake = AwakeController(defaults: store.defaults, hasExternalDisplay: { connected }, isLaptop: true)
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
        let awake = AwakeController(defaults: store.defaults, hasExternalDisplay: { connected }, isLaptop: true)
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
        let awake = AwakeController(defaults: store.defaults, hasExternalDisplay: { true }, isLaptop: true)
        defer { awake.stopWatchingDisplays() }
        awake.startWatchingDisplays()
        #expect(!awake.isHeldByDisplay)

        awake.whileDisplayConnected = true
        #expect(awake.isHeldByDisplay)
        awake.whileDisplayConnected = false
        #expect(!awake.isHeldByDisplay)
    }

    @Test func noHoldWhileNotWatching() {
        let awake = AwakeController(defaults: store.defaults, hasExternalDisplay: { true }, isLaptop: true)
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
            defaults: store.defaults, hasExternalDisplay: { connected }, isLaptop: true, unplugGrace: 0.05)
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
            defaults: store.defaults, hasExternalDisplay: { connected }, isLaptop: true, unplugGrace: 0.05)
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
        let awake = AwakeController(defaults: store.defaults, hasExternalDisplay: { true }, isLaptop: true)
        defer { awake.stopWatchingDisplays() }
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()
        awake.start(.indefinitely)

        awake.toggle()
        #expect(!awake.isActive)
        #expect(!awake.isHeldByDisplay)
    }

    @Test func holdSurvivesManualStopAndDisplaySetting() {
        let awake = AwakeController(defaults: store.defaults, hasExternalDisplay: { true }, isLaptop: true)
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
        let awake = AwakeController(defaults: store.defaults, hasExternalDisplay: { true }, isLaptop: false)
        defer { awake.stopWatchingDisplays() }
        awake.whileDisplayConnected = true
        awake.startWatchingDisplays()
        #expect(!awake.isHeldByDisplay)
    }

    @Test func settingPersists() {
        let awake = AwakeController(defaults: store.defaults, hasExternalDisplay: { false })
        awake.whileDisplayConnected = true
        #expect(AwakeController(defaults: store.defaults, hasExternalDisplay: { false }).whileDisplayConnected)
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
        let awake = AwakeController(defaults: store.defaults)
        defer { awake.stop() }

        let target = Date.now.addingTimeInterval(2 * 60 * 60)
        awake.start(untilTimeOfDay: target)
        let endsAt = try #require(awake.endsAt)
        #expect(awake.isActive)
        #expect(abs(endsAt.timeIntervalSince(target)) < 60)
    }
}
