import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import EasySubCore
#endif

private actor OpenSubtitlesStub: HTTPTransport {
    var responses: [Data]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [String]) { self.responses = responses.map { Data($0.utf8) } }
    func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        requests.append(request)
        guard !responses.isEmpty else { throw SubtitleError.invalidResponse }
        return responses.removeFirst()
    }
}

private actor OpenSubtitlesRateLimitStub: HTTPTransport {
    private(set) var attempts = 0
    func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        attempts += 1
        if attempts == 1 { throw SubtitleError.http(429) }
        return Data(#"{"data":[]}"#.utf8)
    }
}

private func openSubtitlesVideo(size: Int = 131_072) throws -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let video = directory.appendingPathComponent("Movie.2024.mkv")
    try Data(repeating: 0, count: size).write(to: video)
    return (directory, video)
}

@Test func openSubtitlesHashUsesSizeAndTwoLittleEndianChunks() throws {
    let (directory, video) = try openSubtitlesVideo()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try OpenSubtitlesHasher.hash(video) == "0000000000020000")
    let small = directory.appendingPathComponent("small.mkv")
    try Data(repeating: 0, count: 131_071).write(to: small)
    #expect(throws: SubtitleError.self) { try OpenSubtitlesHasher.hash(small) }
}

@Test func openSubtitlesSearchUsesCanonicalQueryAndDownloadsIssuedFile() async throws {
    let (directory, video) = try openSubtitlesVideo()
    defer { try? FileManager.default.removeItem(at: directory) }
    let search = #"{"data":[{"attributes":{"language":"zh-CN","ratings":8,"from_trusted":true,"release":"Movie.2024.1080p","moviehash_match":true,"feature_details":{"title":"Movie","movie_name":"Movie (2024)"},"files":[{"file_id":42,"cd_number":1,"file_name":"Movie.2024.zh-cn.srt"}]}}]}"#
    let stub = OpenSubtitlesStub([search, #"{"link":"https://files.test/sub.srt"}"#, "1\n00:00:01,000 --> 00:00:02,000\nHello\n"])
    let provider = try OpenSubtitlesProvider(apiKey: "test-key", userAgent: "EasySub vTest",
                                            transport: stub, limiter: .init(interval: .zero))
    let results = try await provider.search(.init(video: video, searchName: "Movie Name 2024",
                                                   preferredLanguageCodes: ["zh-cn"],
                                                   includesUnpreferredLanguages: false))
    let candidate = try #require(results.first)
    #expect(candidate.reference == "42")
    #expect(candidate.languageCodes == ["zh-cn"])
    #expect(candidate.matchKind == .fingerprint)
    #expect(try await provider.download(candidate).starts(with: Data("1\n".utf8)))
    let requests = await stub.requests
    #expect(requests.count == 3)
    #expect(requests[0].value(forHTTPHeaderField: "Api-Key") == "test-key")
    #expect(requests[0].value(forHTTPHeaderField: "User-Agent") == "EasySub vTest")
    let items = URLComponents(url: try #require(requests[0].url), resolvingAgainstBaseURL: false)?.queryItems ?? []
    #expect(items.map(\.name) == ["languages", "moviehash", "query"])
    #expect(items.first { $0.name == "moviehash" }?.value == "0000000000020000")
    #expect(requests[0].url?.absoluteString.contains("query=movie+name+2024") == true)
    #expect(requests[1].httpMethod == "POST")
    #expect(requests[2].value(forHTTPHeaderField: "Api-Key") == nil)
}

@Test func openSubtitlesValidatesKeyAndRetriesOneRateLimit() async throws {
    #expect(throws: SourceAPIError.self) { try OpenSubtitlesProvider(apiKey: "  ") }
    let (directory, video) = try openSubtitlesVideo()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stub = OpenSubtitlesRateLimitStub()
    let provider = try OpenSubtitlesProvider(apiKey: "key", transport: stub,
                                            limiter: .init(interval: .zero), retryDelay: .zero)
    let results = try await provider.search(.init(video: video))
    #expect(results.isEmpty)
    #expect(await stub.attempts == 2)
}

@Test func openSubtitlesAutomaticSearchSkipsMultiFileResults() async throws {
    let (directory, video) = try openSubtitlesVideo()
    defer { try? FileManager.default.removeItem(at: directory) }
    let response = #"{"data":[{"attributes":{"language":"en","files":[{"file_id":1,"cd_number":1,"file_name":"CD1.srt"},{"file_id":2,"cd_number":2,"file_name":"CD2.srt"}]}}]}"#
    let provider = try OpenSubtitlesProvider(apiKey: "key", transport: OpenSubtitlesStub([response]),
                                            limiter: .init(interval: .zero))
    let results = try await provider.search(.init(video: video, preferredLanguageCodes: ["en"],
                                                   includesUnpreferredLanguages: false))
    #expect(results.isEmpty)
}
