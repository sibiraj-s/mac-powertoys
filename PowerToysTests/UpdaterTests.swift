import Foundation
import Testing

@testable import PowerToys

struct UpdaterTests {
    /// Installed copies look for new versions here; publish.sh attaches it to each release.
    @Test func feedIsTheLatestReleasesAppcast() {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
        #expect(feed == "https://github.com/sibiraj-s/mac-powertoys/releases/latest/download/appcast.xml")
        #expect(Updater.releasesPage.absoluteString.hasPrefix("https://github.com/sibiraj-s/mac-powertoys/"))
    }

    /// Development builds have no key and aren't versioned, so they never offer to update.
    @Test func developmentBuildsDontUpdateThemselves() {
        #expect(!Updater.shared.isEnabled)
        #expect(Updater.shared.canCheckNow)
    }
}
