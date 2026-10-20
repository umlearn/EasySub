import Foundation

/// Stable provider identity. New sources do not require modifying an enum or the UI.
public struct SubtitleSource: Hashable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
    public static let shooter = SubtitleSource(id: "shooter", name: "Shooter")
}

public enum SubtitleFormat: String, Sendable, CaseIterable {
    case ass, srt
}

public enum SubtitleMatchKind: String, Sendable {
    case fingerprint, filename
}

/// Providers compute their own fingerprints only when needed. The video never gets uploaded.
public struct SubtitleSearchRequest: Sendable {
    public let video: URL
    public let searchName: String?
    public var filename: String {
        let value = searchName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? video.lastPathComponent : value
    }
    /// User-editable search text with a known video extension removed. Release metadata remains
    /// intact so providers and ranking can still use year, episode, resolution and codec hints.
    public var matchingName: String {
        let value = filename
        let ext = (value as NSString).pathExtension.lowercased()
        guard VideoScanner.extensions.contains(ext) else { return value }
        return (value as NSString).deletingPathExtension
    }
    public init(video: URL, searchName: String? = nil) {
        self.video = video
        self.searchName = searchName
    }
}

public struct SubtitleCandidate: Identifiable, Sendable, Equatable {
    /// IDs are scoped to the provider; two sources may use the same local subtitle ID.
    public struct ID: Hashable, Sendable {
        public let sourceID: String
        public let value: String
        public init(sourceID: String, value: String) { self.sourceID = sourceID; self.value = value }
    }
    public var id: ID { ID(sourceID: source.id, value: reference) }
    public let source: SubtitleSource
    /// Opaque provider reference: a subtitle ID, file ID, or URL. Resolve expiring URLs in download().
    public let reference: String
    public let title: String
    /// Provider metadata used for matching. It may include native title, adapted video name
    /// and release filename, while `title` remains the concise value shown to the user.
    public let matchingText: String
    public let format: SubtitleFormat
    public let languageCodes: Set<String>
    public let matchKind: SubtitleMatchKind
    /// Optional provider ranking signal. It is a tie-breaker, never stronger than identity metadata.
    public let providerScore: Int?
    /// nil means unknown, not zero. Automatic matching may select unknown timing without claiming synchronization.
    public let delayMilliseconds: Int?

    public init(source: SubtitleSource, reference: String, title: String, matchingText: String? = nil,
                format: SubtitleFormat, languageCodes: Set<String> = [],
                matchKind: SubtitleMatchKind = .filename, providerScore: Int? = nil,
                delayMilliseconds: Int? = nil) {
        self.source = source; self.reference = reference; self.title = title
        self.matchingText = matchingText ?? title; self.format = format
        self.languageCodes = languageCodes; self.matchKind = matchKind
        self.providerScore = providerScore; self.delayMilliseconds = delayMilliseconds
    }
}

public protocol SubtitleProvider: Sendable {
    var source: SubtitleSource { get }
    func search(_ request: SubtitleSearchRequest) async throws -> [SubtitleCandidate]
    func download(_ candidate: SubtitleCandidate) async throws -> Data
}

public struct SubtitleSourceFailure: Sendable {
    public let source: SubtitleSource
    public let error: any Error
    public var description: String { "\(source.name): \(error.localizedDescription)" }
}

public struct SubtitleSearchResult: Sendable {
    public let candidates: [SubtitleCandidate]
    public let failures: [SubtitleSourceFailure]
}

public enum SubtitleProviderError: Error, LocalizedError, Sendable {
    case emptyRegistry, duplicateSource(String), invalidCandidate, invalidEndpoint
    case allSourcesFailed([SubtitleSourceFailure])

    public var errorDescription: String? {
        switch self {
        case .emptyRegistry: String(localized: "No subtitle sources are configured.")
        case .duplicateSource(let id): String(format: String(localized: "Duplicate subtitle source: %@."), id)
        case .invalidCandidate: String(localized: "The subtitle candidate does not belong to this source.")
        case .invalidEndpoint: String(localized: "The subtitle service address is invalid.")
        case .allSourcesFailed(let failures): failures.map(\.description).joined(separator: "\n")
        }
    }
}
