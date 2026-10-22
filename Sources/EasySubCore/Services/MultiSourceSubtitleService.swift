import Foundation

/// Application-facing service. Candidates are ranked across all sources before downloading.
/// Language priority spans all sources before format preference is considered.
public actor MultiSourceSubtitleService: SubtitleDownloading {
    private struct SeriesAffinity: Sendable {
        var sourceByFormat: [SubtitleFormat: String]
        let primarySourceID: String
    }

    private let coordinator: SubtitleSearchCoordinator
    private let preferredLanguageCodes: [String]
    private var seriesAffinities: [String: SeriesAffinity] = [:]

    public init(preferredLanguageCodes: [String] = []) {
        coordinator = SubtitleSearchCoordinator(provider: ShooterProvider())
        self.preferredLanguageCodes = SubtitleLanguageCatalog.normalizedPreferences(preferredLanguageCodes)
    }
    public init(provider: any SubtitleProvider, preferredLanguageCodes: [String] = []) {
        coordinator = SubtitleSearchCoordinator(provider: provider)
        self.preferredLanguageCodes = SubtitleLanguageCatalog.normalizedPreferences(preferredLanguageCodes)
    }
    public init(providers: [any SubtitleProvider], preferredLanguageCodes: [String] = []) throws {
        coordinator = try SubtitleSearchCoordinator(providers: providers)
        self.preferredLanguageCodes = SubtitleLanguageCatalog.normalizedPreferences(preferredLanguageCodes)
    }

    /// Exposes candidates without downloading or writing; a future picker can use the same engine.
    public func search(_ request: SubtitleSearchRequest) async throws -> SubtitleSearchResult {
        try await coordinator.search(request)
    }

    /// Places candidates safe enough for automatic matching first while retaining the remaining
    /// results for manual inspection.
    public func searchForSelection(_ request: SubtitleSearchRequest) async throws -> SubtitleSearchResult {
        let manualRequest = SubtitleSearchRequest(video: request.video, searchName: request.searchName,
                                                  preferredLanguageCodes: preferredLanguageCodes,
                                                  includesUnpreferredLanguages: true)
        let report = try await coordinator.search(manualRequest)
        let ranked = SubtitleMatcher.rank(report.candidates, forName: request.matchingName,
                                          preferredLanguageCodes: preferredLanguageCodes)
        let rankedIDs = Set(ranked.map(\.id))
        func languageIndex(_ candidate: SubtitleCandidate) -> Int {
            preferredLanguageCodes.firstIndex(where: candidate.languageCodes.contains) ?? Int.max
        }
        let remaining = report.candidates.enumerated().filter { !rankedIDs.contains($0.element.id) }.sorted {
            let left = languageIndex($0.element)
            let right = languageIndex($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        return SubtitleSearchResult(candidates: ranked + remaining,
                                    failures: report.failures)
    }

    /// Explicit selection permits candidates whose timing metadata is unavailable.
    public func download(candidate: SubtitleCandidate, video: URL, overwrite: Bool,
                         renameSubtitle: Bool = true, outputDirectory: URL? = nil) async throws -> URL {
        let destination = manualDestination(video: video, candidate: candidate, overwrite: overwrite,
                                            renameSubtitle: renameSubtitle, outputDirectory: outputDirectory)
        let raw = try await coordinator.download(candidate)
        let data = try SubtitleFileWriter.normalized(raw, format: candidate.format)
        try SubtitleFileWriter.save(data, to: destination, overwrite: overwrite)
        return destination
    }

    /// Manual selection may intentionally download more than one candidate of the same format.
    /// Preserve existing files by choosing movie.1.srt, movie.2.srt, and so on.
    private func manualDestination(video: URL, candidate: SubtitleCandidate, overwrite: Bool,
                                   renameSubtitle: Bool, outputDirectory: URL?) -> URL {
        let base = destination(video: video, candidate: candidate, renameSubtitle: renameSubtitle,
                               outputDirectory: outputDirectory)
        guard !overwrite, FileManager.default.fileExists(atPath: base.path) else { return base }
        for index in 1...Int.max {
            let indexedDestination = base.deletingPathExtension()
                .appendingPathExtension(String(index))
                .appendingPathExtension(candidate.format.rawValue)
            if !FileManager.default.fileExists(atPath: indexedDestination.path) { return indexedDestination }
        }
        return base
    }

    public func download(video: URL, preference: SubtitlePreference, overwrite: Bool,
                         renameSubtitle: Bool, outputDirectory: URL?) async throws -> DownloadResult {
        try Task.checkCancellation()
        let seriesKey = SubtitleMatcher.seriesKey(for: video)
        let affinity = seriesKey.flatMap { seriesAffinities[$0] }
        let formats: [SubtitleFormat] = preference == .srt ? [.srt, .ass] : [.ass, .srt]
        func renamedDestination(_ format: SubtitleFormat) -> URL {
            let filename = video.deletingPathExtension().lastPathComponent + "." + format.rawValue
            return (outputDirectory ?? video.deletingLastPathComponent()).appendingPathComponent(filename)
        }
        let existing = overwrite || !renameSubtitle ? [] : formats.map(renamedDestination).filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        if (preference != .both && existing.contains(renamedDestination(formats[0]))) || existing.count == 2 {
            return DownloadResult(existing: existing)
        }
        let report = try await coordinator.search(SubtitleSearchRequest(
            video: video, preferredLanguageCodes: preferredLanguageCodes,
            includesUnpreferredLanguages: preferredLanguageCodes.isEmpty))
        // Unknown timing can be selected when filename metadata is a safe match. The chosen
        // candidate is returned in DownloadResult so the UI can disclose that limitation.
        let candidates = SubtitleMatcher.rank(report.candidates, for: video,
                                              preferredLanguageCodes: preferredLanguageCodes,
                                              requirePreferredLanguage: !preferredLanguageCodes.isEmpty)
        var diagnostics = report.failures
        var lastError: (any Error)? = report.failures.first?.error
        var assigned = Set<SubtitleCandidate.ID>()
        let groups: [[SubtitleCandidate]]
        if preferredLanguageCodes.isEmpty {
            groups = [candidates]
        } else {
            groups = preferredLanguageCodes.map { language in
                candidates.filter { $0.languageCodes.contains(language) && assigned.insert($0.id).inserted }
            }.filter { !$0.isEmpty }
        }
        for candidates in groups {
            var saved: [URL] = []
            var selections: [SubtitleCandidate] = []
            var kept: [URL] = []
            var warnings: [String] = []
            for format in formats {
                try Task.checkCancellation()
                let renamedURL = renamedDestination(format)
                if existing.contains(renamedURL) {
                    kept.append(renamedURL)
                    if preference != .both { break }
                    continue
                }
                var downloaded = false
                var formatError: (any Error)?
                let preferredSourceID = affinity?.sourceByFormat[format] ?? affinity?.primarySourceID
                let formatCandidates = candidates.enumerated().filter { $0.element.format == format }.sorted {
                    let left = $0.element.source.id == preferredSourceID ? 0 : 1
                    let right = $1.element.source.id == preferredSourceID ? 0 : 1
                    return left == right ? $0.offset < $1.offset : left < right
                }.map(\.element)
                for candidate in formatCandidates {
                    let url = destination(video: video, candidate: candidate, renameSubtitle: renameSubtitle,
                                          outputDirectory: outputDirectory)
                    if !overwrite, FileManager.default.fileExists(atPath: url.path) {
                        kept.append(url); selections.append(candidate); downloaded = true; break
                    }
                    do {
                        let raw = try await coordinator.download(candidate)
                        try Task.checkCancellation()
                        let data = try SubtitleFileWriter.normalized(raw, format: candidate.format)
                        try SubtitleFileWriter.save(data, to: url, overwrite: overwrite)
                        saved.append(url); selections.append(candidate); downloaded = true; break
                    } catch {
                        if Task.isCancelled || error is CancellationError { throw CancellationError() }
                        lastError = error; formatError = error
                        diagnostics.append(SubtitleSourceFailure(source: candidate.source, error: error))
                    }
                }
                if downloaded && preference != .both { break }
                if !downloaded {
                    warnings.append("\(format.rawValue.uppercased()): \((formatError ?? report.failures.first?.error ?? SubtitleError.noMatches).localizedDescription)")
                }
            }
            if !saved.isEmpty || !kept.isEmpty {
                if let seriesKey, let first = selections.first {
                    var current = seriesAffinities[seriesKey] ?? SeriesAffinity(
                        sourceByFormat: [:], primarySourceID: first.source.id
                    )
                    for selection in selections where current.sourceByFormat[selection.format] == nil {
                        current.sourceByFormat[selection.format] = selection.source.id
                    }
                    seriesAffinities[seriesKey] = current
                }
                return DownloadResult(saved: saved, existing: kept,
                                      warnings: preference == .both ? warnings : [],
                                      sourceFailures: diagnostics, selections: selections)
            }
        }
        do {
            if Set(diagnostics.map { $0.source.id }).count > 1 {
                throw SubtitleProviderError.allSourcesFailed(diagnostics)
            }
            throw lastError ?? SubtitleError.noMatches
        }
    }

    private func destination(video: URL, candidate: SubtitleCandidate, renameSubtitle: Bool,
                             outputDirectory: URL?) -> URL {
        let directory = outputDirectory ?? video.deletingLastPathComponent()
        guard !renameSubtitle else {
            let filename = video.deletingPathExtension().lastPathComponent + "." + candidate.format.rawValue
            return directory.appendingPathComponent(filename)
        }
        let sourceName = URL(fileURLWithPath: candidate.title).lastPathComponent
        let stem = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        let safeStem = stem.isEmpty || stem == "." || stem == ".."
            ? video.deletingPathExtension().lastPathComponent
            : stem
        return directory.appendingPathComponent(safeStem)
            .appendingPathExtension(candidate.format.rawValue)
    }
}
