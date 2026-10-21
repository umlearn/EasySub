import Foundation

public actor AssrtProvider: SubtitleProvider {
    public nonisolated let source = SubtitleSource(id: "assrt", name: "ASSRT")
    private let token: String
    private let transport: any HTTPTransport
    private let limiter: AssrtRateLimiter
    private var issued: [String: (SubtitleCandidate, Int, String?)] = [:]
    private var archiveCache: [Int: Data] = [:]

    public init(token: String,
                transport: any HTTPTransport = URLSessionTransport(allowsInsecureASSRTFiles: true),
                limiter: AssrtRateLimiter = .shared) throws {
        guard token.count == 32, token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw SourceAPIError.invalidToken
        }
        self.token = token; self.transport = transport; self.limiter = limiter
    }
    public func search(_ request: SubtitleSearchRequest) async throws -> [SubtitleCandidate] {
        archiveCache.removeAll()
        let response = try await api("search", query: [
            URLQueryItem(name: "q", value: AssrtSearchQuery.make(filename: request.filename)),
            URLQueryItem(name: "is_file", value: "1"), URLQueryItem(name: "filelist", value: "1"),
            URLQueryItem(name: "cnt", value: "15")])
        var results: [SubtitleCandidate] = []
        func append(_ sub: Entry, filename: String?, format: SubtitleFormat, title: String) throws {
            // JSON encodes the composite reference without delimiter collisions.
            let reference = String(decoding: try JSONEncoder().encode(
                [String(sub.id), filename ?? "", format.rawValue]), as: UTF8.self)
            let matchingText = [sub.nativeName, sub.videoName, sub.filename, filename]
                .compactMap { $0 }.joined(separator: " / ")
            let fileLanguages = filename.map(SubtitleLanguageNormalizer.codes(fromFileName:)) ?? []
            let languages = fileLanguages.isEmpty
                ? SubtitleLanguageNormalizer.codes(from: sub.languageDescription.map { [$0] } ?? [])
                : fileLanguages
            let candidate = SubtitleCandidate(source: source, reference: reference, title: title,
                                              matchingText: matchingText, format: format,
                                              languageCodes: languages)
            issued[reference] = (candidate, sub.id, filename)
            results.append(candidate)
        }
        for sub in response.sub?.subs ?? [] {
            if !sub.filelist.isEmpty {
                for file in sub.filelist {
                    guard let format = SubtitleFormat(rawValue: (file.f as NSString).pathExtension.lowercased()) else { continue }
                    try append(sub, filename: file.f, format: format, title: file.f)
                }
            } else if let filename = sub.filename,
                      let format = SubtitleFormat(rawValue: (filename as NSString).pathExtension.lowercased()) {
                try append(sub, filename: filename, format: format, title: filename)
            } else if sub.filename != nil || sub.subtype != nil {
                // Search may omit file details for archive uploads. The detail response resolves
                // the filename and direct URL, then local extraction selects the requested format.
                let title = sub.nativeName ?? sub.filename ?? sub.videoName ?? "ASSRT \(sub.id)"
                for format in [SubtitleFormat.ass, .srt] {
                    try append(sub, filename: sub.filename, format: format, title: title)
                }
            }
        }
        return results
    }
    public func download(_ candidate: SubtitleCandidate) async throws -> Data {
        guard let (original, id, issuedFilename) = issued[candidate.reference], original == candidate else {
            throw SubtitleProviderError.invalidCandidate
        }
        // Detail URLs expire. Resolve just before downloading, never persist them.
        let response = try await api("detail", query: [URLQueryItem(name: "id", value: String(id))])
        guard let sub = response.sub?.subs.first(where: { $0.id == id }) else { throw SourceAPIError.missingFile }
        guard let selected = selectFile(in: sub, issuedFilename: issuedFilename, format: candidate.format),
              let address = selected.url, let url = URL(string: address) else {
            throw SourceAPIError.missingFile
        }
        try URLSessionTransport.validate(url, allowsInsecureASSRTFiles: true)
        // Never send the API token to file hosts.
        var request = URLRequest(url: url)
        if URLSessionTransport.isASSRTFileHost(url.host) {
            // ASSRT's file hosts reject otherwise valid signed links without these headers.
            request.setValue("https://assrt.net/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                             forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        let archive = SubtitleArchive.isArchive(selected.filename)
        let data: Data
        if archive, let cached = archiveCache[id] {
            data = cached
        } else {
            data = try await transport.fetch(request, limit: archive ? 32 * 1024 * 1024 : 8 * 1024 * 1024)
            if archive { archiveCache[id] = data }
        }
        guard archive else { return data }
        return try await SubtitleArchive.extract(data, format: candidate.format)
    }

    private func selectFile(in sub: Entry, issuedFilename: String?,
                            format: SubtitleFormat) -> (filename: String, url: String?)? {
        if let issuedFilename {
            if let file = sub.filelist.first(where: { $0.f == issuedFilename }) {
                return (issuedFilename, file.url)
            }
            if sub.filename == issuedFilename {
                return (issuedFilename, sub.url)
            }
        }
        if let file = sub.filelist.first(where: {
            SubtitleFormat(rawValue: ($0.f as NSString).pathExtension.lowercased()) == format
        }) {
            return (file.f, file.url)
        }
        if let filename = sub.filename {
            if SubtitleFormat(rawValue: (filename as NSString).pathExtension.lowercased()) == format
                || SubtitleArchive.isArchive(filename) {
                return (filename, sub.url)
            }
        }
        if let address = sub.url, let filename = URL(string: address)?.lastPathComponent {
            if SubtitleFormat(rawValue: (filename as NSString).pathExtension.lowercased()) == format
                || SubtitleArchive.isArchive(filename) {
                return (filename, address)
            }
        }
        return nil
    }

    private func api(_ action: String, query: [URLQueryItem]) async throws -> Response {
        try await limiter.wait()
        var url = URLComponents(string: "https://api.assrt.net/v1/sub/\(action)")!
        url.queryItems = query
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let data: Data
        do {
            data = try await transport.fetch(request, limit: 2 * 1024 * 1024)
        } catch SubtitleError.http(509) {
            throw SourceAPIError.rateLimited(source.name)
        }
        do {
            // Read business status first: an error payload need not have a valid result page.
            let status = try JSONDecoder().decode(Status.self, from: data).status
            guard status == 0 else {
                if status == 30900 { throw SourceAPIError.rateLimited(source.name) }
                throw SourceAPIError.rejected(source.name, status)
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as DecodingError {
            let path: [any CodingKey]
            switch error {
            case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
                path = context.codingPath
            case .keyNotFound(let key, let context): path = context.codingPath + [key]
            @unknown default: path = []
            }
            // Include schema location, never raw JSON, API URLs, token or debugDescription.
            throw AssrtResponseError(field: (["response"] + path.map(\.stringValue)).joined(separator: "."))
        }
    }
    private struct Status: Decodable { let status: Int }
    private struct Response: Decodable { let status: Int; let sub: Page? }
    private struct Page: Decodable {
        let subs: [Entry]
        enum CodingKeys: String, CodingKey { case subs }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            subs = try values.decodeIfPresent(APIList<Entry>.self, forKey: .subs)?.values ?? []
        }
    }
    private struct Entry: Decodable {
        let id: Int
        let filename: String?
        let nativeName: String?
        let videoName: String?
        let languageDescription: String?
        let subtype: String?
        let url: String?
        let filelist: [File]
        enum CodingKeys: String, CodingKey {
            case id, filename, url, filelist, lang, subtype
            case nativeName = "native_name"
            case videoName = "videoname"
        }
        private struct Language: Decodable { let desc: String? }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(Int.self, forKey: .id)
            filename = try values.decodeIfPresent(String.self, forKey: .filename)
            nativeName = try values.decodeIfPresent(String.self, forKey: .nativeName)
            videoName = try values.decodeIfPresent(String.self, forKey: .videoName)
            languageDescription = try values.decodeIfPresent(Language.self, forKey: .lang)?.desc
            subtype = try values.decodeIfPresent(String.self, forKey: .subtype)
            url = try values.decodeIfPresent(String.self, forKey: .url)
            filelist = try values.decodeIfPresent(APIList<File>.self, forKey: .filelist)?.values ?? []
        }
    }
    private struct File: Decodable { let f: String; let url: String? }

    /// ASSRT serializes empty lists as {} as well as []; reject nonempty objects and malformed entries.
    private struct APIList<Element: Decodable>: Decodable {
        let values: [Element]
        private struct Key: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: any Decoder) throws {
            if let object = try? decoder.container(keyedBy: Key.self), object.allKeys.isEmpty {
                values = []
            } else {
                values = try decoder.singleValueContainer().decode([Element].self)
            }
        }
    }
}

enum AssrtSearchQuery {
    static func make(for video: URL) -> String {
        make(filename: video.lastPathComponent)
    }

    static func make(filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        let base = VideoScanner.extensions.contains(ext) ? (filename as NSString).deletingPathExtension : filename
        var name = base.isEmpty ? filename : base
        name = name.replacingOccurrences(of: #"^\s*\[[^\]]+\]\s*"#,
                                         with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"^\s*【[^】]+】\s*"#,
                                         with: "", options: .regularExpression)
        // Release groups follow the year or episode tag and are not part of the searchable title.
        name = name.replacingOccurrences(of: #"(?i)((?:19|20)\d{2})-[a-z0-9]{2,}$"#,
                                         with: "$1", options: .regularExpression)
        name = name.replacingOccurrences(of: #"(?i)((?:s\d{1,2}e\d{1,3}|\d{1,2}x\d{1,3}))-[a-z0-9]{2,}$"#,
                                         with: "$1", options: .regularExpression)
        let marker = try! NSRegularExpression(pattern: #"""
            (?i)(?<![a-z0-9])(?:
            2160p|1080p|720p|576p|480p|4k|8k|uhd|imax|extended|uncut|remastered|theatrical|repack|
            remux|bluray|blu-ray|bdrip|brrip|web[ ._-]?dl|webrip|hdtv|dvdrip|hdcam|hdrip|
            x26[45]|h[ ._-]?26[45]|hevc|avc|av1|10bit|8bit|12bit|hdr10\+?|hdr|dolby[ ._-]?vision|dovi|
            atmos|truehd|dts(?:[ ._-]?hd)?|ddp|dd[ .]?[257]|ac3|eac3|aac|flac|opus|
            chs|cht|eng|bilingual|dual[ ._-]?audio|multi[ ._-]?(?:audio|sub|lang)|中字|双语|国语|粤语|简体|繁体|简中|繁中
            )(?![a-z0-9])
            """#, options: [.allowCommentsAndWhitespace])
        let fullRange = NSRange(name.startIndex..., in: name)
        let stem = marker.firstMatch(in: name, range: fullRange)
            .flatMap { Range($0.range, in: name).map { String(name[..<$0.lowerBound]) } }
            ?? name
        let cleaned = normalize(stem)
        return cleaned.isEmpty ? normalize(name) : cleaned
    }

    private static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"[._+()\[\]【】]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[\s-]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Shared across providers and search windows: ASSRT's default quota is 20/minute per IP/token.
public actor AssrtRateLimiter {
    public static let shared = AssrtRateLimiter()
    private var next = ContinuousClock.now
    private let interval: Duration
    public init(interval: Duration = .milliseconds(3100)) { self.interval = interval }
    public func wait() async throws {
        try Task.checkCancellation()
        let slot = max(next, .now)
        next = slot.advanced(by: interval)
        try await ContinuousClock().sleep(until: slot)
        try Task.checkCancellation()
    }
}

struct AssrtResponseError: LocalizedError {
    let field: String
    var errorDescription: String? {
        String(format: String(localized: "ASSRT response format is invalid at %@."), field)
    }
}
