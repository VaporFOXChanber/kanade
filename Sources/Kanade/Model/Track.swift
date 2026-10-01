import Foundation

/// 再生キューの 1 項目。ファイル全体、または CUE シートで切り出された区間を表す。
struct Track: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    /// CUE トラックの開始・終了位置 (ファイル先頭からの秒)。nil ならファイル全体。
    var start: Double?
    var end: Double?
    var lyricsURL: URL?
    var folderArtURL: URL?
    var meta = TrackMeta()

    var fileName: String { url.lastPathComponent }
    var isCueTrack: Bool { start != nil }

    var displayTitle: String {
        if let t = meta.title, !t.isEmpty { return t }
        return Track.titleFromFileName(url)
    }

    var displayArtist: String {
        if let a = meta.artist, !a.isEmpty { return a }
        if let a = meta.albumArtist, !a.isEmpty { return a }
        return Track.artistFromFileName(url) ?? "不明なアーティスト"
    }

    var subtitle: String {
        [displayArtist, meta.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    /// 同じアルバムのトラックでアートワークを共有するためのキー
    var artworkKey: String {
        if let album = meta.album, !album.isEmpty {
            return "album:\(meta.albumArtist ?? meta.artist ?? "")|\(album)|\(url.deletingLastPathComponent().path)"
        }
        return "file:\(url.path)"
    }

    /// 再生時間 (CUE を考慮)
    var duration: Double? {
        if let s = start {
            if let e = end { return e - s }
            if let d = meta.fileDuration { return max(0, d - s) }
            return nil
        }
        return meta.fileDuration
    }

    /// キュー表示用: 曲名がアルバム名で始まっていれば、その部分を除いた「曲番号 + 曲名」を返す
    var titleWithoutAlbum: (number: Int?, title: String)? {
        let title = displayTitle
        // (アルバム名の候補, 残りが曲番号で始まる場合に限るか)
        var candidates: [(String, Bool)] = []
        if let album = meta.album?.nilIfBlank { candidates.append((album, false)) }
        let folder = url.deletingLastPathComponent().lastPathComponent
        candidates.append((folder, true))
        if let r = folder.range(of: " - ", options: .backwards) { candidates.append((String(folder[r.upperBound...]), true)) }

        for (album, needsNumber) in candidates {
            guard let rest = Self.remainder(of: title, afterPrefix: album) else { continue }
            let (number, name) = Self.splitTrackNumber(rest.text)
            if (needsNumber || rest.spaceOnly), number == nil { continue }
            return (meta.trackNumber ?? number, name)
        }
        return nil
    }

    /// `titleWithoutAlbum` を 1 行の文字列にしたもの (コントロールセンター用)。該当しなければ通常の曲名
    var shortTitle: String {
        guard let short = titleWithoutAlbum else { return displayTitle }
        return short.number.map { String(format: "%02d ", $0) + short.title } ?? short.title
    }

    private static let openBrackets: Set<Character> = ["[", "(", "【", "「", "『", "〔", "（", "［"]
    private static let separators: Set<Character> = [
        "-", "–", "—", "－", "_", "＿", ".", ":", "：", "・", "/", "／", "|", "~", "〜", "～",
        "]", ")", "】", "」", "』", "〕", "）", "］",
    ]

    /// `s` が `prefix` (大文字小文字・全角半角を区別しない) と区切り文字で始まっていれば、その後ろを返す
    private static func remainder(of s: String, afterPrefix prefix: String) -> (text: String, spaceOnly: Bool)? {
        guard prefix.count >= 2 else { return nil }
        var start = s.startIndex
        while start < s.endIndex, openBrackets.contains(s[start]) || s[start].isWhitespace { start = s.index(after: start) }
        guard let r = s.range(of: prefix, options: [.anchored, .caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                              range: start..<s.endIndex) else { return nil }
        var i = r.upperBound
        var sawSeparator = false, sawAny = false
        while i < s.endIndex, s[i].isWhitespace || separators.contains(s[i]) {
            if !s[i].isWhitespace { sawSeparator = true }
            sawAny = true
            i = s.index(after: i)
        }
        guard sawAny, i < s.endIndex else { return nil }
        return (String(s[i...]), !sawSeparator)
    }

    private static let trackNumberPattern = try! NSRegularExpression(
        pattern: #"^(?:\d{1,2}[-.])?(\d{1,3})(?:\s*[-._)）:：]\s*|\s+)(.+)$"#)

    /// "01 曲名" "01. 曲名" "1-03 - 曲名" → (番号, 曲名)
    private static func splitTrackNumber(_ s: String) -> (Int?, String) {
        let ns = s as NSString
        guard let m = trackNumberPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return (nil, s) }
        return (Int(ns.substring(with: m.range(at: 1))), ns.substring(with: m.range(at: 2)))
    }

    // MARK: ファイル名からの推測

    static func titleFromFileName(_ url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        // 先頭のトラック番号 "01 - ", "1-02. " などを除去
        if let r = stem.range(of: #"^\s*(\d{1,2}[-.])?\d{1,3}\s*[-._)\]]?\s+"#, options: .regularExpression) {
            let rest = String(stem[r.upperBound...])
            if !rest.isEmpty { stem = rest }
        }
        if let r = stem.range(of: " - ") {
            let rest = String(stem[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return stem
    }

    static func artistFromFileName(_ url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let r = stem.range(of: " - ") else { return nil }
        let head = String(stem[..<r.lowerBound])
            .replacingOccurrences(of: #"^\s*\d{1,3}\s*[-._]?\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return head.isEmpty ? nil : head
    }
}

struct TrackMeta: Codable, Hashable {
    var loaded = false
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: String?
    var trackNumber: Int?
    var discNumber: Int?
    /// ファイル全体の長さ
    var fileDuration: Double?

    // 技術情報
    var codec: String?
    var sampleRate: Double?
    var bitDepth: Int?
    var channels: Int?
    var bitrate: Int?
    var lossless: Bool?
    var fileSize: Int64?

    // ReplayGain (dB / リニアのピーク)
    var rgTrackGain: Double?
    var rgTrackPeak: Double?
    var rgAlbumGain: Double?
    var rgAlbumPeak: Double?

    var hasEmbeddedLyrics = false
    var embeddedCueSheet: String?

    /// "FLAC · 24bit / 96kHz · 3,142kbps" のような表示用の文字列
    var techBadges: [String] {
        var out: [String] = []
        if let c = codec { out.append(c) }
        var q: [String] = []
        if let b = bitDepth, b > 1 { q.append("\(b)bit") }
        if bitDepth == 1, let sr = sampleRate { q.append("DSD\(Int((sr * 8 / 44100).rounded()))") }
        if let sr = sampleRate, bitDepth != 1 {
            let k = sr / 1000
            q.append(k == k.rounded() ? "\(Int(k))kHz" : String(format: "%.1fkHz", k))
        }
        if !q.isEmpty { out.append(q.joined(separator: " / ")) }
        if let br = bitrate, br > 0 { out.append("\(br / 1000)kbps") }
        if let ch = channels, ch > 2 { out.append(ch == 6 ? "5.1ch" : ch == 8 ? "7.1ch" : "\(ch)ch") }
        return out
    }
}

enum RepeatMode: String, Codable, CaseIterable {
    case off, all, one

    var next: RepeatMode {
        switch self {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }
}

/// 再生画面の見た目
enum PlayerSkin: String, Codable, CaseIterable, Identifiable {
    case standard, turntable, cassette, cd, amp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: "スタンダード"
        case .turntable: "レコードプレイヤー"
        case .cassette: "カセットデッキ"
        case .cd: "ポータブル CD"
        case .amp: "アンプ（VU メーター）"
        }
    }
    var symbol: String {
        switch self {
        case .standard: "photo"
        case .turntable: "record.circle"
        case .cassette: "recordingtape"
        case .cd: "opticaldisc"
        case .amp: "gauge.with.needle"
        }
    }
    /// 同梱画像のフォルダ名 (Resources/Skins/...)
    var assetFolder: String { rawValue }
    var next: PlayerSkin {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum ReplayGainMode: String, Codable, CaseIterable, Identifiable {
    case off, track, album
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "オフ"
        case .track: "トラック"
        case .album: "アルバム"
        }
    }
}

enum VisualizerStyle: String, Codable, CaseIterable, Identifiable {
    case bars, mirror, wave, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .bars: "スペクトラム"
        case .mirror: "ミラー"
        case .wave: "波形"
        case .off: "オフ"
        }
    }
    var next: VisualizerStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

func formatTime(_ t: Double?) -> String {
    guard let t, t.isFinite, t >= 0 else { return "--:--" }
    let s = Int(t.rounded(.down))
    if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    return String(format: "%d:%02d", s / 60, s % 60)
}

func formatLongDuration(_ t: Double) -> String {
    let m = Int(t / 60)
    if m >= 60 { return "\(m / 60)時間\(m % 60)分" }
    return "\(m)分"
}
