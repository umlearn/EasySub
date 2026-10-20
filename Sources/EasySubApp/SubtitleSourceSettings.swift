import Foundation

@MainActor
enum SubtitleSourceSettings {
    static func service() throws -> MultiSourceSubtitleService {
        let defaults = UserDefaults.standard
        var providers: [any SubtitleProvider] = []
        if defaults.object(forKey: "sourceShooter") as? Bool ?? false { providers.append(ShooterProvider()) }
        if defaults.object(forKey: "sourceXunlei") as? Bool ?? true { providers.append(XunleiProvider()) }
        if defaults.bool(forKey: "sourceAssrt") {
            let token = (defaults.string(forKey: "assrtToken") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            providers.append(try AssrtProvider(token: token))
        }
        return try MultiSourceSubtitleService(providers: providers)
    }
}
