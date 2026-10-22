import Foundation

public enum SubtitlePreference: String, CaseIterable, Sendable {
    case ass = "ASS", srt = "SRT", both = "BOTH"
}

public enum SubtitleError: Error, LocalizedError, Sendable {
    case smallFile, unreadableFile, invalidResponse, noMatches, insecureURL, emptySubtitle, oversizedResponse
    case unexpectedLanguage
    case archiveUnsupported, archiveMissingSubtitle
    case http(Int)

    public var errorDescription: String? {
        switch self {
        case .smallFile: String(localized: "Video must be at least 8 KB.")
        case .unreadableFile: String(localized: "The video could not be read completely.")
        case .invalidResponse: String(localized: "The subtitle service returned an invalid response.")
        case .noMatches: String(localized: "No suitable ASS or SRT subtitles found. Try manual selection.")
        case .insecureURL: String(localized: "The service returned an insecure download link.")
        case .emptySubtitle: String(localized: "The downloaded subtitle is empty or is an HTML error page.")
        case .oversizedResponse: String(localized: "The service response exceeds the size limit.")
        case .unexpectedLanguage: String(localized: "The inferred Chinese subtitle does not appear to contain Chinese dialogue.")
        case .archiveUnsupported: String(localized: "The subtitle archive could not be extracted.")
        case .archiveMissingSubtitle: String(localized: "The subtitle archive contains no ASS or SRT file.")
        case .http(let status): String(format: String(localized: "Service returned HTTP %d."), status)
        }
    }
}

public struct VideoFile: Identifiable, Sendable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let size: Int64
    public init(url: URL, size: Int64) { self.url = url; self.size = size }
}

public struct DownloadResult: Sendable {
    public let saved: [URL]
    public let existing: [URL]
    public let warnings: [String]
    public let sourceFailures: [SubtitleSourceFailure]
    public let selections: [SubtitleCandidate]
    public init(saved: [URL] = [], existing: [URL] = [], warnings: [String] = [],
                sourceFailures: [SubtitleSourceFailure] = [], selections: [SubtitleCandidate] = []) {
        self.saved = saved; self.existing = existing; self.warnings = warnings
        self.sourceFailures = sourceFailures; self.selections = selections
    }
}

public protocol SubtitleDownloading: Sendable {
    func download(video: URL, preference: SubtitlePreference, overwrite: Bool,
                  renameSubtitle: Bool, outputDirectory: URL?) async throws -> DownloadResult
}

public extension SubtitleDownloading {
    func download(video: URL, preference: SubtitlePreference, overwrite: Bool) async throws -> DownloadResult {
        try await download(video: video, preference: preference, overwrite: overwrite,
                           renameSubtitle: true, outputDirectory: nil)
    }

    func download(video: URL, preference: SubtitlePreference, overwrite: Bool,
                  renameSubtitle: Bool) async throws -> DownloadResult {
        try await download(video: video, preference: preference, overwrite: overwrite,
                           renameSubtitle: renameSubtitle, outputDirectory: nil)
    }
}
