import Foundation
import Observation

public enum DownloadStatus: String, Sendable {
    case ready, queued, downloading, completed, partial, failed, cancelled
    public var canRetry: Bool { self == .ready || self == .failed || self == .cancelled || self == .partial }
}

public struct DownloadItem: Identifiable, Sendable {
    public var id: URL { video.id }
    public let video: VideoFile
    public var status: DownloadStatus = .ready
    public var detail = ""
    public var output: [URL] = []
    public var selectedCandidates: [SubtitleCandidate] = []
    public var downloadedCandidates: [SubtitleCandidate.ID: URL] = [:]
}

@MainActor @Observable
public final class DownloadStore {
    public private(set) var items: [DownloadItem] = []
    public private(set) var isRunning = false
    public private(set) var isCancelling = false
    public private(set) var activeImports = 0
    public private(set) var batchTotal = 0
    public private(set) var batchFinished = 0
    public private(set) var completionCount = 0
    public var importMessage: String?
    @ObservationIgnored private var batch: Task<Void, Never>?
    @ObservationIgnored private let service: any SubtitleDownloading
    @ObservationIgnored private let scanner = VideoScanner()

    public init(service: any SubtitleDownloading = MultiSourceSubtitleService()) { self.service = service }
    public var pendingCount: Int { items.filter { $0.status.canRetry }.count }
    public var successCount: Int { items.filter { $0.status == .completed }.count }
    public var failureCount: Int { items.filter { $0.status == .failed || $0.status == .partial }.count }

    public func add(_ urls: [URL]) async {
        activeImports += 1
        defer { activeImports -= 1 }
        let result = await scanner.scan(urls)
        let existing = Set(items.map(\.id))
        items += result.videos.filter { !existing.contains($0.id) }.map { DownloadItem(video: $0) }
        if !result.failures.isEmpty { importMessage = result.failures.joined(separator: "\n") }
        else if result.videos.isEmpty { importMessage = String(localized: "No supported video files were found.") }
    }

    public func remove(_ ids: Set<URL>) {
        guard !isRunning else { return }
        items.removeAll { ids.contains($0.id) }
    }

    public func clearCompleted() {
        guard !isRunning else { return }
        items.removeAll { $0.status == .completed }
    }

    public func clearAll() {
        guard !isRunning else { return }
        items.removeAll()
    }

    public func mark(_ ids: Set<URL>, as status: DownloadStatus) {
        guard !isRunning else { return }
        guard status == .ready || status == .completed else { return }
        for index in items.indices where ids.contains(items[index].id) {
            items[index].status = status
        }
    }

    public func start(preference: SubtitlePreference, overwrite: Bool, renameSubtitle: Bool = true,
                      outputDirectory: URL? = nil,
                      service override: (any SubtitleDownloading)? = nil) {
        guard !isRunning else { return }
        let videos = items.filter { $0.status.canRetry }.map(\.video)
        guard !videos.isEmpty else { return }
        isRunning = true
        isCancelling = false
        batchTotal = videos.count
        batchFinished = 0
        let ids = Set(videos.map(\.id))
        for index in items.indices where ids.contains(items[index].id) {
            items[index].status = .queued
            items[index].detail = ""
            items[index].selectedCandidates = []
            items[index].downloadedCandidates = [:]
        }
        let service = override ?? service
        batch = Task {
            // Two workers keep the UI responsive and avoid flooding the legacy service.
            await withTaskGroup(of: Outcome.self) { group in
                var iterator = videos.makeIterator()
                @MainActor func enqueue(_ video: VideoFile) {
                    setStatus(video.id, .downloading)
                    group.addTask {
                        do {
                            try Task.checkCancellation()
                            let result = try await service.download(video: video.url, preference: preference,
                                                                    overwrite: overwrite,
                                                                    renameSubtitle: renameSubtitle,
                                                                    outputDirectory: outputDirectory)
                            return Outcome(id: video.id, result: result, error: nil, cancelled: false)
                        } catch {
                            return Outcome(id: video.id, result: nil, error: error.localizedDescription,
                                           cancelled: Task.isCancelled || error is CancellationError)
                        }
                    }
                }
                for _ in 0..<2 { if let video = iterator.next() { enqueue(video) } }
                while let outcome = await group.next() {
                    apply(outcome)
                    batchFinished += 1
                    if !Task.isCancelled, let video = iterator.next() { enqueue(video) }
                }
            }
            for index in items.indices where ids.contains(items[index].id) && items[index].status == .queued {
                items[index].status = .cancelled
            }
            isRunning = false
            isCancelling = false
            completionCount += 1
            batch = nil
        }
    }

    public func cancel() { isCancelling = true; batch?.cancel() }

    public func recordManualDownload(video: URL, output: URL, candidate: SubtitleCandidate) {
        guard !isRunning else { return }
        guard let index = items.firstIndex(where: { $0.id == video }) else { return }
        items[index].status = .completed
        let replacedCandidateIDs = Set(items[index].downloadedCandidates.compactMap { id, existingOutput in
            existingOutput.standardizedFileURL == output.standardizedFileURL ? id : nil
        })
        items[index].selectedCandidates.removeAll { replacedCandidateIDs.contains($0.id) }
        for id in replacedCandidateIDs { items[index].downloadedCandidates[id] = nil }
        if !items[index].output.contains(output) { items[index].output.append(output) }
        if !items[index].selectedCandidates.contains(where: { $0.id == candidate.id }) {
            items[index].selectedCandidates.append(candidate)
        }
        items[index].downloadedCandidates[candidate.id] = output
        var lines = items[index].output.map { String(localized: "Saved") + ": " + $0.lastPathComponent }
        lines += items[index].selectedCandidates.map { savedCandidate in
            let evidence = savedCandidate.matchKind == .fingerprint ? " · " + String(localized: "Fingerprint match") : ""
            return "\(savedCandidate.source.name): \(savedCandidate.title)\(evidence)"
        }
        items[index].detail = lines.joined(separator: "\n")
    }

    private func setStatus(_ id: URL, _ status: DownloadStatus) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
    }
    private func apply(_ outcome: Outcome) {
        guard let index = items.firstIndex(where: { $0.id == outcome.id }) else { return }
        if let result = outcome.result {
            items[index].status = result.warnings.isEmpty ? .completed : .partial
            items[index].output = result.saved + result.existing
            items[index].selectedCandidates = result.selections
            items[index].downloadedCandidates = candidateFiles(result.selections, outputs: items[index].output)
            var lines = result.saved.map { String(localized: "Saved") + ": " + $0.lastPathComponent }
            lines += result.existing.map { String(localized: "Kept existing") + ": " + $0.lastPathComponent }
            lines += result.selections.map { candidate in
                let evidence = candidate.matchKind == .fingerprint ? " · " + String(localized: "Fingerprint match") : ""
                return "\(candidate.source.name): \(candidate.title)\(evidence)"
            }
            lines += result.warnings
            items[index].detail = lines.joined(separator: "\n")
        } else {
            items[index].status = outcome.cancelled ? .cancelled : .failed
            items[index].detail = outcome.cancelled ? String(localized: "Download cancelled.") : (outcome.error ?? "")
        }
    }

    private func candidateFiles(_ candidates: [SubtitleCandidate], outputs: [URL]) -> [SubtitleCandidate.ID: URL] {
        var remaining = outputs
        var files: [SubtitleCandidate.ID: URL] = [:]
        for candidate in candidates {
            guard let index = remaining.firstIndex(where: {
                $0.pathExtension.caseInsensitiveCompare(candidate.format.rawValue) == .orderedSame
            }) else { continue }
            files[candidate.id] = remaining.remove(at: index)
        }
        return files
    }
}

private struct Outcome: Sendable {
    let id: URL
    let result: DownloadResult?
    let error: String?
    let cancelled: Bool
}
