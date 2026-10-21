import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import EasySubCore
#endif

private struct Fixture {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func video(_ name: String = "sample.mkv", size: Int = 16384) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0, count: size).write(to: url)
        return url
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

private actor StubTransport: HTTPTransport {
    enum Reply: Sendable { case data(Data), failure(SubtitleError) }
    let replies: [String: Reply]
    var requests: [URLRequest] = []
    init(_ replies: [String: Reply]) { self.replies = replies }
    func fetch(_ request: URLRequest, limit: Int) async throws -> Data {
        requests.append(request)
        switch replies[request.url!.path] ?? .failure(.http(404)) {
        case .data(let data): return data
        case .failure(let error): throw error
        }
    }
}

private func metadata(_ files: [(String, String)], delay: Int = 0) throws -> Data {
    try JSONSerialization.data(withJSONObject: [["Delay": delay, "Files": files.map { ["Ext": $0.0, "Link": $0.1] }]])
}
private let assSubtitle = Data("[Script Info]\nScriptType: v4.00+\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello\n".utf8)
private let subtitle = Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8)

@Test func fingerprintMatchesLegacyProtocol() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video()
    let expected = Array(repeating: "620f0b67a91f7f74151bc5be745b7110", count: 4).joined(separator: ";")
    #expect(try VideoHasher.hash(video) == expected)
}

@Test func smallVideoFailsWithoutUnsignedUnderflow() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video(size: 100)
    #expect(throws: SubtitleError.self) { try VideoHasher.hash(video) }
}

@Test func boundaryVideoUsesShortFinalRead() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video(size: 8192)
    #expect(try VideoHasher.hash(video).split(separator: ";").count == 4)
}

@Test func scannerDeduplicatesAndIgnoresSymlinkLoops() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video("MOVIE.MKV")
    _ = try fixture.video("notes.txt")
    let nested = fixture.directory.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: nested.appendingPathComponent("loop"), withDestinationURL: fixture.directory)
    let scan = await VideoScanner().scan([fixture.directory, video])
    #expect(scan.videos.count == 1)
    #expect(scan.videos.first?.url == video.resolvingSymlinksInPath())
    #expect(scan.failures.isEmpty)
}

@Test func assPreferenceDownloadsOnlyOnceAndOmitsDirectory() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video("中文 & sample.mkv")
    let transport = StubTransport([
        "/api/subapi.php": .data(try metadata([("ass", "https://example.com/a"), ("srt", "https://example.com/s")])),
        "/a": .data(assSubtitle), "/s": .data(subtitle)
    ])
    let result = try await ShooterService(transport: transport).download(video: video, preference: .ass, overwrite: false)
    #expect(result.saved.count == 1)
    #expect(result.saved.first?.pathExtension == "ass")
    let requests = await transport.requests
    #expect(requests.count == 2)
    let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(query.first { $0.name == "pathinfo" }?.value == video.lastPathComponent)
}

@Test func fallbackAndCandidateFailuresAreHandled() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video()
    let transport = StubTransport([
        "/api/subapi.php": .data(try metadata([("ass", "https://example.com/a"), ("srt", "https://example.com/s")])),
        "/a": .failure(.http(503)), "/s": .data(subtitle)
    ])
    let result = try await ShooterService(transport: transport).download(video: video, preference: .ass, overwrite: false)
    #expect(result.saved.first?.pathExtension == "srt")
    #expect(result.warnings.isEmpty)
}

@Test func bothFormatsDownloadedExactlyOnce() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video()
    let transport = StubTransport([
        "/api/subapi.php": .data(try metadata([("ASS", "https://example.com/a"), ("srt", "https://example.com/s")])),
        "/a": .data(assSubtitle), "/s": .data(subtitle)
    ])
    let result = try await ShooterService(transport: transport).download(video: video, preference: .both, overwrite: false)
    #expect(result.saved.count == 2)
    #expect(await transport.requests.count == 3)
}

@Test func bothReportsPartialSuccess() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video()
    let transport = StubTransport([
        "/api/subapi.php": .data(try metadata([("ass", "https://example.com/a")])), "/a": .data(assSubtitle)
    ])
    let result = try await ShooterService(transport: transport).download(video: video, preference: .both, overwrite: false)
    #expect(result.saved.count == 1)
    #expect(result.warnings.count == 1)
}

@Test func existingPreferredSubtitleSkipsNetwork() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video()
    let destination = video.deletingPathExtension().appendingPathExtension("ass")
    let original = Data("Do not overwrite".utf8)
    try original.write(to: destination)
    let transport = StubTransport([:])
    let result = try await ShooterService(transport: transport).download(video: video, preference: .ass, overwrite: false)
    #expect(result.existing == [destination])
    #expect(await transport.requests.isEmpty)
    #expect(try Data(contentsOf: destination) == original)
}

@Test func saveDoesNotOverwriteARacingFile() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let destination = try fixture.video("existing.srt", size: 20)
    #expect(throws: (any Error).self) { try SubtitleFileWriter.save(subtitle, to: destination, overwrite: false) }
    #expect(try Data(contentsOf: destination) == Data(repeating: 0, count: 20))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count == 1)
    try SubtitleFileWriter.save(subtitle, to: destination, overwrite: true)
    #expect(try Data(contentsOf: destination) == subtitle)
}

@Test(arguments: [Data([0xff]), Data("-1".utf8), Data(), Data("[]".utf8)])
func noMatchResponsesAreHandled(_ data: Data) async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let transport = StubTransport(["/api/subapi.php": .data(data)])
    let video = try fixture.video()
    await #expect(throws: SubtitleError.self) {
        try await ShooterService(transport: transport).download(video: video, preference: .ass, overwrite: false)
    }
}

@Test func delayedMatchesAreIgnored() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let transport = StubTransport(["/api/subapi.php": .data(try metadata([("srt", "https://example.com/s")], delay: 10))])
    let video = try fixture.video()
    await #expect(throws: SubtitleError.self) {
        try await ShooterService(transport: transport).download(video: video, preference: .srt, overwrite: false)
    }
    #expect(await transport.requests.count == 1)
}

@Test(arguments: [Data("<html>Service unavailable</html>".utf8), Data()])
func invalidSubtitleIsNotWritten(_ data: Data) async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let transport = StubTransport(["/api/subapi.php": .data(try metadata([("srt", "https://example.com/s")])), "/s": .data(data)])
    let video = try fixture.video()
    await #expect(throws: SubtitleError.self) {
        try await ShooterService(transport: transport).download(video: video, preference: .srt, overwrite: false)
    }
    #expect(!FileManager.default.fileExists(atPath: video.deletingPathExtension().appendingPathExtension("srt").path))
}

@Test func insecureSubtitleLinksAreRejected() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let transport = StubTransport(["/api/subapi.php": .data(try metadata([("srt", "http://example.com/s")]))])
    let video = try fixture.video()
    await #expect(throws: SubtitleError.self) {
        try await ShooterService(transport: transport).download(video: video, preference: .srt, overwrite: false)
    }
    #expect(await transport.requests.count == 1)
}

private actor SlowDownloader: SubtitleDownloading {
    var active = 0
    var peak = 0
    var calls = 0
    func download(video: URL, preference: SubtitlePreference, overwrite: Bool,
                  renameSubtitle: Bool, outputDirectory: URL?) async throws -> DownloadResult {
        active += 1; calls += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(80))
        return DownloadResult(saved: [video.appendingPathExtension("ass")])
    }
}

@MainActor @Test func queueBoundsConcurrencyAndPreventsRepeatedStart() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let urls = try (0..<5).map { try fixture.video("\($0).mkv") }
    let service = SlowDownloader()
    let store = DownloadStore(service: service)
    await store.add(urls)
    await store.add(urls)
    #expect(store.items.count == 5)
    store.start(preference: .ass, overwrite: false)
    store.start(preference: .srt, overwrite: true)
    store.remove(Set(urls))
    #expect(store.items.count == 5)
    while store.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(await service.calls == 5)
    #expect(await service.peak == 2)
    #expect(store.batchFinished == 5)
    #expect(store.successCount == 5)
    #expect(store.completionCount == 1)
}

@MainActor @Test func cancellationMarksUnstartedVideosAndSupportsRetry() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let urls = try (0..<5).map { try fixture.video("\($0).mkv") }
    let service = SlowDownloader()
    let store = DownloadStore(service: service)
    await store.add(urls)
    store.start(preference: .ass, overwrite: false)
    store.cancel()
    while store.isRunning { try await Task.sleep(for: .milliseconds(10)) }
    #expect(store.items.allSatisfy { $0.status == .cancelled })
    #expect(store.pendingCount == 5)
    store.start(preference: .ass, overwrite: false)
    while store.isRunning { try await Task.sleep(for: .milliseconds(20)) }
    #expect(store.successCount == 5)
}

@MainActor @Test func clearAllRemovesEveryVideoFromTheQueue() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let urls = try (0..<3).map { try fixture.video("\($0).mkv") }
    let store = DownloadStore(service: SlowDownloader())
    await store.add(urls)
    #expect(store.items.count == 3)
    store.clearAll()
    #expect(store.items.isEmpty)
}

@MainActor @Test func markingPendingAndCompletedUpdatesCountsAndRetryAvailability() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let urls = try (0..<3).map { try fixture.video("\($0).mkv") }
    let store = DownloadStore(service: SlowDownloader())
    await store.add(urls)

    store.mark([urls[0]], as: .completed)

    #expect(store.successCount == 1)
    #expect(store.failureCount == 0)
    #expect(store.pendingCount == 2)
    #expect(store.items.first { $0.id == urls[0] }?.status == .completed)

    store.mark([urls[0]], as: .ready)
    #expect(store.successCount == 0)
    #expect(store.pendingCount == 3)
}

@MainActor @Test func manualDownloadsAccumulateInQueueDetails() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video()
    let store = DownloadStore(service: SlowDownloader())
    await store.add([video])
    let source = SubtitleSource(id: "manual", name: "Manual")
    let first = SubtitleCandidate(source: source, reference: "one", title: "One", format: .srt)
    let second = SubtitleCandidate(source: source, reference: "two", title: "Two", format: .srt)
    let firstOutput = video.deletingPathExtension().appendingPathExtension("srt")
    let secondOutput = video.deletingPathExtension().appendingPathExtension("1.srt")
    store.recordManualDownload(video: video, output: firstOutput, candidate: first)
    store.recordManualDownload(video: video, output: secondOutput, candidate: second)
    #expect(store.items.first?.output == [firstOutput, secondOutput])
    #expect(store.items.first?.selectedCandidates.map(\.id) == [first.id, second.id])
    #expect(store.items.first?.downloadedCandidates == [first.id: firstOutput, second.id: secondOutput])
}

@MainActor @Test func replacingManualDownloadTransfersDownloadedState() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video()
    let store = DownloadStore(service: SlowDownloader())
    await store.add([video])
    let source = SubtitleSource(id: "manual", name: "Manual")
    let first = SubtitleCandidate(source: source, reference: "one", title: "One", format: .srt)
    let replacement = SubtitleCandidate(source: source, reference: "two", title: "Two", format: .srt)
    let output = video.deletingPathExtension().appendingPathExtension("srt")

    store.recordManualDownload(video: video, output: output, candidate: first)
    store.recordManualDownload(video: video, output: output, candidate: replacement)

    #expect(store.items.first?.selectedCandidates.map(\.id) == [replacement.id])
    #expect(store.items.first?.downloadedCandidates == [replacement.id: output])
}

@Test func fingerprintUsesLegacyIntegerDivisionOffsets() throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video()
    var bytes = [UInt8]()
    bytes.reserveCapacity(20_003)
    for index in 0..<20_003 {
        let mixedValue = index * 17 + index / 251
        bytes.append(UInt8(mixedValue % 256))
    }
    let data = Data(bytes)
    try data.write(to: video)
    #expect(try VideoHasher.hash(video) == "881f47336edb905d37e28cc140815984;d44a1eb9fd0d03f66a9b39faa0403399;2176d03405642cc0a44c123800dfd205;3c96c487030a0a37bcaddb97019a47f0")
}

@Test func malformedServiceResponseIsReported() async throws {
    let fixture = try Fixture(); defer { fixture.cleanup() }
    let video = try fixture.video()
    let transport = StubTransport(["/api/subapi.php": .data(Data("<html>Maintenance</html>".utf8))])
    await #expect(throws: SubtitleError.self) {
        try await ShooterService(transport: transport).download(video: video, preference: .ass, overwrite: false)
    }
}
