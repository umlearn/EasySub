import Foundation
import CryptoKit

/// Filename search is not a fingerprint match: timing remains unknown.
public actor XunleiProvider: SubtitleProvider {
    public nonisolated let source = SubtitleSource(id: "xunlei", name: "迅雷")
    private let transport: any HTTPTransport
    private var issued: [String: SubtitleCandidate] = [:]
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func search(_ request: SubtitleSearchRequest) async throws -> [SubtitleCandidate] {
        let videoCID = try? await Task.detached(priority: .utility) {
            try XunleiCIDHasher.hash(request.video)
        }.value
        var url = URLComponents(string: "https://api-shoulei-ssl.xunlei.com/oracle/subtitle")!
        url.queryItems = [URLQueryItem(name: "name", value: request.matchingName)]
        let data = try await transport.fetch(URLRequest(url: url.url!), limit: 2 * 1024 * 1024)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.code == 0 else { throw SourceAPIError.rejected(source.name, response.code) }
        var seen = Set<String>()
        let candidates = (response.data ?? []).compactMap { item -> SubtitleCandidate? in
            guard let format = SubtitleFormat(rawValue: item.ext.lowercased()),
                  let url = URL(string: item.url), url.scheme == "https",
                  seen.insert(item.url.lowercased()).inserted else { return nil }
            let hashMatch = videoCID != nil && item.cid?.caseInsensitiveCompare(videoCID!) == .orderedSame
            let score = (item.score ?? 0) + (item.fingerprintScore ?? 0)
            let filenameLanguages = SubtitleLanguageNormalizer.codes(fromFileName: item.name)
            let simpleNameLanguages = item.simpleName.map(SubtitleLanguageNormalizer.codes(fromFileName:)) ?? []
            let providerLanguages = SubtitleLanguageNormalizer.codes(from: item.languages ?? [])
            let languages = !filenameLanguages.isEmpty ? filenameLanguages
                : (!simpleNameLanguages.isEmpty ? simpleNameLanguages : providerLanguages)
            let candidate = SubtitleCandidate(
                source: source, reference: item.url, title: item.name,
                matchingText: [item.name, item.simpleName].compactMap { $0 }.joined(separator: " / "),
                format: format, languageCodes: languages,
                matchKind: hashMatch ? .fingerprint : .filename,
                providerScore: score
            )
            issued[candidate.reference] = candidate
            return candidate
        }
        return candidates.sorted {
            if $0.matchKind != $1.matchKind { return $0.matchKind == .fingerprint }
            let leftSimplified = Self.isSimplifiedChinese($0)
            let rightSimplified = Self.isSimplifiedChinese($1)
            if leftSimplified != rightSimplified { return leftSimplified }
            return ($0.providerScore ?? 0) > ($1.providerScore ?? 0)
        }.prefix(20).map { $0 }
    }
    public func download(_ candidate: SubtitleCandidate) async throws -> Data {
        guard issued[candidate.reference] == candidate, let url = URL(string: candidate.reference) else {
            throw SubtitleProviderError.invalidCandidate
        }
        return try await transport.fetch(URLRequest(url: url), limit: 8 * 1024 * 1024)
    }
    private struct Response: Decodable { let code: Int; let data: [Item]? }
    private static func isSimplifiedChinese(_ candidate: SubtitleCandidate) -> Bool {
        candidate.languageCodes.contains("zh-cn")
    }
    private struct Item: Decodable {
        let url: String
        let ext: String
        let name: String
        let languages: [String]?
        let cid: String?
        let simpleName: String?
        let score: Int?
        let fingerprintScore: Int?
        enum CodingKeys: String, CodingKey {
            case url, ext, name, languages, cid, score
            case simpleName = "simple_name"
            case fingerprintScore = "fingerprintf_score"
        }
    }
}

enum XunleiCIDHasher {
    private static let blockSize = 0x5000
    private static let sampledSize = 0xf000

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        var payload = Data()
        if size < UInt64(sampledSize) {
            payload = try readExactly(handle, count: Int(size))
        } else {
            for offset in [UInt64(0), size / 3, size - UInt64(blockSize)] {
                try handle.seek(toOffset: offset)
                payload.append(try readExactly(handle, count: blockSize))
            }
        }
        return Insecure.SHA1.hash(data: payload).map { String(format: "%02X", $0) }.joined()
    }

    private static func readExactly(_ handle: FileHandle, count: Int) throws -> Data {
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw SubtitleError.unreadableFile }
        return data
    }
}

public enum SourceAPIError: Error, LocalizedError, Sendable {
    case rejected(String, Int), rateLimited(String), invalidToken, missingFile
    case missingAPIKey(String), invalidAPIKey(String), accountRequired(String), downloadLimitReached(String)
    public var errorDescription: String? {
        switch self {
        case .rejected(let source, let code): "\(source): API error \(code)"
        case .rateLimited(let source): String(format: String(localized: "%@ request limit reached. Try again in a minute."), source)
        case .invalidToken: String(localized: "Enter a valid 32-character ASSRT token in Settings.")
        case .missingFile: String(localized: "The subtitle file is no longer available. Search again.")
        case .missingAPIKey(let source): String(format: String(localized: "%@ requires an API key in Settings."), source)
        case .invalidAPIKey(let source): String(format: String(localized: "%@ rejected the API key."), source)
        case .accountRequired(let source): String(format: String(localized: "%@ currently requires account authentication for downloads."), source)
        case .downloadLimitReached(let source): String(format: String(localized: "%@ daily download limit reached."), source)
        }
    }
}
