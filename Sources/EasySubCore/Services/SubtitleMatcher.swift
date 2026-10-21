import Foundation

/// Deterministic filename heuristics, not a guarantee of synchronized dialogue.
enum SubtitleMatcher {
    static func rank(_ candidates: [SubtitleCandidate], for video: URL,
                     preferredLanguageCodes: [String] = [], requirePreferredLanguage: Bool = false) -> [SubtitleCandidate] {
        rank(candidates, forName: video.deletingPathExtension().lastPathComponent,
             preferredLanguageCodes: preferredLanguageCodes, requirePreferredLanguage: requirePreferredLanguage)
    }

    static func rank(_ candidates: [SubtitleCandidate], forName name: String,
                     preferredLanguageCodes: [String] = [], requirePreferredLanguage: Bool = false) -> [SubtitleCandidate] {
        let target = Metadata(name)
        let preferences = SubtitleLanguageCatalog.normalizedPreferences(preferredLanguageCodes)
        return candidates.enumerated().compactMap { index, candidate -> (Int, Int, Int, SubtitleCandidate)? in
            let languageIndex = preferences.firstIndex(where: { candidate.languageCodes.contains($0) })
            if requirePreferredLanguage && !preferences.isEmpty && languageIndex == nil { return nil }
            // Known nonzero offsets need retiming, which this app does not perform.
            guard candidate.delayMilliseconds == nil || candidate.delayMilliseconds == 0 else { return nil }
            let metadata = Metadata(candidate.matchingText)
            let fingerprint = candidate.matchKind == .fingerprint
            if !fingerprint {
                if let year = target.year, let other = metadata.year, year != other { return nil }
                if !target.episodes.isEmpty {
                    // Do not auto-pick an unnamed episode from a season pack.
                    guard target.episodes == metadata.episodes else { return nil }
                    if let season = target.season, let other = metadata.season, season != other { return nil }
                } else if !metadata.episodes.isEmpty { return nil }
                let sharesTitle = !target.words.isDisjoint(with: metadata.words)
                let exactYear = target.year != nil && target.year == metadata.year
                let exactEpisode = !target.episodes.isEmpty && target.episodes == metadata.episodes
                // Translated titles may share no words. An exact year or episode remains useful evidence;
                // otherwise leave unrelated filename results for explicit manual selection.
                if candidate.delayMilliseconds == nil && !sharesTitle && !exactYear && !exactEpisode {
                    return nil
                }
            }
            var score = fingerprint ? 1000 : 0
            let sharedWords = target.words.intersection(metadata.words)
            score += sharedWords.count * 20
            if !target.words.isEmpty && target.words.isSubset(of: metadata.words) { score += 20 }
            if target.year != nil && target.year == metadata.year { score += 30 }
            if !target.episodes.isEmpty && target.episodes == metadata.episodes { score += 100 }
            if target.season != nil && target.season == metadata.season { score += 30 }
            score += versionScore(target: target, candidate: metadata)
            if preferences.isEmpty {
                if candidate.languageCodes.contains("zh-cn") { score += 25 }
                else if candidate.languageCodes.contains("ze") { score += 20 }
                else if candidate.languageCodes.contains("zh-tw") { score += 12 }
            }
            if candidate.delayMilliseconds == 0 { score += 10 }
            if let providerScore = candidate.providerScore {
                score += min(20, max(-20, providerScore))
            }
            return (languageIndex ?? Int.max, score, index, candidate)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            return $0.2 < $1.2
        }.map { $0.3 }
    }

    private struct Metadata {
        let year: String?
        let season: String?
        let episodes: Set<Int>
        let words: Set<String>
        let resolution: String?
        let source: String?
        let codec: String?
        let releaseGroup: String?
        init(_ name: String) {
            let text = name.lowercased()
            func matches(_ pattern: String) -> [[String]] {
                let regex = try! NSRegularExpression(pattern: pattern)
                return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
                    (0..<match.numberOfRanges).map { i in
                        Range(match.range(at: i), in: text).map { String(text[$0]) } ?? ""
                    }
                }
            }
            year = matches(#"\b(?:19|20)\d{2}\b"#).first?.first
            let seasons = matches(#"\bs(\d{1,2})(?=[ ._-]*e\d|\b)"#)
            let cross = matches(#"\b(\d{1,2})x(\d{1,3})\b"#)
            season = (seasons.first?[1] ?? cross.first?[1]).flatMap(Int.init).map(String.init)
            let episodeMatches = matches(#"(?:\bs\d{1,2}[ ._-]*|\b|(?<=\d))e(\d{1,3})(?:[- ]e?(\d{1,3}))?\b"#)
            var numbers = Set(cross.compactMap { Int($0[2]) })
            for match in episodeMatches {
                if let first = Int(match[1]) {
                    numbers.insert(first)
                    if let last = Int(match[2]), last >= first, last - first < 100 {
                        numbers.formUnion(first...last)
                    }
                }
            }
            episodes = numbers
            resolution = matches(#"\b(2160p|1080p|720p|576p|480p)\b"#).first?[1]
            let sourceText = matches(#"\b(uhd[ ._-]?blu[ ._-]?ray|blu[ ._-]?ray|bdrip|web[ ._-]?dl|webrip|hdtv|dvdrip)\b"#).first?[1]
            if let sourceText {
                if sourceText.contains("blu") || sourceText == "bdrip" { source = "bluray" }
                else if sourceText.contains("web") && sourceText.contains("dl") { source = "webdl" }
                else { source = sourceText }
            } else { source = nil }
            let codecText = matches(#"\b(x265|h[ ._-]?265|hevc|x264|h[ ._-]?264|avc|av1)\b"#).first?[1]
            if let codecText {
                if codecText.contains("265") || codecText == "hevc" { codec = "h265" }
                else if codecText.contains("264") || codecText == "avc" { codec = "h264" }
                else { codec = codecText }
            } else { codec = nil }
            releaseGroup = matches(#"-([a-z0-9]+)(?:[ ._-]*(?:srt|ass))?$"#).last?[1]
            // The title usually precedes year, episode and release tags. Compare title words, not codecs.
            let boundary = try! NSRegularExpression(pattern: #"\b(?:(?:19|20)\d{2}|s\d{1,2}e\d+|\d{1,2}x\d+|e\d+|\d{3,4}p|bluray|blu-ray|web[ ._-]?dl|webrip|hdtv|x26[45]|h26[45])\b"#)
            let end = boundary.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).flatMap { Range($0.range, in: text)?.lowerBound } ?? text.endIndex
            let ignored: Set<String> = ["the", "a", "an", "ass", "srt", "ssa", "mkv", "mp4", "chs", "cht", "zh", "en", "eng"]
            words = Set(text[..<end].components(separatedBy: CharacterSet.alphanumerics.inverted).filter {
                !$0.isEmpty && !$0.allSatisfy(\.isNumber) && !ignored.contains($0)
            })
        }
    }

    private static func versionScore(target: Metadata, candidate: Metadata) -> Int {
        var score = 0
        if let value = target.resolution, let other = candidate.resolution, value == other { score += 6 }
        if let value = target.source, let other = candidate.source, value == other { score += 8 }
        if let value = target.codec, let other = candidate.codec, value == other { score += 4 }
        if let value = target.releaseGroup, let other = candidate.releaseGroup, value == other { score += 10 }
        return score
    }
}
