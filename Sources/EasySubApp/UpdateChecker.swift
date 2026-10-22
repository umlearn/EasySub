import Foundation
import Observation

struct UpdateRelease: Identifiable, Sendable {
    let version: String
    let pageURL: URL
    let notes: String

    var id: String { version }
}

enum UpdateCheckStatus: Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case failed(String)
}

@MainActor @Observable
final class UpdateChecker {
    static let automaticChecksKey = "automaticallyCheckForUpdates"

    private static let lastCheckKey = "lastUpdateCheckDate"
    private static let skippedVersionKey = "skippedUpdateVersion"
    private static let releaseURL = URL(string: "https://api.github.com/repos/umlearn/EasySub/releases/latest")!
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private(set) var status: UpdateCheckStatus = .idle

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored let currentVersion: String

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         currentVersion: String? = nil) {
        self.defaults = defaults
        self.session = session
        self.currentVersion = currentVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }

    var isChecking: Bool {
        if case .checking = status { true } else { false }
    }

    var hasVisibleStatus: Bool {
        if case .idle = status { false } else { true }
    }

    func performAutomaticCheckIfNeeded() async {
        guard automaticChecksEnabled else { return }
        if let lastCheck = defaults.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(lastCheck) < Self.checkInterval {
            return
        }
        try? await Task.sleep(for: .seconds(3))
        guard !Task.isCancelled, automaticChecksEnabled else { return }
        await check(manual: false)
    }

    func check(manual: Bool) async {
        guard !isChecking else { return }
        status = .checking
        defaults.set(Date(), forKey: Self.lastCheckKey)

        do {
            let release = try await fetchLatestRelease()
            guard let installed = AppVersion(currentVersion), let latest = AppVersion(release.version) else {
                throw UpdateCheckError.invalidVersion
            }

            if installed < latest {
                let skipped = defaults.string(forKey: Self.skippedVersionKey)
                if manual || skipped != release.version {
                    status = .available(release)
                } else {
                    status = .idle
                }
            } else {
                status = .upToDate
            }
        } catch {
            status = manual ? .failed(error.localizedDescription) : .idle
        }
    }

    func skip(_ release: UpdateRelease) {
        defaults.set(release.version, forKey: Self.skippedVersionKey)
        status = .idle
    }

    private var automaticChecksEnabled: Bool {
        defaults.object(forKey: Self.automaticChecksKey) == nil
            || defaults.bool(forKey: Self.automaticChecksKey)
    }

    private func fetchLatestRelease() async throws -> UpdateRelease {
        var request = URLRequest(url: Self.releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("EasySub/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }
        if response.statusCode == 404 { throw UpdateCheckError.noPublishedRelease }
        guard (200..<300).contains(response.statusCode) else {
            throw UpdateCheckError.server(response.statusCode)
        }

        let responseBody = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let pageURL = URL(string: responseBody.htmlURL) else {
            throw UpdateCheckError.invalidResponse
        }
        let version = responseBody.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        return UpdateRelease(version: normalizedVersion(version), pageURL: pageURL,
                             notes: responseBody.body ?? "")
    }

    private func normalizedVersion(_ value: String) -> String {
        guard value.first == "v" || value.first == "V" else { return value }
        return String(value.dropFirst())
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
    }
}

private enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case noPublishedRelease
    case invalidVersion
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            String(localized: "GitHub returned an invalid response.")
        case .noPublishedRelease:
            String(localized: "No published EasySub release was found.")
        case .invalidVersion:
            String(localized: "The release has an invalid version number.")
        case .server(let statusCode):
            String(format: String(localized: "GitHub returned HTTP status %lld."), statusCode)
        }
    }
}
