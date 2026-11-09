import AppKit
import CorralKit
import Sparkle

/// Sparkle 2 behind `AppUpdater`. Feed URL and EdDSA public key come from Info.plist (bundle.sh);
/// a build without them gets no updater. Updates are EdDSA-signed zips on GitHub Releases.
final class SparkleUpdater: AppUpdater {
    private let controller: SPUStandardUpdaterController

    static func make(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> SparkleUpdater? {
        let feed = info["SUFeedURL"] as? String ?? "", key = info["SUPublicEDKey"] as? String ?? ""
        return feed.isEmpty || key.isEmpty ? nil : SparkleUpdater()
    }

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }
}
