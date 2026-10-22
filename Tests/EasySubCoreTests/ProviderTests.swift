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
private let chineseSRTData = Data("1\n00:00:01,000 --> 00:00:03,000\n这是用于确认字幕语言的中文对白内容。\n2\n00:00:04,000 --> 00:00:07,000\n我们需要确保自动下载选择正确的中文字幕。\n".utf8)
private let englishSRTData = Data("1\n00:00:01,000 --> 00:00:03,000\nThis subtitle contains enough English dialogue to identify its language.\n2\n00:00:04,000 --> 00:00:07,000\nIt should be rejected when Chinese was inferred only from the source.\n".utf8)
private let simplifiedSRTData = Data("1\n00:00:01,000 --> 00:00:03,000\n这个视频已经发布，我们发现里面还有很多问题，需要继续处理。\n2\n00:00:04,000 --> 00:00:07,000\n请打开设置选择正确语言，然后重新下载字幕文件。\n".utf8)
private let traditionalSRTData = Data("1\n00:00:01,000 --> 00:00:03,000\n這個影片已經發佈，我們發現裡面還有很多問題，需要繼續處理。\n2\n00:00:04,000 --> 00:00:07,000\n請開啟設定選擇正確語言，然後重新下載字幕檔案。\n".utf8)

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
    #expect(SubtitleLanguageCatalog.displayLabel(for: ["zh", "en", "ze"], in: chinese)
            == "中文 + 英语 + 双语字幕")
}

@Test func subtitleFilenameLanguagesRecognizeAliasesCombinationsAndAccessibilitySuffixes() {
    let cases: [(String, Set<String>)] = [
        ("Fre.srt", ["fr"]), ("Ger.srt", ["de"]), ("Jpn.srt", ["ja"]),
        ("Movie.HK.ass", ["zh-tw"]), ("Movie.CHT_CHS.srt", ["zh-cn", "zh-tw"]),
        ("Movie.CHS&ENG.ass", ["zh-cn", "en", "ze"]),
        ("Movie.WEB-DLChs.srt", ["zh-cn"]),
        ("Movie.WEB-DLChsEng.ass", ["zh-cn", "en", "ze"]),
        ("Movie.WEB-DLCHTENG.srt", ["zh-tw", "en", "ze"]),
        ("Movie.zh-CN.srt", ["zh-cn"]), ("Movie.zh_Hant.srt", ["zh-tw"]),
        ("Movie.zhCN.srt", ["zh-cn"]), ("Movie.zh.srt", ["zh"]),
        ("Movie.cn.srt", ["zh-cn"]),
        ("蜘蛛侠.中英字幕.ass", ["zh", "en", "ze"]),
        ("Movie.en.forced.srt", ["en"]),
        ("Movie.SDH.srt", []), ("Movie.HI.srt", []), ("Movie.CC.srt", [])
    ]
    for (filename, expected) in cases {
        #expect(SubtitleLanguageNormalizer.codes(fromFileName: filename) == expected)
    }
}

@Test func chineseSourcePriorOnlyAppliesWhenLanguageIsUnknown() {
    let assrt = SubtitleSource(id: "assrt", name: "ASSRT")
    let unknown = SubtitleCandidate(source: assrt, reference: "unknown", title: "Movie.srt", format: .srt)
    let english = SubtitleCandidate(source: assrt, reference: "english", title: "Movie.Eng.srt",
                                    format: .srt, languageCodes: ["en"])
    #expect(SubtitleLanguageCatalog.preferenceMatch(for: unknown, in: ["zh-cn"])?.confidence == 2)
    #expect(SubtitleLanguageCatalog.preferenceMatch(for: english, in: ["zh-cn"]) == nil)
}

@Test func chineseSourcePriorRanksAfterExplicitChineseAndRejectsExplicitEnglish() {
    let assrt = SubtitleSource(id: "assrt", name: "ASSRT")
    let other = SubtitleSource(id: "other", name: "Other")
    let candidates = [
        SubtitleCandidate(source: assrt, reference: "english", title: "Movie.Eng.srt",
                          format: .srt, languageCodes: ["en"]),
        SubtitleCandidate(source: assrt, reference: "source-prior", title: "Movie.srt", format: .srt),
        SubtitleCandidate(source: other, reference: "explicit", title: "Movie.Chs.srt",
                          format: .srt, languageCodes: ["zh-cn"]),
        SubtitleCandidate(source: other, reference: "unknown", title: "Movie.srt", format: .srt)
    ]
    let ranked = SubtitleMatcher.rank(candidates, forName: "Movie", preferredLanguageCodes: ["zh-cn"],
                                      requirePreferredLanguage: true)
    #expect(ranked.map(\.reference) == ["explicit", "source-prior"])
}

@Test func inferredChineseContentDetectionIsConservative() {
    #expect(SubtitleFileWriter.likelyContainsChineseDialogue(chineseSRTData, format: .srt) == true)
    #expect(SubtitleFileWriter.likelyContainsChineseDialogue(englishSRTData, format: .srt) == false)
    #expect(SubtitleFileWriter.likelyContainsChineseDialogue(srtData, format: .srt) == nil)
    let chineseASS = Data("[Script Info]\nTitle: English metadata\n[Events]\nDialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,{\\i1}这是中文字幕正文，应该能够被正确识别。{\\i0}\n".utf8)
    #expect(SubtitleFileWriter.likelyContainsChineseDialogue(chineseASS, format: .ass) == true)
}

@Test func chineseDialogueScriptDistinguishesSimplifiedTraditionalAndNeutralText() {
    #expect(SubtitleFileWriter.chineseDialogueScript(simplifiedSRTData, format: .srt) == .simplified)
    #expect(SubtitleFileWriter.chineseDialogueScript(traditionalSRTData, format: .srt) == .traditional)
    #expect(SubtitleFileWriter.chineseDialogueScript(chineseSRTData, format: .srt) == .simplified)
    #expect(SubtitleFileWriter.chineseDialogueScript(englishSRTData, format: .srt) == .nonChinese)
    #expect(SubtitleFileWriter.chineseDialogueScript(srtData, format: .srt) == .inconclusive)
}

@Test func automaticDownloadRejectsWrongInferredLanguageAndFallsBack() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "assrt", name: "assrt")
    let candidates = [
        SubtitleCandidate(source: source, reference: "english", title: "video.srt", format: .srt),
        SubtitleCandidate(source: source, reference: "chinese", title: "video.srt", format: .srt)
    ]
    let provider = TestProvider("assrt", candidates: candidates,
                                payloads: ["english": englishSRTData, "chinese": chineseSRTData])
    let service = MultiSourceSubtitleService(provider: provider, preferredLanguageCodes: ["zh-cn"])
    let result = try await service.download(video: files.video, preference: .srt, overwrite: false)
    #expect(await provider.downloads == ["english", "chinese"])
    #expect(result.selections.map(\.reference) == ["chinese"])
    #expect(try Data(contentsOf: files.output(.srt)) == chineseSRTData)
}

@Test func automaticDownloadRejectsTraditionalContentMislabeledAsSimplified() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "metadata", name: "metadata")
    let candidates = [
        SubtitleCandidate(source: source, reference: "wrong", title: "video.chs.srt",
                          format: .srt, languageCodes: ["zh-cn"]),
        SubtitleCandidate(source: source, reference: "correct", title: "video.chs.srt",
                          format: .srt, languageCodes: ["zh-cn"])
    ]
    let provider = TestProvider("metadata", candidates: candidates,
                                payloads: ["wrong": traditionalSRTData, "correct": simplifiedSRTData])
    let service = MultiSourceSubtitleService(provider: provider, preferredLanguageCodes: ["zh-cn"])
    let result = try await service.download(video: files.video, preference: .srt, overwrite: false)
    #expect(await provider.downloads == ["wrong", "correct"])
    #expect(result.selections.map(\.reference) == ["correct"])
    #expect(try Data(contentsOf: files.output(.srt)) == simplifiedSRTData)
}

@Test func automaticDownloadRejectsSimplifiedContentMislabeledAsTraditional() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let source = SubtitleSource(id: "metadata", name: "metadata")
    let candidates = [
        SubtitleCandidate(source: source, reference: "wrong", title: "video.cht.srt",
                          format: .srt, languageCodes: ["zh-tw"]),
        SubtitleCandidate(source: source, reference: "correct", title: "video.cht.srt",
                          format: .srt, languageCodes: ["zh-tw"])
    ]
    let provider = TestProvider("metadata", candidates: candidates,
                                payloads: ["wrong": simplifiedSRTData, "correct": traditionalSRTData])
    let service = MultiSourceSubtitleService(provider: provider, preferredLanguageCodes: ["zh-tw"])
    let result = try await service.download(video: files.video, preference: .srt, overwrite: false)
    #expect(await provider.downloads == ["wrong", "correct"])
    #expect(result.selections.map(\.reference) == ["correct"])
    #expect(try Data(contentsOf: files.output(.srt)) == traditionalSRTData)
}

@Test func subtitleFilenameLanguagesDoNotMatchCodesInsideTitles() {
    for filename in ["Frozen.srt", "Golden.ass", "It.2017.srt", "No.2026.srt"] {
        #expect(SubtitleLanguageNormalizer.codes(fromFileName: filename).isEmpty)
    }
}

@Test func exactPreferredLanguageRanksAheadOfGenericChinese() {
    let source = SubtitleSource(id: "language", name: "language")
    let candidates = [
        SubtitleCandidate(source: source, reference: "generic", title: "Movie.zh.srt",
                          format: .srt, languageCodes: ["zh"]),
        SubtitleCandidate(source: source, reference: "simplified", title: "Movie.chs.srt",
                          format: .srt, languageCodes: ["zh-cn"])
    ]
    let ranked = SubtitleMatcher.rank(candidates, forName: "Movie", preferredLanguageCodes: ["zh-cn"],
                                      requirePreferredLanguage: true)
    #expect(ranked.map(\.reference) == ["simplified", "generic"])
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

@Test func seriesEpisodesPreferTheFirstSuccessfulSourceAndFormat() async throws {
    let files = try ProviderFiles(); defer { files.cleanup() }
    let episode1 = files.directory.appendingPathComponent("Example.Show.S01E01.mkv")
    let episode2 = files.directory.appendingPathComponent("Example.Show.S01E02.mkv")
    try Data(repeating: 0, count: 16384).write(to: episode1)
    try Data(repeating: 0, count: 16384).write(to: episode2)

    let sourceA = SubtitleSource(id: "a", name: "a")
    let sourceB = SubtitleSource(id: "b", name: "b")
    let providerA = TestProvider("a", candidates: [
        SubtitleCandidate(source: sourceA, reference: "a1", title: "Example.Show.S01E01.ass",
                          format: .ass, providerScore: 20),
        SubtitleCandidate(source: sourceA, reference: "a2-srt", title: "Example.Show.S01E02.srt",
                          format: .srt, providerScore: -20),
        SubtitleCandidate(source: sourceA, reference: "a2-ass", title: "Example.Show.S01E02.ass",
                          format: .ass, providerScore: 20)
    ])
    let providerB = TestProvider("b", candidates: [
        SubtitleCandidate(source: sourceB, reference: "b2", title: "Example.Show.S01E02.ass",
                          format: .ass, providerScore: 20)
    ])
    let service = try MultiSourceSubtitleService(providers: [providerA, providerB])

    let first = try await service.download(video: episode1, preference: .srt, overwrite: false)
    let second = try await service.download(video: episode2, preference: .srt, overwrite: false)

    #expect(first.selections.first?.source.id == "a")
    #expect(first.selections.first?.format == .ass)
    #expect(second.selections.first?.source.id == "a")
    #expect(second.selections.first?.format == .srt)
}

@Test func seriesKeyGroupsEpisodesByTitleAndSeason() {
    #expect(SubtitleMatcher.seriesKey(for: URL(fileURLWithPath: "/A/Example.Show.S01E01.mkv")) ==
            SubtitleMatcher.seriesKey(for: URL(fileURLWithPath: "/B/Example Show S01E12.mp4")))
    #expect(SubtitleMatcher.seriesKey(for: URL(fileURLWithPath: "/A/Example.Show.S01E01.mkv")) !=
            SubtitleMatcher.seriesKey(for: URL(fileURLWithPath: "/A/Example.Show.S02E01.mkv")))
    #expect(SubtitleMatcher.seriesKey(for: URL(fileURLWithPath: "/A/Movie.2026.mkv")) == nil)
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
