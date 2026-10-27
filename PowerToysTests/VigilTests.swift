import Testing
@testable import PowerToys

struct VigilTests {
    @Test func pointsAtVigilsRelease() {
        #expect(Vigil.bundleID == "dev.sibiraj.vigil")
        #expect(Vigil.releasesURL.absoluteString == "https://github.com/sibiraj-s/vigil/releases/latest")
    }
}
