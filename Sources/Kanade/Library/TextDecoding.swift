import Foundation

enum TextDecoding {
    static let shiftJIS = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
    )

    /// CUE / LRC / M3U などのテキストファイルを文字コード自動判別で読む (UTF-8 → UTF-16 → Shift_JIS → Latin-1)
    static func readText(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    static func decode(_ data: Data) -> String? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let s = String(data: bytes, encoding: .utf8) { return s }
        if let s = String(data: bytes, encoding: shiftJIS) { return s }
        return String(data: bytes, encoding: .isoLatin1)
    }

    /// ID3 などで Shift_JIS が Latin-1 として解釈されて文字化けした文字列を復元する
    static func fixMojibake(_ s: String) -> String {
        let scalars = s.unicodeScalars
        guard scalars.contains(where: { $0.value >= 0x80 }),
              scalars.allSatisfy({ $0.value <= 0xFF }),
              let raw = s.data(using: .isoLatin1),
              let sjis = String(data: raw, encoding: shiftJIS),
              sjis.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) })
        else { return s }
        return sjis
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
