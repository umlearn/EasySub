import Foundation

/// Compatibility entry point for callers that explicitly want only Shooter.
/// The app uses MultiSourceSubtitleService; protocol handling lives in ShooterProvider.
public actor ShooterService: SubtitleDownloading {
    private let service: MultiSourceSubtitleService

    public init(transport: any HTTPTransport = URLSessionTransport(),
                endpoint: URL = URL(string: "https://www.shooter.cn/api/subapi.php")!) {
        service = MultiSourceSubtitleService(provider: ShooterProvider(transport: transport, endpoint: endpoint))
    }

    public func download(video: URL, preference: SubtitlePreference, overwrite: Bool,
                         renameSubtitle: Bool, outputDirectory: URL?) async throws -> DownloadResult {
        try await service.download(video: video, preference: preference, overwrite: overwrite,
                                   renameSubtitle: renameSubtitle, outputDirectory: outputDirectory)
    }
}
