import AppKit
import Foundation
import Observation
import SwiftUI

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

enum UpdateCheckSource: Sendable {
    case automatic
    case settings
    case menu
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
        await checkForUpdates(from: .automatic)
    }

    func checkForUpdates(from source: UpdateCheckSource) async {
        await check(manual: source != .automatic)

        switch source {
        case .automatic:
            if case .available = status { presentAvailableUpdate() }
        case .settings:
            if case .available = status { presentAvailableUpdate() }
        case .menu:
            presentCurrentStatus()
        }
    }

    private func check(manual: Bool) async {
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
        status = .available(release)
    }

    private func presentAvailableUpdate() {
        guard case .available(let release) = status else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(
            format: String(localized: "Version %@ is available."),
            release.version
        )
        alert.informativeText = String(
            format: String(localized: "You’re using version %@."),
            currentVersion
        )

        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            let notesView = NSHostingView(rootView: UpdateReleaseNotesView(markdown: notes))
            notesView.frame = NSRect(x: 0, y: 0, width: 390, height: 135)
            alert.accessoryView = notesView
        }

        alert.addButton(withTitle: String(localized: "View Release"))
        alert.addButton(withTitle: String(localized: "Skip This Version"))
        alert.addButton(withTitle: String(localized: "Later"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        case .alertSecondButtonReturn:
            skip(release)
        default:
            break
        }
    }

    private func presentCurrentStatus() {
        switch status {
        case .available:
            presentAvailableUpdate()
        case .upToDate:
            presentInformation(
                title: String(localized: "You’re up to date!"),
                message: String(
                    format: String(localized: "You’re using version %@."),
                    currentVersion
                )
            )
        case .failed(let message):
            presentInformation(
                title: String(localized: "Couldn’t check for updates."),
                message: message,
                style: .warning
            )
        case .checking:
            presentInformation(
                title: String(localized: "Checking for updates…"),
                message: String(localized: "Please wait for the current update check to finish.")
            )
        case .idle:
            presentInformation(
                title: String(localized: "No update information is available."),
                message: String(localized: "Run “Check for Updates…” again to retry.")
            )
        }
    }

    private func presentInformation(title: String, message: String,
                                    style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
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

private struct UpdateReleaseNotesView: View {
    let markdown: String

    private var blocks: [ReleaseNoteBlock] {
        ReleaseNoteBlock.parse(markdown)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .heading(let level, let text):
                        markdownText(text)
                            .font(.caption.weight(.semibold))
                            .padding(.top, level <= 2 ? 2 : 0)
                    case .bullet(let text):
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle()
                                .fill(.secondary)
                                .frame(width: 3, height: 3)
                            markdownText(text)
                                .font(.caption)
                        }
                    case .numbered(let number, let text):
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(verbatim: "\(number).")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            markdownText(text)
                                .font(.caption)
                        }
                    case .paragraph(let text):
                        markdownText(text)
                            .font(.caption)
                    case .divider:
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private func markdownText(_ source: String) -> Text {
        guard let attributed = try? AttributedString(markdown: source) else {
            return Text(verbatim: source)
        }
        return Text(attributed)
    }
}

private enum ReleaseNoteBlock {
    case heading(Int, String)
    case bullet(String)
    case numbered(Int, String)
    case paragraph(String)
    case divider

    static func parse(_ markdown: String) -> [Self] {
        markdown.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line == "---" || line == "***" { return .divider }

            let headingLevel = line.prefix { $0 == "#" }.count
            if headingLevel > 0, headingLevel <= 6,
               line.dropFirst(headingLevel).first == " " {
                return .heading(headingLevel, String(line.dropFirst(headingLevel + 1)))
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                return .bullet(String(line.dropFirst(2)))
            }

            if let dot = line.firstIndex(of: "."),
               let number = Int(line[..<dot]),
               line.index(after: dot) < line.endIndex,
               line[line.index(after: dot)] == " " {
                return .numbered(number, String(line[line.index(dot, offsetBy: 2)...]))
            }

            return .paragraph(line)
        }
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
