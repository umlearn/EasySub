import Foundation

@MainActor
enum SubtitleSourceSettings {
    static func service() throws -> MultiSourceSubtitleService {
        let defaults = UserDefaults.standard
        var providers: [any SubtitleProvider] = []
        if defaults.object(forKey: "sourceXunlei") as? Bool ?? true { providers.append(XunleiProvider()) }
        let token = (defaults.string(forKey: "assrtToken") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if (defaults.object(forKey: "sourceAssrt") as? Bool ?? true), !token.isEmpty {
            providers.append(try AssrtProvider(token: token))
        }
        if defaults.object(forKey: "sourceShooter") as? Bool ?? false { providers.append(ShooterProvider()) }
        let openSubtitlesKey = (defaults.string(forKey: "openSubtitlesAPIKey") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if defaults.bool(forKey: "sourceOpenSubtitles"), !openSubtitlesKey.isEmpty {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
            providers.append(try OpenSubtitlesProvider(apiKey: openSubtitlesKey, userAgent: "EasySub v\(version)"))
        }
        let languages = SubtitleLanguageCatalog.normalizedPreferences([
            defaults.string(forKey: "subtitleLanguagePrimary") ?? SubtitleLanguageCatalog.defaultCodes[0],
            defaults.string(forKey: "subtitleLanguageSecondary") ?? SubtitleLanguageCatalog.defaultCodes[1],
            defaults.string(forKey: "subtitleLanguageTertiary") ?? SubtitleLanguageCatalog.defaultCodes[2]
        ])
        return try MultiSourceSubtitleService(providers: providers, preferredLanguageCodes: languages)
    }
}
