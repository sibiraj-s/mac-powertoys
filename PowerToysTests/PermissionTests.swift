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
        for permission in [Permission.automation, .fullDiskAccess, .microphone, .admin] {
            #expect(service.status(permission) == .unknown)
        }
    }

    @Test func checkablePermissionsReportAConcreteStatus() {
        let service = PermissionsService()
        for permission in [Permission.accessibility, .screenRecording, .inputMonitoring] {
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
            prompt: { recorder.prompts.append($0) }, openURL: { recorder.opened.append($0) }
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

    @Test func promptingForOneDoesNotCountForAnother() {
        let recorder = Recorder()
        let service = makeService(recorder)
        service.request(.screenRecording)
        service.request(.accessibility)
        #expect(recorder.prompts == [.screenRecording, .accessibility])
        #expect(recorder.opened.isEmpty)
    }

    @Test(arguments: [Permission.automation, .fullDiskAccess, .microphone])
    func withoutAPromptOpensSettingsStraightAway(permission: Permission) {
        let recorder = Recorder()
        makeService(recorder).request(permission)
        #expect(recorder.prompts.isEmpty)
        #expect(recorder.opened == [permission.settingsURL])
    }
}
