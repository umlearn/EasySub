import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import EasySubCore
#endif

private actor APIStub: HTTPTransport {
    var responses: [Data]
    private(set) var requests: [URLRequest] = []
    init(_ responses: [String]) { self.responses = responses.map { Data($0.utf8) } }
    init(data responses: [Data]) { self.responses = responses }
    func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        requests.append(request)
        guard !responses.isEmpty else { throw SubtitleError.invalidResponse }
        return responses.removeFirst()
    }
}

private struct FailingAPIStub: HTTPTransport {
    let error: SubtitleError
    func fetch(_ request: URLRequest, limit: Int) async throws -> Data { throw error }
}

private func makeZip(_ files: [String: String]) throws -> Data {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for (name, contents) in files {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }
    let archive = directory.appendingPathComponent("subtitle.zip")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = directory
    process.arguments = ["-q", archive.lastPathComponent] + files.keys.sorted()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw SubtitleError.archiveUnsupported }
    return try Data(contentsOf: archive)
}

@Test func xunleiSearchPreservesUnknownTimingAndEncodesFilename() async throws {
    let stub = APIStub([#"{"code":0,"data":[{"url":"https://files.test/sub.srt","ext":"srt","name":"Movie.srt","languages":["简体"]},{"url":"http://files.test/sub.srt","ext":"srt","name":"unsafe"}]}"#, "subtitle"])
    let provider = XunleiProvider(transport: stub)
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie & Name.mkv")))
    #expect(results.count == 1)
    #expect(results[0].delayMilliseconds == nil)
    #expect(results[0].languageCodes == ["zh-cn"])
    let request = await stub.requests[0]
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Movie & Name")
    #expect(try await provider.download(results[0]) == Data("subtitle".utf8))
}

@Test func editedSearchNameIsSentWithoutChangingTheVideoURL() async throws {
    let stub = APIStub([#"{"code":0,"data":[]}"#])
    let provider = XunleiProvider(transport: stub)
    let video = URL(fileURLWithPath: "/tmp/Original.Release.2024.mkv")
    _ = try await provider.search(.init(video: video, searchName: "Edited Movie 2026.mp4"))
    let request = await stub.requests[0]
    #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Edited Movie 2026")
}

@Test func xunleiCIDUsesWholeSmallFileAndThreeSamplesForLargeFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let small = directory.appendingPathComponent("small.mkv")
    try Data(repeating: 0, count: 16384).write(to: small)
    #expect(try XunleiCIDHasher.hash(small) == "897256B6709E1A4DA9DABA92B6BDE39CCFCCD8C1")
    let large = directory.appendingPathComponent("large.mkv")
    try Data((0..<100_000).map { UInt8($0 % 251) }).write(to: large)
    #expect(try XunleiCIDHasher.hash(large) == "D4090EA01D10880E8327F6FBDE52CD6F75715FE7")
}

@Test func xunleiRanksCIDThenSimplifiedChineseAndDeduplicatesURLs() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let video = directory.appendingPathComponent("Movie.2024.mkv")
    try Data(repeating: 0, count: 16384).write(to: video)
    let cid = "897256B6709E1A4DA9DABA92B6BDE39CCFCCD8C1"
    let response = #"{"code":0,"data":[{"url":"https://files.test/trad.srt","ext":"srt","name":"Movie.2024.CHT.srt","languages":["繁体"],"score":100},{"url":"https://files.test/simple.srt","ext":"srt","name":"Movie.2024.CHS.srt","simple_name":"中文 Movie 2024","languages":["简体"]},{"url":"https://files.test/hash.srt","ext":"srt","name":"opaque.srt","languages":["繁体"],"cid":"\#(cid)"},{"url":"https://files.test/simple.srt","ext":"srt","name":"duplicate.srt","languages":["简体"]}]}"#
    let provider = XunleiProvider(transport: APIStub([response]))
    let results = try await provider.search(.init(video: video))
    #expect(results.map(\.reference) == ["https://files.test/hash.srt", "https://files.test/simple.srt", "https://files.test/trad.srt"])
    #expect(results.first?.matchKind == .fingerprint)
    #expect(results[1].matchingText.contains("中文 Movie 2024"))
}

@Test func xunleiUsesFilenameLanguageBeforeProviderMetadata() async throws {
    let response = #"{"code":0,"data":[{"url":"https://files.test/simple.srt","ext":"srt","name":"Movie.WEB-DLChsEng.srt"},{"url":"https://files.test/trad.srt","ext":"srt","name":"Movie.zh-Hant.srt","languages":["简体"]}]}"#
    let provider = XunleiProvider(transport: APIStub([response]))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
    #expect(results.first(where: { $0.reference.hasSuffix("simple.srt") })?.languageCodes == ["zh-cn", "en", "ze"])
    #expect(results.first(where: { $0.reference.hasSuffix("trad.srt") })?.languageCodes == ["zh-tw"])
}

@Test func xunleiRejectsBusinessError() async throws {
    let provider = XunleiProvider(transport: APIStub([#"{"code":500}"#]))
    await #expect(throws: SourceAPIError.self) {
        try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/movie.mkv")))
    }
}

@Test func assrtResolvesFreshIndividualLinksAndScopesCredentials() async throws {
    let stub = APIStub([
        #"{"status":0,"sub":{"subs":[{"id":123456,"native_name":"电影/Movie","videoname":"Movie.2024.1080p","filename":"Movie.zip","lang":{"desc":"简 双语"},"filelist":[{"f":"Movie.srt"},{"f":"Movie.idx"}]}]}}"#,
        #"{"status":0,"sub":{"subs":[{"id":123456,"filelist":[{"f":"Movie.srt","url":"https://files.test/fresh.srt"}]}]}}"#,
        "subtitle"
    ])
    let token = String(repeating: "a", count: 32)
    let provider = try AssrtProvider(token: token, transport: stub, limiter: AssrtRateLimiter(interval: .zero))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
    #expect(results.count == 1)
    #expect(results[0].delayMilliseconds == nil)
    #expect(results[0].matchingText.contains("Movie.2024.1080p"))
    #expect(results[0].languageCodes == ["zh-cn", "ze"])
    #expect(try await provider.download(results[0]) == Data("subtitle".utf8))
    let requests = await stub.requests
    #expect(requests.count == 3)
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    #expect(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.contains {
        $0.name == "is_file" && $0.value == "1"
    } == true)
    #expect(requests[1].url?.path == "/v1/sub/detail")
    #expect(requests[2].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(requests.allSatisfy { !$0.url!.absoluteString.contains(token) })
}

@Test func assrtUsesIndividualFileLanguagesInsteadOfGroupDescription() async throws {
    let stub = APIStub([
        #"{"status":0,"sub":{"subs":[{"id":42,"filename":"Movie.zip","lang":{"desc":"英 简 繁 双语"},"filelist":[{"f":"Movie.chs.ass"},{"f":"Movie.cht.ass"},{"f":"Movie.chs&eng.ass"},{"f":"Movie.cht&eng.ass"},{"f":"Movie.idx"}]}]}}"#
    ])
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32), transport: stub,
                                     limiter: AssrtRateLimiter(interval: .zero))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
    #expect(results.map(\.languageCodes) == [
        ["zh-cn"],
        ["zh-tw"],
        ["en", "ze", "zh-cn"],
        ["en", "ze", "zh-tw"]
    ])
}

@Test func assrtDoesNotApplyAmbiguousGroupLanguagesToEveryChildFile() async throws {
    let stub = APIStub([
        #"{"status":0,"sub":{"subs":[{"id":43,"filename":"Movie.zip","lang":{"desc":"英 简 繁 日 法 德 双语"},"filelist":[{"f":"Fre.srt"},{"f":"Cht_chs.srt"},{"f":"蜘蛛侠.中英字幕.ass"},{"f":"Ger.srt"},{"f":"Jpn.srt"},{"f":"Chs.srt"},{"f":"Movie.SDH.srt"}] }]}}"#
    ])
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32), transport: stub,
                                     limiter: AssrtRateLimiter(interval: .zero))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
    #expect(results.map(\.languageCodes) == [
        ["fr"], ["zh-cn", "zh-tw"], ["en", "ze", "zh"], ["de"], ["ja"], ["zh-cn"], []
    ])
}

@Test func assrtKeepsUnambiguousGroupLanguageFallback() async throws {
    let stub = APIStub([
        #"{"status":0,"sub":{"subs":[{"id":44,"filename":"Movie.zip","lang":{"desc":"简体"},"filelist":[{"f":"Movie.SDH.srt"},{"f":"Movie.Forced.ass"}]}]}}"#
    ])
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32), transport: stub,
                                     limiter: AssrtRateLimiter(interval: .zero))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
    #expect(results.map(\.languageCodes) == [["zh-cn"], ["zh-cn"]])
}

@Test func assrtRejectsInvalidTokenAndBusinessErrors() async throws {
    #expect(throws: SourceAPIError.self) { try AssrtProvider(token: "bad") }
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32), transport: APIStub([#"{"status":1}"#]), limiter: AssrtRateLimiter(interval: .zero))
    await #expect(throws: SourceAPIError.self) { try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv"))) }
}

@Test func assrtSearchQueryStripsReleaseMetadataWithoutDamagingTitles() {
    #expect(AssrtSearchQuery.make(filename: "Oppenheimer.2023.IMAX.1080p.BluRay.DTS-HD.MA.5.1.x265-EGEN.mkv")
        == "Oppenheimer 2023")
    #expect(AssrtSearchQuery.make(filename: "The.Matrix.1999.1080p.BluRay.x264.mkv")
        == "The Matrix 1999")
    #expect(AssrtSearchQuery.make(filename: "Severance.S02E03.2160p.WEB-DL.H265.DDP5.1.Atmos-GROUP.mkv")
        == "Severance S02E03")
    #expect(AssrtSearchQuery.make(filename: "流浪地球2.2023.2160p.UHD.BluRay.HDR.x265.mkv")
        == "流浪地球2 2023")
    #expect(AssrtSearchQuery.make(filename: "1917.2019.1080p.BluRay.x264.mkv")
        == "1917 2019")
    #expect(AssrtSearchQuery.make(filename: "Dual.2022.1080p.WEB-DL.mkv") == "Dual 2022")
    #expect(AssrtSearchQuery.make(filename: "[GROUP] Show - 01 [1080p].mkv") == "Show 01")
    #expect(AssrtSearchQuery.make(filename: "Show.S01E01-GROUP.mkv") == "Show S01E01")
    #expect(AssrtSearchQuery.make(filename: "简爱.2010.1080p.mkv") == "简爱 2010")
    #expect(AssrtSearchQuery.make(filename: "Spider-Man.Brand.New.Day.2026") == "Spider Man Brand New Day 2026")
    #expect(AssrtSearchQuery.make(filename: "A.Proper.Gentleman.2023.1080p.mkv")
        == "A Proper Gentleman 2023")
    #expect(AssrtSearchQuery.make(for: URL(fileURLWithPath: "/tmp/Hopeu.2026.1080p.WEBRip.mkv"))
        == "Hopeu 2026")
}

@Test func assrtSearchSendsNormalizedQuery() async throws {
    let stub = APIStub([#"{"status":0,"sub":{"subs":[]}}"#])
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32),
                                    transport: stub, limiter: AssrtRateLimiter(interval: .zero))
    let video = URL(fileURLWithPath: "/tmp/Oppenheimer.2023.IMAX.1080p.BluRay.x265-EGEN.mkv")
    _ = try await provider.search(.init(video: video))
    let request = try #require(await stub.requests.first)
    let query = URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
        .queryItems?.first { $0.name == "q" }?.value
    #expect(query == "Oppenheimer 2023")
}

@Test func assrtAllowsHTTPOnlyForFileHostsAndAddsReferer() async throws {
    let stub = APIStub([
        #"{"status":0,"sub":{"subs":[{"id":1,"filename":"Movie.srt","filelist":[{"f":"Movie.srt"}]}]}}"#,
        #"{"status":0,"sub":{"subs":[{"id":1,"filelist":[{"f":"Movie.srt","url":"http://file1.assrt.net/onthefly/Movie.srt"}]}]}}"#,
        "subtitle"
    ])
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32),
                                    transport: stub, limiter: AssrtRateLimiter(interval: .zero))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.2024.mkv")))
    let candidate = try #require(results.first)
    #expect(try await provider.download(candidate) == Data("subtitle".utf8))
    let requests = await stub.requests
    #expect(requests[2].url?.host == "file1.assrt.net")
    #expect(requests[2].value(forHTTPHeaderField: "Referer") == "https://assrt.net/")
    #expect(requests[2].value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func assrtRejectsHTTPFromUnrelatedHosts() async throws {
    let stub = APIStub([
        #"{"status":0,"sub":{"subs":[{"id":1,"filename":"Movie.srt","filelist":[{"f":"Movie.srt"}]}]}}"#,
        #"{"status":0,"sub":{"subs":[{"id":1,"filelist":[{"f":"Movie.srt","url":"http://example.com/Movie.srt"}]}]}}"#
    ])
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32),
                                    transport: stub, limiter: AssrtRateLimiter(interval: .zero))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.2024.mkv")))
    let candidate = try #require(results.first)
    await #expect(throws: SubtitleError.self) { try await provider.download(candidate) }
}

@Test func transportHTTPPolicyIsLimitedToASSRTFileHosts() throws {
    try URLSessionTransport.validate(URL(string: "http://file0.assrt.net/sub.srt"),
                                     allowsInsecureASSRTFiles: true)
    try URLSessionTransport.validate(URL(string: "https://example.com/sub.srt"),
                                     allowsInsecureASSRTFiles: false)
    #expect(throws: SubtitleError.self) {
        try URLSessionTransport.validate(URL(string: "http://example.com/sub.srt"),
                                         allowsInsecureASSRTFiles: true)
    }
    #expect(throws: SubtitleError.self) {
        try URLSessionTransport.validate(URL(string: "http://file1.assrt.net.evil.test/sub.srt"),
                                         allowsInsecureASSRTFiles: true)
    }
    #expect(URLSessionTransport.isASSRTFileHost("file12.assrt.net"))
    #expect(URLSessionTransport.isASSRTFileHost("dl1.assrt.net"))
    #expect(!URLSessionTransport.isASSRTFileHost("api.assrt.net"))
}

@Test func assrtExplainsQuotaFailures() async throws {
    let token = String(repeating: "a", count: 32)
    let httpProvider = try AssrtProvider(token: token, transport: FailingAPIStub(error: .http(509)),
                                         limiter: AssrtRateLimiter(interval: .zero))
    await #expect(throws: SourceAPIError.self) {
        try await httpProvider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
    }
    let businessProvider = try AssrtProvider(token: token, transport: APIStub([#"{"status":30900}"#]),
                                             limiter: AssrtRateLimiter(interval: .zero))
    await #expect(throws: SourceAPIError.self) {
        try await businessProvider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
    }
}

@Test func unissuedCandidateCannotBeDownloaded() async throws {
    let provider = XunleiProvider(transport: APIStub([]))
    let candidate = SubtitleCandidate(source: provider.source, reference: "https://files.test/a.srt", title: "a", format: .srt)
    await #expect(throws: SubtitleProviderError.self) { try await provider.download(candidate) }
}

@Test func cancelledRateLimitWaitDoesNotIssueRequest() async throws {
    let limiter = AssrtRateLimiter(interval: .seconds(30))
    try await limiter.wait()
    let task = Task { try await limiter.wait() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func manualPayloadValidationRejectsArchivesAndJSON() throws {
    #expect(throws: SubtitleError.self) { try SubtitleFileWriter.normalized(Data("{\"error\":1}".utf8), format: .srt) }
    #expect(throws: SubtitleError.self) { try SubtitleFileWriter.normalized(Data([0x50, 0x4b, 0x03, 0x04]), format: .ass) }
    let text = "1\n00:00:01,000 --> 00:00:02,000\n字幕\n"
    let utf16 = try #require(text.data(using: .utf16))
    #expect(try SubtitleFileWriter.normalized(utf16, format: .srt) == Data(text.utf8))
}

@Test func manualDownloadAllowsUnknownTimingAndNumbersAdditionalFiles() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let payload = "1\n00:00:01,000 --> 00:00:02,000\nHello\n"
    let stub = APIStub([#"{"code":0,"data":[{"url":"https://files.test/sub.srt","ext":"srt","name":"Movie.srt"}]}"#, payload, payload])
    let service = MultiSourceSubtitleService(provider: XunleiProvider(transport: stub))
    let video = directory.appendingPathComponent("movie.mkv")
    let result = try await service.search(.init(video: video))
    let candidate = try #require(result.candidates.first)
    let output = try await service.download(candidate: candidate, video: video, overwrite: false)
    #expect(try Data(contentsOf: output) == Data(payload.utf8))
    let additional = try await service.download(candidate: candidate, video: video, overwrite: false)
    #expect(additional.lastPathComponent == "movie.1.srt")
    #expect(try Data(contentsOf: output) == Data(payload.utf8))
    #expect(try Data(contentsOf: additional) == Data(payload.utf8))
}

@Test func assrtEmptyObjectFilelistDoesNotDiscardOtherResults() async throws {
    let stub = APIStub([#"{"status":0,"sub":{"subs":[{"id":1,"filelist":{}},{"id":2,"filelist":[{"f":"Movie.srt"}]},{"id":3,"filelist":null},{"id":4}]}}"#])
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32), transport: stub, limiter: AssrtRateLimiter(interval: .zero))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
    #expect(results.count == 1)
    #expect(results.first?.title == "Movie.srt")
}

@Test func assrtEmptyObjectResultsAreNoMatches() async throws {
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32), transport: APIStub([#"{"status":0,"sub":{"subs":{}}}"#]), limiter: AssrtRateLimiter(interval: .zero))
    #expect(try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv"))).isEmpty)
}

@Test func assrtDirectSubtitleWithoutFilelistDownloadsFromFreshDetail() async throws {
    let stub = APIStub([
        #"{"status":0,"sub":{"subs":[{"id":1,"filename":"Movie.srt","filelist":{}},{"id":2,"filename":"Movie.zip","filelist":{}}]}}"#,
        #"{"status":0,"sub":{"subs":[{"id":1,"filename":"Movie.srt","filelist":{},"url":"https://files.test/direct.srt"}]}}"#,
        "subtitle"
    ])
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32), transport: stub, limiter: AssrtRateLimiter(interval: .zero))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
    #expect(results.count == 3)
    let direct = try #require(results.first { $0.title == "Movie.srt" })
    #expect(try await provider.download(direct) == Data("subtitle".utf8))
}

@Test func assrtDownloadsAndExtractsArchiveWhenSearchOmitsFiles() async throws {
    let srt = "1\n00:00:01,000 --> 00:00:02,000\n简体\n"
    let traditional = "1\n00:00:01,000 --> 00:00:02,000\n繁體\n"
    let ass = "[Script Info]\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,简体\n"
    let archive = try makeZip([
        "Movie.cht.srt": traditional,
        "Movie.chs.srt": srt,
        "Movie.chs.ass": ass
    ])
    let search = #"{"status":0,"sub":{"subs":[{"id":42,"native_name":"Movie 2024","subtype":"Subrip(srt)","filelist":{}}]}}"#
    let detail = #"{"status":0,"sub":{"subs":[{"id":42,"filename":"Movie.zip","url":"http://file1.assrt.net/download/42/Movie.zip","filelist":{}}]}}"#
    let stub = APIStub(data: [Data(search.utf8), Data(detail.utf8), archive, Data(detail.utf8)])
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32),
                                    transport: stub, limiter: AssrtRateLimiter(interval: .zero))
    let results = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.2024.mkv")))
    #expect(results.count == 2)
    let srtCandidate = try #require(results.first { $0.format == .srt })
    let assCandidate = try #require(results.first { $0.format == .ass })
    #expect(try await provider.download(srtCandidate) == Data(srt.utf8))
    #expect(try await provider.download(assCandidate) == Data(ass.utf8))
    let requests = await stub.requests
    #expect(requests.count == 4)
    #expect(requests[2].value(forHTTPHeaderField: "Referer") == "https://assrt.net/")
    #expect(requests[2].value(forHTTPHeaderField: "User-Agent") != nil)
}

@Test func assrtMalformedNonemptyObjectsRemainVisibleErrors() async throws {
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32), transport: APIStub([#"{"status":0,"sub":{"subs":[{"id":1,"filelist":{"unexpected":"secret"}}]}}"#]), limiter: AssrtRateLimiter(interval: .zero))
    do {
        _ = try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv")))
        Issue.record("Expected malformed list error")
    } catch let error as AssrtResponseError {
        #expect(error.field.contains("filelist"))
        #expect(!error.localizedDescription.contains("secret"))
    }
}

@Test func assrtBusinessErrorPrecedesResultDecoding() async throws {
    let provider = try AssrtProvider(token: String(repeating: "a", count: 32), transport: APIStub([#"{"status":1,"sub":"invalid result"}"#]), limiter: AssrtRateLimiter(interval: .zero))
    await #expect(throws: SourceAPIError.self) { try await provider.search(.init(video: URL(fileURLWithPath: "/tmp/Movie.mkv"))) }
}
