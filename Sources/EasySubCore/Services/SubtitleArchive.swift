import Foundation

/// Reads subtitle members directly from an archive without extracting paths to disk.
enum SubtitleArchive {
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "tar", "tgz", "gz"]
    private static let tool = URL(fileURLWithPath: "/usr/bin/bsdtar")
    private static let listingLimit = 2 * 1024 * 1024
    private static let subtitleLimit = 8 * 1024 * 1024

    static func isArchive(_ filename: String) -> Bool {
        archiveExtensions.contains((filename as NSString).pathExtension.lowercased())
    }

    static func extract(_ data: Data, format: SubtitleFormat) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            try extractSynchronously(data, format: format)
        }.value
    }

    private static func extractSynchronously(_ data: Data, format: SubtitleFormat) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasySubArchive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = directory.appendingPathComponent("subtitle-archive")
        try data.write(to: archive, options: .atomic)
        let listing = String(decoding: try run(["-tf", archive.path], limit: listingLimit), as: UTF8.self)
        let entries = listing.split(separator: "\n")
            .map(String.init)
            .filter { isSafeEntry($0, format: format) }
        guard let entry = entries.max(by: { languageScore($0) < languageScore($1) }) else {
            throw SubtitleError.archiveMissingSubtitle
        }
        let subtitle = try run(["-xOf", archive.path, entry], limit: subtitleLimit)
        guard !subtitle.isEmpty else { throw SubtitleError.archiveMissingSubtitle }
        return subtitle
    }

    private static func isSafeEntry(_ name: String, format: SubtitleFormat) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("__MACOSX/"),
              !name.hasPrefix("/"), !name.hasPrefix("-"),
              !name.contains("\0"), !name.components(separatedBy: "/").contains(".."),
              (name as NSString).pathExtension.lowercased() == format.rawValue else {
            return false
        }
        return true
    }

    private static func languageScore(_ name: String) -> Int {
        let value = name.lowercased()
        var score = 0
        if ["chs", "zh-cn", "zh_cn", "简体", "简中"].contains(where: value.contains) { score += 30 }
        else if ["cht", "zh-tw", "zh_tw", "繁体", "繁中"].contains(where: value.contains) { score += 20 }
        if ["双语", "bilingual", "&eng"].contains(where: value.contains) { score += 5 }
        return score
    }

    private static func run(_ arguments: [String], limit: Int) throws -> Data {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw SubtitleError.archiveUnsupported
        }

        var data = Data()
        while true {
            let chunk = try output.fileHandleForReading.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > limit {
                process.terminate()
                process.waitUntilExit()
                throw SubtitleError.oversizedResponse
            }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SubtitleError.archiveUnsupported }
        return data
    }
}
