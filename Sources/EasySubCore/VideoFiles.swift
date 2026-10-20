import Foundation
import CryptoKit

public enum VideoHasher {
    /// Shooter's compatibility fingerprint, not a security digest.
    public static func hash(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        guard size >= 8192 else { throw SubtitleError.smallFile }
        // The legacy Shooter protocol performs integer division before multiplying by two.
        // Reordering these operations changes the sampled byte when size % 3 == 2.
        let offsets: [UInt64] = [4096, (size / 3) * 2, size / 3, size - 8192]
        return try offsets.map { offset in
            try Task.checkCancellation()
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: 4096), data.count == Int(min(4096, size - offset)) else {
                throw SubtitleError.unreadableFile
            }
            return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }.joined(separator: ";")
    }
}

public struct ScanResult: Sendable {
    public var videos: [VideoFile] = []
    public var failures: [String] = []
}

public actor VideoScanner {
    public static let extensions: Set<String> = ["mkv", "mov", "mp4", "m4v", "rmvb", "avi", "mpeg", "mpg", "ts", "m2ts", "webm"]
    public init() {}

    public func scan(_ roots: [URL]) -> ScanResult {
        var result = ScanResult()
        var seen = Set<URL>()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        func append(_ url: URL) {
            guard Self.extensions.contains(url.pathExtension.lowercased()) else { return }
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
                let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                if seen.insert(canonical).inserted {
                    result.videos.append(VideoFile(url: canonical, size: Int64(values.fileSize ?? 0)))
                }
            } catch { result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        for root in roots where root.isFileURL {
            if Task.isCancelled { break }
            do {
                let values = try root.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    // Do not follow directory symlinks; avoids loops and unexpected traversal.
                    let enumerator = FileManager.default.enumerator(
                        at: root, includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                        errorHandler: { url, error in
                            result.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                            return true
                        })
                    while let child = enumerator?.nextObject() as? URL {
                        if Task.isCancelled { break }
                        append(child)
                    }
                } else { append(root) }
            } catch { result.failures.append("\(root.lastPathComponent): \(error.localizedDescription)") }
        }
        result.videos.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
        return result
    }
}
