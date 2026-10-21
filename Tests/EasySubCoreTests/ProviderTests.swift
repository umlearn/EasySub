import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import EasySubCore
#endif

private struct ProviderFiles {
    let directory: URL
    let video: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        video = directory.appendingPathComponent("video.mkv")
        try Data(repeating: 0, count: 16384).write(to: video)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func output(_ format: SubtitleFormat) -> URL { video.deletingPathExtension().appendingPathExtension(format.rawValue) }
}

private let assData = Data("[Script Info]\nScriptType: v4.00+\n[Events]\nDialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Hello\n".utf8)
private let srtData = Data("1\n00:00:01,000 --> 00:00:02,000\nHello\n".utf8)

@Test func subtitleLanguageLabelsUseChineseForChineseAndAppLocaleForOthers() {
    let english = Locale(identifier: "en")
    let chinese = Locale(identifier: "zh-Hans")
    #expect(SubtitleLanguageCatalog.displayName(for: "zh-cn", in: english) == "简体中文")
    #expect(SubtitleLanguageCatalog.displayName(for: "zh-tw", in: english) == "繁体中文")
    #expect(SubtitleLanguageCatalog.displayName(for: "ze", in: english) == "双语字幕")
    #expect(SubtitleLanguageCatalog.displayName(for: "en", in: english) == "English")
    #expect(SubtitleLanguageCatalog.displayName(for: "en", in: chinese) == "英语")
    #expect(SubtitleLanguageCatalog.displayLabel(
        for: ["zh-cn", "en", "ze"], in: english
    ) == "简体中文 + 英语 + 双语字幕")
    #expect(SubtitleLanguageCatalog.displayLabel(for: ["en", "ja"], in: english)
            == "English + Japanese")
}

private actor SearchProbe {
    var active = 0
    var peak = 0
    func begin() { active += 1; peak = max(peak, active) }
    func end() { active -= 1 }
}

private actor TestProvider: SubtitleProvider {
    nonisolated let source: SubtitleSource
    let candidates: [SubtitleCandidate]
    let failure: SubtitleError?
    let delay: Duration
    let probe: SearchProbe?
    let payloads: [String: Data]
    let brokenReferences: Set<String>
    private(set) var searches = 0
    private(set) var downloads: [String] = []
    private(set) var cancellations = 0

    init(_ id: String, formats: [SubtitleFormat] = [.ass], failure: SubtitleError? = nil,
         delay: Duration = .zero, probe: SearchProbe? = nil,
         candidates: [SubtitleCandidate]? = nil, payloads: [String: Data] = [:],
         brokenReferences: Set<String> = []) {
        let source = SubtitleSource(id: id, name: id)
        self.source = source
        self.candidates = candidates ?? formats.map {
            SubtitleCandidate(source: source, reference: "id-\($0.rawValue)", title: "Subtitle", format: $0,
                              delayMilliseconds: 0)
        }
        self.failure = failure; self.delay = delay; self.probe = probe
        self.payloads = payloads; self.brokenReferences = brokenReferences
    }
    func search(_ request: SubtitleSearchRequest) async throws -> [SubtitleCandidate] {
        searches += 1
        await probe?.begin()
        do {
            try await Task.sleep(for: delay)
            if let failure { throw failure }
            await probe?.end()
            return candidates
        } catch {
            if error is CancellationError { cancellations += 1 }
            await probe?.end()
            throw error
        }
    }
    func download(_ candidate: SubtitleCandidate) async throws -> Data {
        downloads.append(candidate.reference)
        if brokenReferences.contains(candidate.reference) { throw SubtitleError.http(503) }
        return payloads[candidate.reference] ?? (candidate.format == .ass ? assData : srtData)
    }
}

@Test func registryRejectsEmptyAndDuplicateSourceIDs() throws {
    #expect(throws: SubtitleProviderError.self) { try MultiSourceSubtitleService(providers: []) }
    #expect(throws: SubtitleProviderError.self) {
        try MultiSourceSubtitleService(providers: [TestProvider("same"), TestProvider("same")])
    }
}

@Test func searchIsReadOnlyAndDeduplicatesWithinSourceOnly() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "first", name: "first")
    let candidate = SubtitleCandidate(source: source, reference: "id-ass", title: "A", format: .ass, delayMilliseconds: 0)
    let first = TestProvider("first", candidates: [candidate, candidate])
    let second = TestProvider("second")
    let service = try MultiSourceSubtitleService(providers: [first, second])
    let report = try await service.search(SubtitleSearchRequest(video: files.video))
    #expect(report.candidates.count == 2)
    #expect(report.candidates.map(\.source.id) == ["first", "second"])
    #expect(await first.downloads.isEmpty)
    #expect(await second.downloads.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: files.output(.ass).path))
}

@Test func sourceSearchFailureDoesNotDiscardHealthyResults() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let broken = TestProvider("broken", failure: .http(503))
    let healthy = TestProvider("healthy")
    let service = try MultiSourceSubtitleService(providers: [broken, healthy])
    let result = try await service.download(video: files.video, preference: .ass, overwrite: false)
    #expect(result.saved == [files.output(.ass)])
    #expect(result.warnings.isEmpty)
    #expect(result.sourceFailures.map(\.source.id) == ["broken"])
    #expect(await broken.downloads.isEmpty)
    #expect(await healthy.downloads == ["id-ass"])
}

@Test func failedDownloadFallsBackToSameFormatFromNextSource() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let broken = TestProvider("broken", formats: [.ass, .srt], brokenReferences: ["id-ass"])
    let healthy = TestProvider("healthy", formats: [.ass])
    let service = try MultiSourceSubtitleService(providers: [broken, healthy])
    let result = try await service.download(video: files.video, preference: .ass, overwrite: false)
    #expect(result.saved == [files.output(.ass)])
    #expect(await broken.downloads == ["id-ass"])
    #expect(await healthy.downloads == ["id-ass"])
}

@Test func formatPreferencePrecedesProviderOrder() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let first = TestProvider("first", formats: [.srt])
    let second = TestProvider("second", formats: [.ass])
    let service = try MultiSourceSubtitleService(providers: [first, second])
    let result = try await service.download(video: files.video, preference: .ass, overwrite: false)
    #expect(result.saved == [files.output(.ass)])
    #expect(await first.downloads.isEmpty)
    #expect(await second.downloads == ["id-ass"])
}

@Test func bothCanCombineDifferentSources() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let service = try MultiSourceSubtitleService(providers: [TestProvider("ass", formats: [.ass]), TestProvider("srt", formats: [.srt])])
    let result = try await service.download(video: files.video, preference: .both, overwrite: false)
    #expect(result.saved == [files.output(.ass), files.output(.srt)])
    #expect(result.warnings.isEmpty)
    #expect(try Data(contentsOf: files.output(.ass)) == assData)
    #expect(try Data(contentsOf: files.output(.srt)) == srtData)
}

@Test func duplicateCandidateIsNotDownloadedTwiceOnFailure() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "source", name: "source")
    let candidate = SubtitleCandidate(source: source, reference: "bad", title: "Bad", format: .ass, delayMilliseconds: 0)
    let provider = TestProvider("source", candidates: [candidate, candidate], brokenReferences: ["bad"])
    let service = MultiSourceSubtitleService(provider: provider)
    await #expect(throws: SubtitleError.self) {
        try await service.download(video: files.video, preference: .ass, overwrite: false)
    }
    #expect(await provider.downloads == ["bad"])
}

@Test func allSourcesForOneVideoSearchConcurrentlyAndOrderIsDeterministic() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let probe = SearchProbe()
    let providers = (0..<5).map { TestProvider("\($0)", delay: .milliseconds($0 == 0 ? 100 : 20), probe: probe) }
    let coordinator = try SubtitleSearchCoordinator(providers: providers)
    let result = try await coordinator.search(SubtitleSearchRequest(video: files.video))
    #expect(await probe.peak == 5)
    #expect(result.candidates.map(\.source.id) == ["0", "1", "2", "3", "4"])
}

@Test func searchesAcrossVideosRespectGlobalConcurrencyLimit() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let probe = SearchProbe()
    let limiter = SubtitleSearchLimiter(limit: 8)
    let providers = (0..<4).map { TestProvider("\($0)", delay: .milliseconds(50), probe: probe) }
    let coordinator = try SubtitleSearchCoordinator(providers: providers, searchLimiter: limiter)

    try await withThrowingTaskGroup(of: Void.self) { group in
        for _ in 0..<3 {
            group.addTask {
                _ = try await coordinator.search(SubtitleSearchRequest(video: files.video))
            }
        }
        try await group.waitForAll()
    }

    #expect(await probe.peak == 8)
}

@Test func foreignCandidateCannotBeRoutedToAnotherProvider() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let healthy = TestProvider("healthy")
    let foreign = SubtitleCandidate(source: healthy.source, reference: "injected", title: "Invalid", format: .ass, delayMilliseconds: 0)
    let bad = TestProvider("bad", candidates: [foreign])
    let service = try MultiSourceSubtitleService(providers: [bad, healthy])
    let result = try await service.download(video: files.video, preference: .ass, overwrite: false)
    #expect(result.sourceFailures.map(\.source.id) == ["bad"])
    #expect(await bad.downloads.isEmpty)
    #expect(await healthy.downloads == ["id-ass"])
}

@Test func existingPreferredFileSkipsAllProviders() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    try assData.write(to: files.output(.ass))
    let first = TestProvider("first")
    let second = TestProvider("second")
    let service = try MultiSourceSubtitleService(providers: [first, second])
    let result = try await service.download(video: files.video, preference: .ass, overwrite: false)
    #expect(result.existing == [files.output(.ass)])
    #expect(await first.searches == 0)
    #expect(await second.searches == 0)
}

@Test func allFailedSourcesPreserveIndividualDiagnostics() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let service = try MultiSourceSubtitleService(providers: [TestProvider("one", failure: .http(503)), TestProvider("two", failure: .invalidResponse)])
    do {
        _ = try await service.download(video: files.video, preference: .ass, overwrite: false)
        Issue.record("Expected source failure")
    } catch SubtitleProviderError.allSourcesFailed(let failures) {
        #expect(failures.map(\.source.id) == ["one", "two"])
    }
    #expect(!FileManager.default.fileExists(atPath: files.output(.ass).path))
}

@Test func unrelatedUnknownDelayCandidatesAreNotAutoSelected() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "source", name: "source")
    let candidates = [nil, 50].map {
        SubtitleCandidate(source: source, reference: "\(String(describing: $0))", title: "Unknown", format: .ass, delayMilliseconds: $0)
    }
    let provider = TestProvider("source", candidates: candidates)
    let service = MultiSourceSubtitleService(provider: provider)
    let search = try await service.search(SubtitleSearchRequest(video: files.video))
    #expect(search.candidates.count == 2)
    await #expect(throws: SubtitleError.self) {
        try await service.download(video: files.video, preference: .ass, overwrite: false)
    }
    #expect(await provider.downloads.isEmpty)
}

@Test func matchingUnknownDelayCandidateIsAutoDownloaded() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "filename", name: "filename")
    let candidate = SubtitleCandidate(source: source, reference: "match", title: "The.Matrix.1999.zh.srt",
                                      format: .srt, languageCodes: ["zh"], delayMilliseconds: nil)
    let provider = TestProvider("filename", candidates: [candidate], payloads: ["match": srtData])
    let video = files.directory.appendingPathComponent("The.Matrix.1999.1080p.mkv")
    try Data(repeating: 0, count: 16384).write(to: video)
    let result = try await MultiSourceSubtitleService(provider: provider)
        .download(video: video, preference: .srt, overwrite: false)
    #expect(result.saved == [video.deletingPathExtension().appendingPathExtension("srt")])
    #expect(result.selections.map(\.reference) == ["match"])
    #expect(await provider.downloads == ["match"])
}

@Test func sourceFilenameIsPreservedWhenRenamingIsDisabled() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "filename", name: "filename")
    let candidate = SubtitleCandidate(source: source, reference: "match",
                                      title: "video.CHS.srt", format: .srt)
    let provider = TestProvider("filename", candidates: [candidate], payloads: ["match": srtData])
    let service = MultiSourceSubtitleService(provider: provider)
    let result = try await service.download(video: files.video, preference: .srt, overwrite: false,
                                            renameSubtitle: false)
    let expected = files.directory.appendingPathComponent("video.CHS.srt")
    #expect(result.saved == [expected])
    #expect(FileManager.default.fileExists(atPath: expected.path))
}

@Test func customOutputDirectoryIsUsedForAutomaticDownloads() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let outputDirectory = files.directory.appendingPathComponent("Subtitles", isDirectory: true)
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let source = SubtitleSource(id: "filename", name: "filename")
    let candidate = SubtitleCandidate(source: source, reference: "match",
                                      title: "video.zh.srt", format: .srt)
    let provider = TestProvider("filename", candidates: [candidate], payloads: ["match": srtData])
    let service = MultiSourceSubtitleService(provider: provider)

    let result = try await service.download(video: files.video, preference: .srt, overwrite: false,
                                            renameSubtitle: true, outputDirectory: outputDirectory)

    let expected = outputDirectory.appendingPathComponent("video.srt")
    #expect(result.saved == [expected])
    #expect(FileManager.default.fileExists(atPath: expected.path))
    #expect(!FileManager.default.fileExists(atPath: files.output(.srt).path))
}

@Test func replacementOnlyTouchesTheResolvedFilename() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "filename", name: "filename")
    let candidate = SubtitleCandidate(source: source, reference: "match",
                                      title: "video.Downloaded.srt", format: .srt)
    let provider = TestProvider("filename", candidates: [candidate], payloads: ["match": srtData])
    let service = MultiSourceSubtitleService(provider: provider)
    let unrelated = files.directory.appendingPathComponent("Other.Name.srt")
    let target = files.directory.appendingPathComponent("video.Downloaded.srt")
    try Data("unrelated".utf8).write(to: unrelated)
    try Data("old".utf8).write(to: target)

    let result = try await service.download(video: files.video, preference: .srt, overwrite: true,
                                            renameSubtitle: false)

    #expect(result.saved == [target])
    #expect(try Data(contentsOf: target) == srtData)
    #expect(try Data(contentsOf: unrelated) == Data("unrelated".utf8))
}

@Test func automaticMatchingRejectsWrongYearAndEpisode() async throws {
    let source = SubtitleSource(id: "filename", name: "filename")
    let candidates = [
        SubtitleCandidate(source: source, reference: "wrong-year", title: "Dune.1984.zh.srt", format: .srt),
        SubtitleCandidate(source: source, reference: "wrong-episode", title: "Show.S02E04.zh.srt", format: .srt),
        SubtitleCandidate(source: source, reference: "right", title: "Show.S02E03.1080p.zh.srt", format: .srt)
    ]
    let rankedMovie = SubtitleMatcher.rank(candidates, for: URL(fileURLWithPath: "/tmp/Dune.2021.mkv"))
    #expect(rankedMovie.allSatisfy { $0.reference != "wrong-year" })
    let rankedEpisode = SubtitleMatcher.rank(candidates, for: URL(fileURLWithPath: "/tmp/Show.S02E03.mkv"))
    #expect(rankedEpisode.map(\.reference) == ["right"])
}

@Test func automaticMatchingPrefersFingerprintThenLanguageAndTitleEvidence() {
    let filenameSource = SubtitleSource(id: "filename", name: "filename")
    let candidates = [
        SubtitleCandidate(source: filenameSource, reference: "plain", title: "The.Matrix.1999.srt", format: .srt),
        SubtitleCandidate(source: filenameSource, reference: "chinese", title: "The.Matrix.1999.CHS.srt", format: .srt,
                          languageCodes: ["zh"]),
        SubtitleCandidate(source: .shooter, reference: "fingerprint", title: "opaque.srt", format: .srt,
                          languageCodes: ["zh"], matchKind: .fingerprint, delayMilliseconds: 0)
    ]
    let ranked = SubtitleMatcher.rank(candidates, for: URL(fileURLWithPath: "/tmp/The.Matrix.1999.mkv"))
    #expect(ranked.map(\.reference) == ["fingerprint", "chinese", "plain"])
}

@Test func automaticMatchingUsesReleaseVersionAsSoftRanking() {
    let source = SubtitleSource(id: "filename", name: "filename")
    let candidates = [
        SubtitleCandidate(source: source, reference: "other", title: "Movie.2024.720p.WEB-DL.x264-OTHER.srt", format: .srt),
        SubtitleCandidate(source: source, reference: "release", title: "Movie.2024.1080p.BluRay.x265-GROUP.srt", format: .srt),
        SubtitleCandidate(source: source, reference: "generic", title: "Movie.2024.zh.srt", format: .srt,
                          languageCodes: ["zh"])
    ]
    let video = URL(fileURLWithPath: "/tmp/Movie.2024.1080p.BluRay.x265-GROUP.mkv")
    #expect(SubtitleMatcher.rank(candidates, for: video).first?.reference == "release")
}

@Test func automaticDownloadPrioritizesLanguageBeforeFormat() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "language", name: "language")
    let candidates = [
        SubtitleCandidate(source: source, reference: "english-ass", title: "video.en.ass",
                          format: .ass, languageCodes: ["en"]),
        SubtitleCandidate(source: source, reference: "chinese-srt", title: "video.zh-cn.srt",
                          format: .srt, languageCodes: ["zh-cn"])
    ]
    let provider = TestProvider("language", candidates: candidates,
                                payloads: ["english-ass": assData, "chinese-srt": srtData])
    let service = MultiSourceSubtitleService(provider: provider, preferredLanguageCodes: ["zh-cn", "en"])
    let result = try await service.download(video: files.video, preference: .ass, overwrite: false)
    #expect(result.selections.map(\.reference) == ["chinese-srt"])
    #expect(result.saved == [files.output(.srt)])
}

@Test func bothFormatsDoNotMixPreferredLanguages() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "language", name: "language")
    let candidates = [
        SubtitleCandidate(source: source, reference: "chinese-srt", title: "video.zh-cn.srt",
                          format: .srt, languageCodes: ["zh-cn"]),
        SubtitleCandidate(source: source, reference: "english-ass", title: "video.en.ass",
                          format: .ass, languageCodes: ["en"])
    ]
    let provider = TestProvider("language", candidates: candidates,
                                payloads: ["english-ass": assData, "chinese-srt": srtData])
    let service = MultiSourceSubtitleService(provider: provider, preferredLanguageCodes: ["zh-cn", "en"])
    let result = try await service.download(video: files.video, preference: .both, overwrite: false)
    #expect(result.selections.map(\.reference) == ["chinese-srt"])
    #expect(result.saved == [files.output(.srt)])
    #expect(result.warnings.count == 1)
}

@Test func manualSelectionKeepsOtherLanguagesAfterPreferredResults() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "language", name: "language")
    let candidates = [
        SubtitleCandidate(source: source, reference: "english", title: "video.en.srt",
                          format: .srt, languageCodes: ["en"]),
        SubtitleCandidate(source: source, reference: "chinese", title: "video.zh-cn.srt",
                          format: .srt, languageCodes: ["zh-cn"])
    ]
    let service = MultiSourceSubtitleService(provider: TestProvider("language", candidates: candidates),
                                             preferredLanguageCodes: ["zh-cn"])
    let result = try await service.searchForSelection(.init(video: files.video))
    #expect(result.candidates.map(\.reference) == ["chinese", "english"])
}

@Test func selectionSearchRanksSafeMatchesButRetainsManualCandidates() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let video = files.directory.appendingPathComponent("Movie.2024.1080p.mkv")
    try Data(repeating: 0, count: 16384).write(to: video)
    let source = SubtitleSource(id: "filename", name: "filename")
    let unsafe = SubtitleCandidate(source: source, reference: "unsafe", title: "Other.2023.srt", format: .srt)
    let safe = SubtitleCandidate(source: source, reference: "safe", title: "Movie.2024.srt", format: .srt)
    let service = MultiSourceSubtitleService(provider: TestProvider("filename", candidates: [unsafe, safe]))
    let report = try await service.searchForSelection(.init(video: video))
    #expect(report.candidates.map(\.reference) == ["safe", "unsafe"])
}

@Test func oversizedPayloadFromProviderIsRejectedBeforeWriting() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let provider = TestProvider("source", payloads: ["id-ass": Data(repeating: 65, count: 8 * 1024 * 1024 + 1)])
    let service = MultiSourceSubtitleService(provider: provider)
    await #expect(throws: SubtitleError.self) {
        try await service.download(video: files.video, preference: .ass, overwrite: false)
    }
    #expect(!FileManager.default.fileExists(atPath: files.output(.ass).path))
}

@Test func cancellationStopsActiveAndQueuedProviderSearches() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let first = TestProvider("first", delay: .seconds(10))
    let second = TestProvider("second", delay: .seconds(10))
    let third = TestProvider("third", delay: .seconds(10))
    let service = try MultiSourceSubtitleService(providers: [first, second, third])
    let task = Task { try await service.download(video: files.video, preference: .ass, overwrite: false) }
    // Wait for a concrete start signal, with a bounded wait, rather than cancelling by timing luck.
    for _ in 0..<200 {
        if await first.searches == 1, await second.searches == 1, await third.searches == 1 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await first.cancellations == 1)
    #expect(await second.cancellations == 1)
    #expect(await third.cancellations == 1)
    #expect(await first.downloads.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: files.output(.ass).path))
}
