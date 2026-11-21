import Foundation

/// Stet's settings moved with its identifier (`local.stet.Stet` → `io.github.booneynoobington.stet`).
/// On the first start under the new one, everything the old one stored comes along once:
/// signing and timestamp setup, this Mac's device ID (names its snapshots), editor settings,
/// recent books, window positions. The old settings stay where they were.
enum SettingsMigration {
    static let previousDomains = ["local.stet.Stet"]
    private static let marker = "StetSettingsMigrated"

    static func run(into defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: marker) == nil else { return }
        for domain in previousDomains {
            guard domain != Bundle.main.bundleIdentifier, let old = defaults.persistentDomain(forName: domain) else { continue }
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: marker)
    }
}
