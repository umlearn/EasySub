import Foundation

/// Uses the app's language preference so SwiftUI, Foundation and AppKit agree
/// on the next launch. Never changes the global system language preferences.
public enum ApplicationLanguage: String, CaseIterable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public static func current(
        in defaults: UserDefaults = .standard,
        domainName: String = Bundle.main.bundleIdentifier ?? ""
    ) -> Self {
        // Ignore the inherited global preference: only an app override counts.
        guard let domain = defaults.persistentDomain(forName: domainName),
              let languages = domain["AppleLanguages"] as? [String],
              let identifier = languages.first else { return .system }
        return Self(rawValue: identifier) ?? .system
    }

    public func save(in defaults: UserDefaults = .standard) {
        if self == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([rawValue], forKey: "AppleLanguages")
        }
    }
}
