import Foundation

// MARK: - CUE シート

struct CueSheet {
    struct Entry {
        var file: String
        var number: Int
        var title: String?
        var performer: String?
        var start: Double = 0
        var end: Double?
    }

    var title: String?
    var performer: String?
    var date: String?
    var genre: String?
    var entries: [Entry] = []

    var files: [String] {
        var seen = Set<String>()
        return entries.map(\.file).filter { seen.insert($0).inserted }
    }

    static func parse(_ text: String) -> CueSheet {
        var sheet = CueSheet()
        var file = ""
        var current: Entry?
        var index00: Double?

        func flush() {
            if var e = current {
                if e.start == 0, let i0 = index00 { e.start = i0 }
                sheet.entries.append(e)
            }
            current = nil
            index00 = nil
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let cmd = parts[0].uppercased()
            let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

            switch cmd {
            case "FILE":
                flush()
                if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
                    file = String(rest[rest.index(after: rest.startIndex)..<close])
                } else {
                    var words = rest.split(separator: " ").map(String.init)
                    if words.count > 1 { words.removeLast() }
                    file = words.joined(separator: " ")
                }
            case "TRACK":
                flush()
                let words = rest.split(separator: " ")
                let isAudio = words.count < 2 || words[1].uppercased() == "AUDIO"
                if isAudio { current = Entry(file: file, number: Int(words.first ?? "") ?? sheet.entries.count + 1) }
            case "TITLE":
                if current != nil { current?.title = unquote(rest) } else { sheet.title = unquote(rest) }
            case "PERFORMER":
                if current != nil { current?.performer = unquote(rest) } else { sheet.performer = unquote(rest) }
            case "INDEX":
                let words = rest.split(separator: " ")
                guard words.count >= 2, let t = parseTime(String(words[1])) else { break }
                if words[0] == "01" { current?.start = t } else if words[0] == "00" { index00 = t }
            case "REM":
                let words = rest.split(separator: " ", maxSplits: 1).map(String.init)
                guard words.count == 2 else { break }
                switch words[0].uppercased() {
                case "DATE": sheet.date = unquote(words[1])
                case "GENRE": sheet.genre = unquote(words[1])
                default: break
                }
            default: break
            }
        }
        flush()

        for i in sheet.entries.indices where i + 1 < sheet.entries.count {
            if sheet.entries[i + 1].file == sheet.entries[i].file {
                sheet.entries[i].end = sheet.entries[i + 1].start
            }
        }
        return sheet
    }

    private static func unquote(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\""), t.hasSuffix("\""), t.count >= 2 { t = String(t.dropFirst().dropLast()) }
        return TextDecoding.fixMojibake(t)
    }

    /// mm:ss:ff (1 秒 = 75 フレーム)
    private static func parseTime(_ s: String) -> Double? {
        let p = s.split(separator: ":").compactMap { Double($0) }
        guard p.count == 3 else { return nil }
        return p[0] * 60 + p[1] + p[2] / 75
    }
}

// MARK: - プレイリスト (M3U / M3U8 / PLS)

enum PlaylistFile {
    struct Entry {
        var location: String
        var title: String?
    }

    static func parse(_ text: String, ext: String) -> [Entry] {
        ext.lowercased() == "pls" ? parsePLS(text) : parseM3U(text)
    }

    private static func parseM3U(_ text: String) -> [Entry] {
        var out: [Entry] = []
        var title: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                title = line.split(separator: ",", maxSplits: 1).dropFirst().first.map(String.init)
                continue
            }
            if line.hasPrefix("#") { continue }
            out.append(Entry(location: line, title: title))
            title = nil
        }
        return out
    }

    private static func parsePLS(_ text: String) -> [Entry] {
        var files: [Int: String] = [:], titles: [Int: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let parts = raw.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            if key.hasPrefix("file"), let n = Int(key.dropFirst(4)) { files[n] = parts[1] }
            if key.hasPrefix("title"), let n = Int(key.dropFirst(5)) { titles[n] = parts[1] }
        }
        return files.keys.sorted().map { Entry(location: files[$0]!, title: titles[$0]) }
    }

    /// エントリをファイル URL に解決する (相対パス・file:// ・Windows 区切りに対応)
    static func resolve(_ location: String, relativeTo dir: URL) -> URL? {
        if let u = URL(string: location), u.isFileURL { return u }
        if location.contains("://") { return nil }
        let path = location.replacingOccurrences(of: "\\", with: "/")
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return dir.appendingPathComponent(path).standardizedFileURL
    }

    static func export(_ tracks: [Track]) -> String {
        var s = "#EXTM3U\n"
        var seen = Set<URL>()
        for t in tracks where seen.insert(t.url).inserted || t.isCueTrack == false {
            s += "#EXTINF:\(Int(t.duration ?? -1)),\(t.displayArtist) - \(t.displayTitle)\n\(t.url.path)\n"
        }
        return s
    }
}

// MARK: - 歌詞・字幕 (LRC / SRT / WebVTT)

struct Lyrics: Equatable {
    struct Line: Equatable, Identifiable {
        let id: Int
        let time: Double?
        /// 字幕 (SRT / WebVTT) の表示が終わる時刻。LRC にはない
        var end: Double? = nil
        let text: String
    }

    var lines: [Line]
    var synced: Bool

    /// LRC・SRT・WebVTT・ただのテキストを、中身から見分けて読む
    static func parse(_ source: String) -> Lyrics {
        // Windows の改行 (CRLF) をそのまま行に分けると、1 行ごとに空行が挟まってしまう
        let text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if let subtitles = parseSubtitles(text) { return subtitles }
        let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
        let word = try! NSRegularExpression(pattern: #"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>"#)
        var offset = 0.0
        var timed: [(Double, String)] = []
        var plain: [String] = []

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            if let m = line.range(of: #"^\[offset:\s*([+-]?\d+)\]"#, options: [.regularExpression, .caseInsensitive]) {
                offset = Double(line[m].filter { $0.isNumber || $0 == "-" || $0 == "+" }) ?? 0
                continue
            }
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                // [ar:...] などのタグ行は除外
                if line.range(of: #"^\[[a-zA-Z]+:.*\]$"#, options: .regularExpression) == nil { plain.append(line) }
                continue
            }
            let last = matches.last!.range
            var body = ns.substring(from: last.location + last.length)
            body = word.stringByReplacingMatches(in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
            body = body.trimmingCharacters(in: .whitespaces)
            for m in matches {
                let min = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")) ?? 0
                timed.append((max(0, min * 60 + sec - offset / 1000), body))
            }
        }

        if timed.isEmpty {
            while plain.first?.isEmpty == true { plain.removeFirst() }
            while plain.last?.isEmpty == true { plain.removeLast() }
            return Lyrics(lines: plain.enumerated().map { Line(id: $0.offset, time: nil, text: $0.element) }, synced: false)
        }
        timed.sort { $0.0 < $1.0 }
        return Lyrics(lines: timed.enumerated().map { Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }, synced: true)
    }

    // MARK: 字幕 (SRT / WebVTT)

    /// "00:01:02,500 --> 00:01:05,000" (SRT) / "01:02.500 --> 01:05.000 line:0" (WebVTT、時は省略できる)
    private static let cueTiming = try! NSRegularExpression(
        pattern: #"^\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})\s*-->\s*(?:(\d+):)?(\d{1,2}):(\d{1,2})[.,](\d{1,3})"#)
    /// <i> <font color=...> <v 話者> <c.class> <00:01.000> などのタグと、{\an8} のような位置指定
    private static let cueMarkup = try! NSRegularExpression(pattern: #"<[^>]*>|\{\\[^}]*\}"#)
    private static let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&quot;": "\"", "&#39;": "'", "&lrm;": "", "&rlm;": ""]

    /// SRT / WebVTT として読む。字幕が 1 つもなければ nil
    static func parseSubtitles(_ text: String) -> Lyrics? {
        let rows = text.components(separatedBy: .newlines)
        func timing(_ row: String) -> (Double, Double)? {
            let ns = row as NSString
            guard let m = cueTiming.firstMatch(in: row, range: NSRange(location: 0, length: ns.length)) else { return nil }
            func seconds(_ first: Int) -> Double {
                func part(_ i: Int) -> String { m.range(at: i).location == NSNotFound ? "0" : ns.substring(with: m.range(at: i)) }
                let whole = (Double(part(first)) ?? 0) * 3600 + (Double(part(first + 1)) ?? 0) * 60 + (Double(part(first + 2)) ?? 0)
                return whole + (Double("0." + part(first + 3)) ?? 0)
            }
            return (seconds(1), seconds(5))
        }

        var cues: [(start: Double, end: Double, text: String)] = []
        var i = 0
        while i < rows.count {
            guard let (start, end) = timing(rows[i]) else { i += 1; continue }
            i += 1
            var body: [String] = []
            while i < rows.count, !rows[i].trimmingCharacters(in: .whitespaces).isEmpty, timing(rows[i]) == nil {
                // 空行なしで次の字幕が続いている場合、その通し番号は本文に入れない
                if i + 1 < rows.count, timing(rows[i + 1]) != nil, Int(rows[i].trimmingCharacters(in: .whitespaces)) != nil { break }
                body.append(clean(rows[i]))
                i += 1
            }
            let joined = body.filter { !$0.isEmpty }.joined(separator: "\n")
            if !joined.isEmpty { cues.append((start, max(start, end), joined)) }
        }
        guard !cues.isEmpty else { return nil }
        cues.sort { $0.start < $1.start }
        return Lyrics(lines: cues.enumerated().map { Line(id: $0.offset, time: $0.element.start, end: $0.element.end, text: $0.element.text) },
                      synced: true)
    }

    private static func clean(_ row: String) -> String {
        var out = cueMarkup.stringByReplacingMatches(in: row, range: NSRange(location: 0, length: (row as NSString).length), withTemplate: "")
        for (entity, character) in entities { out = out.replacingOccurrences(of: entity, with: character) }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// その行を今も表示しているか。字幕は終わりの時刻を過ぎたら消す (LRC は次の行まで出したまま)
    func isActive(_ index: Int, at time: Double) -> Bool {
        guard lines.indices.contains(index), let end = lines[index].end else { return true }
        return time <= end + 0.3
    }

    /// 再生位置に対応する行
    func index(at time: Double) -> Int? {
        guard synced else { return nil }
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if let t = lines[mid].time, t <= time + 0.15 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}
