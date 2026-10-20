import Foundation

/// Shooter-specific wire protocol. Selection and disk writes belong to the shared engine.
public actor ShooterProvider: SubtitleProvider {
    public nonisolated let source = SubtitleSource.shooter
    private let transport: any HTTPTransport
    private let endpoint: URL

    public init(transport: any HTTPTransport = URLSessionTransport(),
                endpoint: URL = URL(string: "https://www.shooter.cn/api/subapi.php")!) {
        self.transport = transport; self.endpoint = endpoint
    }

    public func search(_ request: SubtitleSearchRequest) async throws -> [SubtitleCandidate] {
        try Task.checkCancellation()
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil,
              var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SubtitleProviderError.invalidEndpoint
        }
        let hash = try VideoHasher.hash(request.video)
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"), URLQueryItem(name: "lang", value: "Chn"),
            URLQueryItem(name: "filehash", value: hash), URLQueryItem(name: "pathinfo", value: request.filename)
        ]
        guard let url = components.url else { throw SubtitleProviderError.invalidEndpoint }
        let data = try await transport.fetch(URLRequest(url: url), limit: 2 * 1024 * 1024)
        try Task.checkCancellation()
        if data.isEmpty || data == Data([0xff]) || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "-1" {
            return []
        }
        let matches: [ShooterMatch]
        do { matches = try JSONDecoder().decode([ShooterMatch].self, from: data) }
        catch { throw SubtitleError.invalidResponse }
        return matches.filter { $0.delay == 0 }.flatMap { match in
            match.files.compactMap { file in
                guard let format = SubtitleFormat(rawValue: file.ext.lowercased()) else { return nil }
                return SubtitleCandidate(source: source, reference: file.link.absoluteString,
                                         title: file.link.lastPathComponent, format: format,
                                         languageCodes: ["zh"], matchKind: .fingerprint,
                                         delayMilliseconds: match.delay)
            }
        }
    }

    public func download(_ candidate: SubtitleCandidate) async throws -> Data {
        try Task.checkCancellation()
        guard candidate.source == source else { throw SubtitleProviderError.invalidCandidate }
        guard let url = URL(string: candidate.reference), url.scheme?.lowercased() == "https", url.host != nil else {
            throw SubtitleError.insecureURL
        }
        return try await transport.fetch(URLRequest(url: url), limit: 8 * 1024 * 1024)
    }
}

private struct ShooterMatch: Decodable {
    let delay: Int
    let files: [ShooterLink]
    enum CodingKeys: String, CodingKey { case delay = "Delay", files = "Files" }
}

private struct ShooterLink: Decodable {
    let ext: String
    let link: URL
    enum CodingKeys: String, CodingKey { case ext = "Ext", link = "Link" }
}
