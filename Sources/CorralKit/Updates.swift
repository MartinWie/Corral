import Foundation

/// App updates. The app target backs this with Sparkle; a build without a feed has none and shows
/// no update UI.
public protocol AppUpdater: AnyObject {
    /// Daily background checks.
    var automaticallyChecks: Bool { get set }
    var lastCheck: Date? { get }
    /// Shows Sparkle's window: up to date, or the update with Install.
    func checkForUpdates()
}

enum UpdateText {
    /// "0.1.0 (12)" from an Info.plist.
    static func version(_ info: [String: Any]) -> String {
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info["CFBundleVersion"] as? String else { return short }
        return "\(short) (\(build))"
    }

    static func caption(lastCheck: Date?, now: Date = Date()) -> String {
        "Once a day, from GitHub. Last checked: "
            + (lastCheck.map { SearchHitCell.ago($0, now: now) } ?? "never") + "."
    }
}
