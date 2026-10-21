import Foundation

public struct SubtitleLanguage: Identifiable, Hashable, Sendable {
    public var id: String { code }
    public let code: String
    public let name: String

    public init(code: String, name: String) {
        self.code = code.lowercased()
        self.name = name
    }

    public func displayName(in locale: Locale) -> String {
        SubtitleLanguageCatalog.displayName(for: code, in: locale)
    }
}

public enum SubtitleLanguageCatalog {
    public static let defaultCodes = ["zh-cn", "ze", "zh-tw"]

    /// A bundled snapshot of the public OpenSubtitles language table. Keeping this local makes
    /// language settings usable before a source or API key is configured.
    public static let all: [SubtitleLanguage] = [
        .init(code: "zh-cn", name: "Chinese (Simplified)"),
        .init(code: "ze", name: "Chinese (Bilingual)"),
        .init(code: "zh-tw", name: "Chinese (Traditional)"),
        .init(code: "en", name: "English"), .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"), .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"), .init(code: "es", name: "Spanish"),
        .init(code: "it", name: "Italian"), .init(code: "pt-br", name: "Portuguese (Brazilian)"),
        .init(code: "pt-pt", name: "Portuguese"), .init(code: "ru", name: "Russian"),
        .init(code: "ar", name: "Arabic"), .init(code: "bg", name: "Bulgarian"),
        .init(code: "cs", name: "Czech"), .init(code: "da", name: "Danish"),
        .init(code: "nl", name: "Dutch"), .init(code: "fi", name: "Finnish"),
        .init(code: "el", name: "Greek"), .init(code: "he", name: "Hebrew"),
        .init(code: "hi", name: "Hindi"), .init(code: "hu", name: "Hungarian"),
        .init(code: "id", name: "Indonesian"), .init(code: "no", name: "Norwegian"),
        .init(code: "fa", name: "Persian"), .init(code: "pl", name: "Polish"),
        .init(code: "ro", name: "Romanian"), .init(code: "sr", name: "Serbian"),
        .init(code: "sk", name: "Slovak"), .init(code: "sl", name: "Slovenian"),
        .init(code: "sv", name: "Swedish"), .init(code: "th", name: "Thai"),
        .init(code: "tr", name: "Turkish"), .init(code: "uk", name: "Ukrainian"),
        .init(code: "vi", name: "Vietnamese"), .init(code: "af", name: "Afrikaans"),
        .init(code: "sq", name: "Albanian"), .init(code: "hy", name: "Armenian"),
        .init(code: "eu", name: "Basque"), .init(code: "be", name: "Belarusian"),
        .init(code: "bn", name: "Bengali"), .init(code: "bs", name: "Bosnian"),
        .init(code: "ca", name: "Catalan"), .init(code: "hr", name: "Croatian"),
        .init(code: "et", name: "Estonian"), .init(code: "ka", name: "Georgian"),
        .init(code: "is", name: "Icelandic"), .init(code: "kk", name: "Kazakh"),
        .init(code: "km", name: "Khmer"), .init(code: "lv", name: "Latvian"),
        .init(code: "lt", name: "Lithuanian"), .init(code: "mk", name: "Macedonian"),
        .init(code: "ms", name: "Malay"), .init(code: "mn", name: "Mongolian"),
        .init(code: "sw", name: "Swahili"), .init(code: "ta", name: "Tamil"),
        .init(code: "te", name: "Telugu"), .init(code: "ur", name: "Urdu")
    ]

    private static let localeIdentifiers: [String: String] = [
        "zh-cn": "zh-Hans", "zh-tw": "zh-Hant",
        "pt-br": "pt-BR", "pt-pt": "pt-PT"
    ]

    /// Chinese subtitle labels stay in Chinese in both app languages. Other language
    /// names follow the locale of the interface currently on screen.
    public static func displayName(for code: String, in locale: Locale = .current) -> String {
        let code = code.lowercased()
        switch code {
        case "zh-cn": return "简体中文"
        case "zh-tw": return "繁体中文"
        case "ze": return "双语字幕"
        default:
            let identifier = localeIdentifiers[code] ?? code
            if let localized = locale.localizedString(forIdentifier: identifier), !localized.isEmpty {
                return localized.capitalized(with: locale)
            }
            return all.first(where: { $0.code == code })?.name ?? code
        }
    }

    public static func displayLabel(for codes: Set<String>, in locale: Locale = .current) -> String {
        let isChineseSubtitle = codes.contains(where: { code in
            let code = code.lowercased()
            return code == "zh-cn" || code == "zh-tw" || code == "ze"
        })
        let labelLocale = isChineseSubtitle ? Locale(identifier: "zh-Hans") : locale
        let names = codes
            .filter { $0 != "ze" }
            .sorted { languageSortIndex($0) < languageSortIndex($1) }
            .map { displayName(for: $0, in: labelLocale) }
        var parts = names
        if codes.contains("ze") {
            parts.append("双语字幕")
        }
        return parts.joined(separator: " + ")
    }

    private static func languageSortIndex(_ code: String) -> Int {
        all.firstIndex(where: { $0.code == code.lowercased() }) ?? Int.max
    }

    public static func normalizedPreferences(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            guard let code = SubtitleLanguageNormalizer.codes(from: value).sorted().first,
                  seen.insert(code).inserted else { continue }
            result.append(code)
            if result.count == 3 { break }
        }
        return result
    }
}

public enum SubtitleLanguageNormalizer {
    public static func codes<S: Sequence>(from values: S) -> Set<String> where S.Element == String {
        values.reduce(into: Set<String>()) { $0.formUnion(codes(from: $1)) }
    }

    public static func codes(from value: String) -> Set<String> {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return [] }
        var result = Set<String>()
        if text.contains("双语") || text.contains("bilingual") || text == "ze" {
            result.insert("ze")
        }
        if ["繁", "cht", "zh-tw", "zh-hk", "zh-hant", "traditional"]
            .contains(where: text.contains) {
            result.insert("zh-tw")
        }
        if ["简", "chs", "zh-cn", "zh-hans", "simplified"]
            .contains(where: text.contains) {
            result.insert("zh-cn")
        }
        if ["chi", "zho", "zh"].contains(text) {
            result.insert("zh-cn")
        }
        let shorthand = ["英": "en", "日": "ja", "韩": "ko", "法": "fr",
                         "德": "de", "俄": "ru", "西": "es"]
        for (marker, code) in shorthand where text.contains(marker) {
            result.insert(code)
        }
        if !result.isEmpty { return result }
        let aliases = ["eng": "en", "jpn": "ja", "kor": "ko", "fre": "fr", "fra": "fr",
                       "ger": "de", "deu": "de", "spa": "es", "ita": "it", "rus": "ru",
                       "por": "pt-pt", "pob": "pt-br", "英语": "en", "英文": "en",
                       "日语": "ja", "日文": "ja", "韩语": "ko", "韩文": "ko",
                       "法语": "fr", "德语": "de", "西班牙语": "es", "俄语": "ru"]
        if let alias = aliases[text] { return [alias] }
        if let language = SubtitleLanguageCatalog.all.first(where: { $0.name.lowercased() == text }) {
            return [language.code]
        }
        if text.range(of: #"^[a-z]{2}(?:-[a-z]{2})?$"#, options: .regularExpression) != nil { return [text] }
        return []
    }

    /// ASSRT provides one language description for a whole file list. Individual filenames
    /// are more precise, so prefer their explicit CHS/CHT and English markers.
    public static func codes(fromFileName filename: String) -> Set<String> {
        let text = filename.lowercased()
        var result = Set<String>()
        let hasSimplified = ["chs", "zh-cn", "zh-hans"].contains(where: text.contains)
        let hasTraditional = ["cht", "zh-tw", "zh-hk", "zh-hant"].contains(where: text.contains)
        let hasEnglish = ["eng", "english"].contains(where: text.contains)
        if hasSimplified { result.insert("zh-cn") }
        if hasTraditional { result.insert("zh-tw") }
        if hasEnglish { result.insert("en") }
        if (hasSimplified || hasTraditional) && hasEnglish {
            result.insert("ze")
        }
        return result
    }
}
