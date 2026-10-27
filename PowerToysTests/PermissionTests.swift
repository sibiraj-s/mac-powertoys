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
