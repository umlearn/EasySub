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
        case "zh": return "中文"
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
            return code == "zh" || code == "zh-cn" || code == "zh-tw" || code == "ze"
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
        if code.lowercased() == "zh" { return 3 }
        return all.firstIndex(where: { $0.code == code.lowercased() }).map {
            $0 >= 3 ? $0 + 1 : $0
        } ?? Int.max
    }

    /// Exact provider/file metadata wins. Generic Chinese remains eligible for either Chinese
    /// script preference, but callers can keep it behind every exact language group.
    static func preferenceMatch(for codes: Set<String>, in preferences: [String])
        -> (index: Int, exact: Bool)? {
        for (index, preference) in preferences.enumerated() where codes.contains(preference) {
            return (index, true)
        }
        guard codes.contains("zh") else { return nil }
        for (index, preference) in preferences.enumerated()
            where preference == "zh-cn" || preference == "zh-tw" {
            return (index, false)
        }
        return nil
    }

    /// ASSRT and Xunlei primarily serve Chinese-speaking users, so an item with no language
    /// evidence can remain a last-resort Chinese candidate. Explicit language metadata always
    /// wins: an item identified as English, Japanese, and so on never receives this prior.
    static func preferenceMatch(for candidate: SubtitleCandidate, in preferences: [String])
        -> (index: Int, confidence: Int)? {
        if let match = preferenceMatch(for: candidate.languageCodes, in: preferences) {
            return (match.index, match.exact ? 0 : 1)
        }
        guard candidate.languageCodes.isEmpty,
              candidate.source.id == "assrt" || candidate.source.id == "xunlei",
              let index = preferences.firstIndex(where: { $0 == "zh-cn" || $0 == "zh-tw" })
        else { return nil }
        return (index, 2)
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
        if ["chi", "zho", "zh", "中文", "中字"].contains(text) {
            result.insert("zh")
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
        let basename = (filename as NSString).deletingPathExtension
        // Preserve case just long enough to split compact release suffixes such as
        // WEB-DLChs, ChsEng, and MovieZhCN before normalizing the text.
        let compatible = basename.precomposedStringWithCompatibilityMapping
        let acronymSeparated = compatible.replacingOccurrences(
            of: #"(?<=[A-Z])(?=[A-Z][a-z])"#, with: " ", options: .regularExpression
        )
        let camelSeparated = acronymSeparated.replacingOccurrences(
            of: #"(?<=[a-z0-9])(?=[A-Z])"#, with: " ", options: .regularExpression
        )
        let text = camelSeparated
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let tokens = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var result = Set<String>()

        func containsDelimited(_ value: String) -> Bool {
            let escaped = NSRegularExpression.escapedPattern(for: value.lowercased())
            return text.range(of: "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])",
                              options: .regularExpression) != nil
        }
        func containsToken(_ values: [String]) -> Bool {
            values.contains { tokens.contains($0) || containsDelimited($0) }
        }

        let simplifiedChinese = ["简体中文", "簡體中文", "简体", "簡體", "简中", "簡中", "简英", "簡英", "英简", "英簡"]
        let traditionalChinese = ["繁体中文", "繁體中文", "繁体", "繁體", "繁中", "繁英", "英繁"]
        let genericChinese = ["中文字幕", "中字", "中英", "英中"]
        let compactSimplified = ["chseng", "engchs", "chsen", "enchs", "zhcn", "zhhans"]
        let compactTraditional = ["chteng", "engcht", "chten", "encht", "zhtw", "zhhk", "zhhant"]
        let tokenPairs = zip(tokens, tokens.dropFirst()).map { ($0, $1) }
        let hasSimplifiedPair = tokenPairs.contains { $0.0 == "zh" && ["cn", "hans"].contains($0.1) }
        let hasTraditionalPair = tokenPairs.contains { $0.0 == "zh" && ["tw", "hk", "hant"].contains($0.1) }
        if simplifiedChinese.contains(where: text.contains)
            || containsToken(["chs", "sc", "gb", "gbk", "zh-cn", "zh-hans"] + compactSimplified)
            || hasSimplifiedPair {
            result.insert("zh-cn")
        }
        if traditionalChinese.contains(where: text.contains)
            || containsToken(["cht", "tc", "big5", "zh-tw", "zh-hk", "zh-hant"] + compactTraditional)
            || hasTraditionalPair {
            result.insert("zh-tw")
        }
        if containsToken(["zh"]), !result.contains("zh-cn"), !result.contains("zh-tw") {
            result.insert("zh")
        }
        if genericChinese.contains(where: text.contains),
           !result.contains("zh-cn"), !result.contains("zh-tw") {
            result.insert("zh")
        }

        let aliases: [(String, [String])] = [
            ("en", ["eng", "english"]), ("ja", ["jpn", "japanese"]),
            ("ko", ["kor", "korean"]), ("fr", ["fre", "fra", "french"]),
            ("de", ["ger", "deu", "german"]), ("es", ["spa", "spanish"]),
            ("it", ["ita", "italian"]), ("pt-pt", ["por", "portuguese"]),
            ("pt-br", ["pob", "brazilian"]), ("ru", ["rus", "russian"]),
            ("ar", ["ara", "arabic"]), ("bg", ["bul", "bulgarian"]),
            ("cs", ["cze", "ces", "czech"]), ("da", ["dan", "danish"]),
            ("nl", ["dut", "nld", "dutch"]), ("fi", ["fin", "finnish"]),
            ("el", ["gre", "ell", "greek"]), ("he", ["heb", "hebrew"]),
            ("hi", ["hin", "hindi"]), ("hu", ["hun", "hungarian"]),
            ("id", ["ind", "indonesian"]), ("no", ["nor", "norwegian"]),
            ("fa", ["per", "fas", "persian"]), ("pl", ["pol", "polish"]),
            ("ro", ["rum", "ron", "romanian"]), ("sr", ["srp", "serbian"]),
            ("sk", ["slo", "slk", "slovak"]), ("sl", ["slv", "slovenian"]),
            ("sv", ["swe", "swedish"]), ("th", ["tha", "thai"]),
            ("tr", ["tur", "turkish"]), ("uk", ["ukr", "ukrainian"]),
            ("vi", ["vie", "vietnamese"]), ("af", ["afr", "afrikaans"]),
            ("sq", ["alb", "sqi", "albanian"]), ("hy", ["arm", "hye", "armenian"]),
            ("eu", ["baq", "eus", "basque"]), ("be", ["bel", "belarusian"]),
            ("bn", ["ben", "bengali"]), ("bs", ["bos", "bosnian"]),
            ("ca", ["cat", "catalan"]), ("hr", ["hrv", "croatian"]),
            ("et", ["est", "estonian"]), ("ka", ["geo", "kat", "georgian"]),
            ("is", ["ice", "isl", "icelandic"]), ("kk", ["kaz", "kazakh"]),
            ("km", ["khm", "khmer"]), ("lv", ["lav", "latvian"]),
            ("lt", ["lit", "lithuanian"]), ("mk", ["mac", "mkd", "macedonian"]),
            ("ms", ["may", "msa", "malay"]), ("mn", ["mon", "mongolian"]),
            ("sw", ["swa", "swahili"]), ("ta", ["tam", "tamil"]),
            ("te", ["tel", "telugu"]), ("ur", ["urd", "urdu"])
        ]
        for (code, markers) in aliases where containsToken(markers) { result.insert(code) }
        if containsToken(compactSimplified + compactTraditional) { result.insert("en") }

        let localizedMarkers: [(String, [String])] = [
            ("en", ["英语", "英語", "英文", "中英", "英中", "简英", "簡英", "英简", "英簡", "繁英", "英繁"]),
            ("ja", ["日语", "日語", "日文"]), ("ko", ["韩语", "韓語", "韩文", "韓文"]),
            ("fr", ["法语", "法語", "法文"]), ("de", ["德语", "德語", "德文"]),
            ("es", ["西班牙语", "西班牙語", "西语", "西語"]),
            ("it", ["意大利语", "意大利語"]), ("ru", ["俄语", "俄語", "俄文"]),
            ("pt-pt", ["葡萄牙语", "葡萄牙語"]), ("ar", ["阿拉伯语", "阿拉伯語"])
        ]
        for (code, markers) in localizedMarkers where markers.contains(where: text.contains) {
            result.insert(code)
        }

        let qualifiers = Set(["sdh", "hi", "cc", "forced", "force", "signs", "commentary", "lyrics", "default"])
        let finalMetadataToken = tokens.reversed().drop(while: qualifiers.contains).first
        // Some release names omit a separator before an all-uppercase language suffix
        // (for example WEB-DLCHS). Limit suffix splitting to known release terms so words
        // that merely end in a language-like sequence do not become false positives.
        if let finalMetadataToken {
            let releasePrefixes = ["dl", "webdl", "webrip", "bluray", "brrip", "hdtv", "hdrip", "dvdrip", "remux"]
            let suffixes: [(String, Set<String>)] = [
                ("chseng", ["zh-cn", "en"]), ("engchs", ["zh-cn", "en"]),
                ("chteng", ["zh-tw", "en"]), ("engcht", ["zh-tw", "en"]),
                ("chs", ["zh-cn"]), ("cht", ["zh-tw"]), ("eng", ["en"])
            ]
            for (suffix, codes) in suffixes where finalMetadataToken.hasSuffix(suffix) {
                let prefix = String(finalMetadataToken.dropLast(suffix.count))
                if releasePrefixes.contains(prefix) { result.formUnion(codes) }
            }
        }
        let shortCodes: [String: String] = [
            "en": "en", "ja": "ja", "ko": "ko", "fr": "fr", "de": "de", "es": "es",
            "it": "it", "pt": "pt-pt", "ru": "ru", "ar": "ar", "bg": "bg", "cs": "cs",
            "da": "da", "nl": "nl", "fi": "fi", "el": "el", "he": "he", "hu": "hu",
            "id": "id", "no": "no", "fa": "fa", "pl": "pl", "ro": "ro", "sr": "sr",
            "sk": "sk", "sl": "sl", "sv": "sv", "th": "th", "tr": "tr", "uk": "uk",
            "vi": "vi", "af": "af", "sq": "sq", "hy": "hy", "eu": "eu", "be": "be",
            "bn": "bn", "bs": "bs", "ca": "ca", "hr": "hr", "et": "et", "ka": "ka",
            "is": "is", "kk": "kk", "km": "km", "lv": "lv", "lt": "lt", "mk": "mk",
            "ms": "ms", "mn": "mn", "sw": "sw", "ta": "ta", "te": "te", "ur": "ur"
        ]
        if let finalMetadataToken, let code = shortCodes[finalMetadataToken] { result.insert(code) }

        switch finalMetadataToken {
        case "hk", "tw": result.insert("zh-tw")
        case "cn": result.insert("zh-cn")
        case "jp": result.insert("ja")
        case "kr": result.insert("ko")
        default: break
        }

        let explicitBilingual = ["双语", "雙語"].contains(where: text.contains)
            || containsToken(["bilingual"])
        if explicitBilingual || ((result.contains("zh") || result.contains("zh-cn") || result.contains("zh-tw"))
            && result.contains("en")) {
            result.insert("ze")
        }
        return result
    }
}
