import Foundation
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
