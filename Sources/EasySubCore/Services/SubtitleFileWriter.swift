import Foundation
import CoreFoundation

/// Shared payload guards and same-directory writes, independent of a subtitle provider.
/// Archive members are read by SubtitleArchive before this final format validation.
enum SubtitleFileWriter {
    enum ChineseDialogueScript: Equatable {
        case simplified, traditional, mixed, chinese, nonChinese, inconclusive
    }

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
        switch chineseDialogueScript(data, format: format) {
        case .simplified, .traditional, .mixed, .chinese: true
        case .nonChinese: false
        case .inconclusive: nil
        }
    }

    /// Distinguishes Chinese scripts from dialogue rather than trusting provider metadata alone.
    /// ICU's contextual conversion supplies the evidence; conservative thresholds keep short,
    /// neutral, Japanese, and genuinely mixed-script subtitles from being rejected automatically.
    static func chineseDialogueScript(_ data: Data, format: SubtitleFormat) -> ChineseDialogueScript {
        guard let text = String(data: data.prefix(256 * 1024), encoding: .utf8) else {
            return .inconclusive
        }
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
            if isHan(scalar) { han += 1 }
            if letters >= 4_000 { break }
        }
        let containsChinese: Bool
        if letters < 40 {
            guard han >= 4 && han * 4 >= letters else { return .inconclusive }
            containsChinese = true
        } else {
            containsChinese = han >= 12 || han * 12 >= letters
        }
        guard containsChinese else { return .nonChinese }

        let sampled = String(visible.prefix(16_000))
        guard let simplified = sampled.applyingTransform(
            StringTransform("Traditional-Simplified"), reverse: false
        ), let traditional = sampled.applyingTransform(
            StringTransform("Simplified-Traditional"), reverse: false
        ) else { return .chinese }
        let originalCharacters = Array(sampled)
        let simplifiedCharacters = Array(simplified)
        let traditionalCharacters = Array(traditional)
        guard originalCharacters.count == simplifiedCharacters.count,
              originalCharacters.count == traditionalCharacters.count else { return .chinese }

        var simplifiedEvidence = 0
        var traditionalEvidence = 0
        for index in originalCharacters.indices {
            let original = originalCharacters[index]
            guard original.unicodeScalars.contains(where: isHan) else { continue }
            let toSimplified = simplifiedCharacters[index]
            let toTraditional = traditionalCharacters[index]
            if toTraditional != original, toSimplified == original { simplifiedEvidence += 1 }
            if toSimplified != original, toTraditional == original { traditionalEvidence += 1 }
        }
        let minimumEvidence = han >= 40 ? 4 : 3
        if simplifiedEvidence >= minimumEvidence,
           simplifiedEvidence >= max(minimumEvidence, traditionalEvidence * 3) {
            return .simplified
        }
        if traditionalEvidence >= minimumEvidence,
           traditionalEvidence >= max(minimumEvidence, simplifiedEvidence * 3) {
            return .traditional
        }
        if simplifiedEvidence >= minimumEvidence, traditionalEvidence >= minimumEvidence {
            return .mixed
        }
        return .chinese
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2FA1F: true
        default: false
        }
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
