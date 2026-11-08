import Foundation
import Testing

@testable import PowerToys

struct PermissionTests {
    @Test(arguments: Permission.allCases)
    func settingsLinkPointsAtPrivacyPane(permission: Permission) throws {
        // Admin rights are asked for per change, so there's no pane to open.
        guard permission != .admin else {
            #expect(permission.settingsURL == nil)
            return
        }
        let url = try #require(permission.settingsURL)
        #expect(url.scheme == "x-apple.systempreferences")
        #expect(url.query?.hasPrefix("Privacy_") == true)
    }

    @Test(arguments: Permission.allCases)
    func hasUserFacingCopy(permission: Permission) {
        #expect(!permission.title.isEmpty)
        #expect(!permission.explanation.isEmpty)
        #expect(!permission.symbol.isEmpty)
    }

    @Test func permissionsWithoutPreflightReportUnknown() {
        let service = PermissionsService()
        for permission in [Permission.automation, .admin] {
            #expect(service.status(permission) == .unknown)
        }
    }

    @Test func checkablePermissionsReportAConcreteStatus() {
        let service = PermissionsService()
        for permission in [Permission.accessibility, .screenRecording, .inputMonitoring, .fullDiskAccess] {
            #expect(service.status(permission) != .unknown)
        }
    }
}

@MainActor
struct PermissionRequestTests {
    let store = TestDefaults()

    final class Recorder {
        var prompts: [Permission] = []
        var opened: [URL] = []
    }

    func makeService(_ recorder: Recorder) -> PermissionsService {
        PermissionsService(
            defaults: store.defaults, check: { _ in .denied },
            prompt: { permission, _ in recorder.prompts.append(permission) }, openURL: { recorder.opened.append($0) }
        )
    }

    @Test(arguments: [Permission.accessibility, .screenRecording, .inputMonitoring])
    func promptsOnceThenOpensSettings(permission: Permission) {
        let recorder = Recorder()
        makeService(recorder).request(permission)
        #expect(recorder.prompts == [permission])
        #expect(recorder.opened.isEmpty)

        // macOS shows its prompt once per app, so asking again, even after relaunching, opens the pane.
        makeService(recorder).request(permission)
        #expect(recorder.prompts == [permission])
        #expect(recorder.opened == [permission.settingsURL])
    }

    @Test func saysWhenThePromptIsAnswered() {
        var answer: (@MainActor @Sendable () -> Void)?
        var checks = 0
        let service = PermissionsService(
            defaults: store.defaults,
            check: { _ in
                checks += 1
                return .denied
            },
            prompt: { _, answered in answer = answered }, openURL: { _ in })
        var answered = false
        service.request(.audioCapture) { answered = true }
        #expect(!answered)
        let before = checks
        answer?()
        #expect(answered)
        #expect(checks > before)  // read again once answered

        // Asked before, so settings open instead, and it says so at once.
        answered = false
        service.request(.audioCapture) { answered = true }
        #expect(answered)
    }

    @Test func promptingForOneDoesNotCountForAnother() {
        let recorder = Recorder()
        let service = makeService(recorder)
        service.request(.screenRecording)
        service.request(.accessibility)
        #expect(recorder.prompts == [.screenRecording, .accessibility])
        #expect(recorder.opened.isEmpty)
    }

    @Test(arguments: [Permission.automation, .fullDiskAccess])
    func withoutAPromptOpensSettingsStraightAway(permission: Permission) {
        let recorder = Recorder()
        makeService(recorder).request(permission)
        #expect(recorder.prompts.isEmpty)
        #expect(recorder.opened == [permission.settingsURL])
    }

    @Test func screenAccessChecksAndAsksThroughTheService() {
        let recorder = Recorder()
        // Only the first try: later ones explain with an alert.
        #expect(!ScreenAccess(for: .pinCrop, permissions: makeService(recorder)).check())
        #expect(recorder.prompts == [.screenRecording])

        let granted = PermissionsService(defaults: store.defaults, check: { _ in .granted }, prompt: { _, _ in }, openURL: { _ in })
        #expect(ScreenAccess(for: .pinCrop, permissions: granted).check())
    }
}
