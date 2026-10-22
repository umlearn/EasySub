import Foundation
import CoreFoundation

/// Shared payload guards and same-directory writes, independent of a subtitle provider.
/// Archive members are read by SubtitleArchive before this final format validation.
enum SubtitleFileWriter {
    static func validate(_ data: Data) throws {
        guard data.count <= 8 * 1024 * 1024 else { throw SubtitleError.oversizedResponse }
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !data.isEmpty, !prefix.hasPrefix("<!doctype html"), !prefix.hasPrefix("<html") else {
            throw SubtitleError.emptySubtitle
        }
    }

    /// Decode common subtitle encodings and verify a minimum structural signature.
    /// This is not a complete subtitle grammar parser.
    static func normalized(_ data: Data, format: SubtitleFormat) throws -> Data {
        try validate(data)
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let encodings: [String.Encoding] = data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])
            ? [.utf16] : [.utf8, gb18030]
        guard let text = encodings.lazy.compactMap({ String(data: data, encoding: $0) }).first,
              !text.contains("\0") else { throw SubtitleError.invalidResponse }
        let valid: Bool
        switch format {
        case .srt:
            valid = text.range(of: #"\d{2}:\d{2}:\d{2}[,.]\d{3}\s*-->\s*\d{2}:\d{2}:\d{2}[,.]\d{3}"#, options: .regularExpression) != nil
        case .ass:
            valid = text.localizedCaseInsensitiveContains("[Events]") && text.localizedCaseInsensitiveContains("Dialogue:")
        }
        guard valid else { throw SubtitleError.invalidResponse }
        return Data(text.utf8)
    }

    /// Returns true for likely Chinese dialogue, false for a sufficiently large sample that is
    /// clearly non-Chinese, and nil when a short or unusual subtitle does not provide enough text.
    /// Callers use this only to verify candidates inferred from a Chinese-community source.
    static func likelyContainsChineseDialogue(_ data: Data, format: SubtitleFormat) -> Bool? {
        guard let text = String(data: data.prefix(256 * 1024), encoding: .utf8) else { return nil }
        let dialogue: String
        switch format {
        case .srt:
            dialogue = text.split(whereSeparator: \Character.isNewline).compactMap { line -> String? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty,
                      value.range(of: #"^\d+$"#, options: .regularExpression) == nil,
                      !value.contains("-->") else { return nil }
                return value
            }.joined(separator: " ")
        case .ass:
            dialogue = text.split(whereSeparator: \Character.isNewline).compactMap { line -> String? in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard value.lowercased().hasPrefix("dialogue:") else { return nil }
                return value.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).last.map(String.init)
            }.joined(separator: " ")
        }
        let visible = dialogue
            .replacingOccurrences(of: #"<[^>]*>|\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\[Nnh]"#, with: " ", options: .regularExpression)
        var han = 0
        var letters = 0
        for scalar in visible.unicodeScalars {
            guard CharacterSet.letters.contains(scalar) else { continue }
            letters += 1
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2FA1F:
                han += 1
            default:
                break
            }
            if letters >= 4_000 { break }
        }
        guard letters >= 40 else {
            return han >= 4 && han * 4 >= letters ? true : nil
        }
        if han >= 12 || han * 12 >= letters { return true }
        return false
    }

    static func save(_ data: Data, to url: URL, overwrite: Bool) throws {
        try Task.checkCancellation()
        if overwrite { try data.write(to: url, options: .atomic); return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".easysub-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        try Task.checkCancellation()
        // Same-directory move is atomic and fails if another process created the destination.
        try FileManager.default.moveItem(at: temporary, to: url)
    }
}
