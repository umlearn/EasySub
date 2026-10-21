import Foundation

public actor OpenSubtitlesProvider: SubtitleProvider {
    public nonisolated let source = SubtitleSource(id: "opensubtitles", name: "OpenSubtitles")
    private let apiKey: String
    private let userAgent: String
    private let transport: any HTTPTransport
    private let limiter: OpenSubtitlesRateLimiter
    private let retryDelay: Duration
    private var issued: [String: SubtitleCandidate] = [:]

    public init(apiKey: String, userAgent: String = "EasySub v1",
                transport: any HTTPTransport = URLSessionTransport(),
                limiter: OpenSubtitlesRateLimiter = .shared,
                retryDelay: Duration = .seconds(1)) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SourceAPIError.missingAPIKey(source.name) }
        self.apiKey = key
        self.userAgent = userAgent
        self.transport = transport
        self.limiter = limiter
        self.retryDelay = retryDelay
    }

    public func search(_ request: SubtitleSearchRequest) async throws -> [SubtitleCandidate] {
        issued.removeAll()
        let hash = try? await Task.detached(priority: .utility) {
            try OpenSubtitlesHasher.hash(request.video)
        }.value
        let preferred = request.preferredLanguageCodes.sorted()
        var results = try await searchPage(request, hash: hash,
                                           languages: preferred.isEmpty ? nil : preferred)
        if request.includesUnpreferredLanguages, !preferred.isEmpty {
            results += try await searchPage(request, hash: hash, languages: nil)
        }
        var seen = Set<String>()
        return results.filter { seen.insert($0.reference).inserted }
    }

    public func download(_ candidate: SubtitleCandidate) async throws -> Data {
        guard issued[candidate.reference] == candidate, let fileID = Int(candidate.reference) else {
            throw SubtitleProviderError.invalidCandidate
        }
        var request = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/download")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request)
        request.httpBody = try JSONEncoder().encode(DownloadBody(fileID: fileID))
        let data = try await apiFetch(request, limit: 512 * 1024)
        let response: DownloadResponse
        do { response = try JSONDecoder().decode(DownloadResponse.self, from: data) }
        catch { throw SubtitleError.invalidResponse }
        guard let url = URL(string: response.link), url.scheme?.lowercased() == "https" else {
            throw SubtitleError.insecureURL
        }
        return try await transport.fetch(URLRequest(url: url), limit: 8 * 1024 * 1024)
    }

    private func searchPage(_ request: SubtitleSearchRequest, hash: String?,
                            languages: [String]?) async throws -> [SubtitleCandidate] {
        var query: [URLQueryItem] = []
        if let languages, !languages.isEmpty {
            query.append(URLQueryItem(name: "languages", value: languages.joined(separator: ",")))
        }
        if let hash { query.append(URLQueryItem(name: "moviehash", value: hash)) }
        query.append(URLQueryItem(name: "query", value: request.matchingName.lowercased()))
        var components = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        components.queryItems = query.sorted { $0.name < $1.name }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "%20", with: "+")
        guard let url = components.url else { throw SubtitleProviderError.invalidEndpoint }
        var urlRequest = URLRequest(url: url)
        applyHeaders(to: &urlRequest)
        let data = try await apiFetch(urlRequest, limit: 2 * 1024 * 1024)
        let response: SearchResponse
        do { response = try JSONDecoder().decode(SearchResponse.self, from: data) }
        catch { throw SubtitleError.invalidResponse }

        var candidates: [SubtitleCandidate] = []
        for result in response.data {
            let attributes = result.attributes
            if !request.includesUnpreferredLanguages && attributes.files.count != 1 { continue }
            for file in attributes.files {
                let ext = (file.fileName as NSString).pathExtension.lowercased()
                let format: SubtitleFormat
                switch ext {
                case "ass": format = .ass
                case "", "srt": format = .srt
                default: continue
                }
                let baseTitle = file.fileName.isEmpty ? (attributes.release ?? "OpenSubtitles \(file.fileID)") : file.fileName
                let title: String
                if attributes.files.count > 1, let cdNumber = file.cdNumber {
                    title = "\(baseTitle) (CD \(cdNumber))"
                } else { title = baseTitle }
                let matchingText = [attributes.release, attributes.featureDetails?.movieName,
                                    attributes.featureDetails?.title, file.fileName]
                    .compactMap { $0 }.joined(separator: " / ")
                let score = (attributes.fromTrusted == true ? 10 : 0) + (attributes.ratings ?? 0)
                let candidate = SubtitleCandidate(
                    source: source, reference: String(file.fileID), title: title,
                    matchingText: matchingText, format: format,
                    languageCodes: [attributes.language],
                    matchKind: attributes.moviehashMatch == true ? .fingerprint : .filename,
                    providerScore: score)
                issued[candidate.reference] = candidate
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func apiFetch(_ request: URLRequest, limit: Int) async throws -> Data {
        for attempt in 0...1 {
            try await limiter.wait()
            do { return try await transport.fetch(request, limit: limit) }
            catch SubtitleError.http(429) where attempt == 0 {
                try await Task.sleep(for: retryDelay)
            } catch SubtitleError.http(401) {
                throw SourceAPIError.invalidAPIKey(source.name)
            } catch SubtitleError.http(403) {
                throw SourceAPIError.accountRequired(source.name)
            } catch SubtitleError.http(let status) where [406, 407].contains(status) {
                throw SourceAPIError.downloadLimitReached(source.name)
            }
        }
        throw SourceAPIError.rateLimited(source.name)
    }

    private struct SearchResponse: Decodable { let data: [Result] }
    private struct Result: Decodable { let attributes: Attributes }
    private struct Attributes: Decodable {
        let language: String
        let ratings: Int?
        let fromTrusted: Bool?
        let release: String?
        let moviehashMatch: Bool?
        let featureDetails: FeatureDetails?
        let files: [File]
        enum CodingKeys: String, CodingKey {
            case language, ratings, release, files
            case fromTrusted = "from_trusted"
            case moviehashMatch = "moviehash_match"
            case featureDetails = "feature_details"
        }
    }
    private struct FeatureDetails: Decodable {
        let title: String?
        let movieName: String?
        enum CodingKeys: String, CodingKey { case title; case movieName = "movie_name" }
    }
    private struct File: Decodable {
        let fileID: Int
        let cdNumber: Int?
        let fileName: String
        enum CodingKeys: String, CodingKey {
            case fileID = "file_id"; case cdNumber = "cd_number"; case fileName = "file_name"
        }
    }
    private struct DownloadBody: Encodable {
        let fileID: Int
        enum CodingKeys: String, CodingKey { case fileID = "file_id" }
    }
    private struct DownloadResponse: Decodable { let link: String }
}

public actor OpenSubtitlesRateLimiter {
    public static let shared = OpenSubtitlesRateLimiter()
    private let interval: Duration
    private var next = ContinuousClock.now
    public init(interval: Duration = .milliseconds(210)) { self.interval = interval }
    public func wait() async throws {
        try Task.checkCancellation()
        let slot = max(next, .now)
        next = slot.advanced(by: interval)
        try await ContinuousClock().sleep(until: slot)
    }
}

enum OpenSubtitlesHasher {
    private static let chunkSize = 64 * 1024

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= UInt64(chunkSize * 2) else { throw SubtitleError.smallFile }
        try handle.seek(toOffset: 0)
        let first = try read(handle)
        try handle.seek(toOffset: size - UInt64(chunkSize))
        let last = try read(handle)
        var value = size
        for data in [first, last] {
            for offset in stride(from: 0, to: data.count, by: 8) {
                var word: UInt64 = 0
                for index in 0..<8 { word |= UInt64(data[offset + index]) << UInt64(index * 8) }
                value &+= word
            }
        }
        return String(format: "%016llx", value)
    }

    private static func read(_ handle: FileHandle) throws -> Data {
        let data = try handle.read(upToCount: chunkSize) ?? Data()
        guard data.count == chunkSize else { throw SubtitleError.unreadableFile }
        return data
    }
}
