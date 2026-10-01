import Foundation

/// ドロップ・「開く」で渡された URL 群を再生キュー用のトラックに展開する。
///  - フォルダは再帰的に探索 (Finder と同じ自然順)
///  - CUE シートがあれば 1 ファイルを複数トラックに分割
///  - 同名の .lrc / .srt / .vtt を歌詞・字幕として、cover.jpg などをジャケットとして関連付け
///  - M3U / M3U8 / PLS プレイリストを展開
enum Importer {
    static let mediaExtensions: Set<String> = [
        "mp3", "mp2", "mp1", "mpa", "m4a", "m4b", "m4p", "aac", "adts", "flac", "fla", "ogg", "oga", "ogx", "opus", "spx",
        "wav", "wave", "bwf", "w64", "rf64", "aif", "aiff", "aifc", "caf", "wma", "asf", "ape", "wv", "tta", "tak", "mpc",
        "mp+", "mpp", "ofr", "ofs", "shn", "dsf", "dff", "ac3", "eac3", "ec3", "dts", "dtshd", "thd", "mlp", "truehd", "amr",
        "awb", "3gp", "3g2", "mka", "mkv", "webm", "weba", "mp4", "m4v", "mov", "avi", "flv", "wmv", "ts", "m2ts", "mts",
        "mpg", "mpeg", "vob", "au", "snd", "voc", "xwma", "ra", "rm", "rmvb", "gsm",
    ]
    static let playlistExtensions: Set<String> = ["m3u", "m3u8", "pls"]
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "gif", "bmp", "tif", "tiff"]
    static let coverNames = ["cover", "folder", "front", "album", "albumart", "jacket", "artwork", "albumartsmall"]
    /// 歌詞・字幕として読むファイル。同じ曲に複数あれば、前にあるものを優先する
    static let lyricsExtensions = ["lrc", "srt", "vtt"]

    struct Result {
        var tracks: [Track] = []
        var skipped = 0
    }

    static func expand(_ urls: [URL]) -> Result {
        var files: [URL] = []
        var explicit = Set<URL>()
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
                var found: [URL] = []
                while let f = e?.nextObject() as? URL {
                    if (try? f.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { found.append(f) }
                }
                found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                files += found
            } else {
                files.append(url)
                explicit.insert(url)
            }
        }
        return build(files: files, explicit: explicit)
    }

    private static func build(files: [URL], explicit: Set<URL>) -> Result {
        var result = Result()
        let byDir = Dictionary(grouping: files) { $0.deletingLastPathComponent() }

        // フォルダごとの補助ファイル
        var lyrics = lyricsIndex(files)
        var covers: [URL: URL] = [:]
        for (dir, list) in byDir {
            for f in list {
                let ext = f.pathExtension.lowercased()
                let stem = f.deletingPathExtension().lastPathComponent.lowercased()
                if imageExtensions.contains(ext), covers[dir] == nil || coverNames.first == stem,
                   coverNames.contains(where: { stem.hasPrefix($0) }) {
                    covers[dir] = f
                }
            }
        }
        // 明示的に 1 曲だけ開かれた場合も、同じフォルダの歌詞・字幕 / cover を拾う
        for f in explicit where !lyricsExtensions.contains(f.pathExtension.lowercased()) {
            let dir = f.deletingLastPathComponent()
            if lyrics[lyricsKey(for: f)] == nil, let found = sidecarLyrics(for: f) { lyrics[lyricsKey(for: f)] = found }
            if covers[dir] == nil { covers[dir] = findCover(in: dir) }
        }

        func decorate(_ t: inout Track) {
            let dir = t.url.deletingLastPathComponent()
            if t.start == nil { t.lyricsURL = lyrics[lyricsKey(for: t.url)] }
            t.folderArtURL = covers[dir]
        }

        // CUE シートで使われるファイルを先に特定
        var cueTracks: [URL: [Track]] = [:]
        var consumed = Set<URL>()
        for cue in files where cue.pathExtension.lowercased() == "cue" {
            guard let text = TextDecoding.readText(at: cue) else { continue }
            let sheet = CueSheet.parse(text)
            let dir = cue.deletingLastPathComponent()
            let siblings = byDir[dir] ?? []
            for fileName in sheet.files {
                guard let media = resolveCueFile(fileName, cue: cue, siblings: siblings) else { continue }
                consumed.insert(media)
                var list: [Track] = []
                for e in sheet.entries where e.file == fileName {
                    var t = Track(url: media, start: e.start, end: e.end)
                    t.meta.title = e.title
                    t.meta.artist = e.performer ?? sheet.performer
                    t.meta.albumArtist = sheet.performer
                    t.meta.album = sheet.title
                    t.meta.trackNumber = e.number
                    t.meta.year = sheet.date
                    t.meta.genre = sheet.genre
                    decorate(&t)
                    list.append(t)
                }
                cueTracks[media, default: []] += list
            }
        }

        for f in files {
            let ext = f.pathExtension.lowercased()
            if let list = cueTracks.removeValue(forKey: f) {
                result.tracks += list
            } else if consumed.contains(f) {
                continue
            } else if mediaExtensions.contains(ext) || (explicit.contains(f) && !["cue", "lrc", "srt", "vtt", "txt"].contains(ext) && !playlistExtensions.contains(ext) && !imageExtensions.contains(ext)) {
                var t = Track(url: f)
                decorate(&t)
                result.tracks.append(t)
            } else if playlistExtensions.contains(ext) {
                guard let text = TextDecoding.readText(at: f) else { continue }
                let dir = f.deletingLastPathComponent()
                for entry in PlaylistFile.parse(text, ext: ext) {
                    guard let u = PlaylistFile.resolve(entry.location, relativeTo: dir),
                          FileManager.default.fileExists(atPath: u.path) else { result.skipped += 1; continue }
                    var t = Track(url: u)
                    if let title = entry.title, let r = title.range(of: " - ") {
                        t.meta.artist = String(title[..<r.lowerBound])
                        t.meta.title = String(title[r.upperBound...])
                    }
                    let c = findCover(in: u.deletingLastPathComponent())
                    t.folderArtURL = c
                    t.lyricsURL = sidecarLyrics(for: u)
                    result.tracks.append(t)
                }
            } else if !["cue", "lrc", "srt", "vtt", "txt", "log", "nfo", "md5", "sfv", "accurip", "m3u", "ds_store"].contains(ext),
                      !imageExtensions.contains(ext) {
                result.skipped += 1
            }
        }
        return result
    }

    private static func resolveCueFile(_ name: String, cue: URL, siblings: [URL]) -> URL? {
        let dir = cue.deletingLastPathComponent()
        let direct = dir.appendingPathComponent(name.replacingOccurrences(of: "\\", with: "/"))
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let media = siblings.filter { mediaExtensions.contains($0.pathExtension.lowercased()) }
        let lower = (name as NSString).lastPathComponent.lowercased()
        if let m = media.first(where: { $0.lastPathComponent.lowercased() == lower }) { return m }
        // CUE の拡張子と実ファイルが異なる (album.wav → album.flac) ケース
        let stem = (lower as NSString).deletingPathExtension
        if let m = media.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == stem }) { return m }
        let cueStem = cue.deletingPathExtension().lastPathComponent.lowercased()
        if let m = media.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == cueStem }) { return m }
        return media.count == 1 ? media[0] : nil
    }

    // MARK: 歌詞・字幕ファイル

    /// 曲のファイルに対応する歌詞・字幕を引くためのキー (フォルダ + 拡張子を除いた名前)
    static func lyricsKey(for audio: URL) -> String {
        audio.deletingLastPathComponent().path + "/" + audio.deletingPathExtension().lastPathComponent.lowercased()
    }

    /// ファイルの一覧から、曲 → 歌詞・字幕ファイル の対応を作る。
    /// 「曲名.srt」のほか、「曲名.wav.vtt」(音源のファイル名に付け足した名前) や「曲名.ja.srt」(言語つき) も拾う。
    /// 同じ曲に複数あれば、名前がそのまま一致するものを、次に lyricsExtensions の順で優先する
    static func lyricsIndex(_ files: [URL]) -> [String: URL] {
        var best: [String: (url: URL, rank: Int)] = [:]
        for f in files {
            guard let order = lyricsExtensions.firstIndex(of: f.pathExtension.lowercased()) else { continue }
            let dir = f.deletingLastPathComponent().path
            var stem = f.deletingPathExtension().lastPathComponent.lowercased()
            var stripped = 0
            while true {
                let rank = stripped * 10 + order
                let key = dir + "/" + stem
                if rank < best[key]?.rank ?? .max { best[key] = (f, rank) }
                // 末尾の「.wav」のような音源の拡張子や、「.ja」「.zh-tw」のような言語の指定を外した名前でも探す
                let suffix = (stem as NSString).pathExtension
                guard stripped < 2, !suffix.isEmpty,
                      mediaExtensions.contains(suffix) || suffix.range(of: #"^[a-z]{2,3}(-[a-z0-9]{2,4})?$"#, options: .regularExpression) != nil
                else { break }
                stem = (stem as NSString).deletingPathExtension
                stripped += 1
            }
        }
        return best.mapValues(\.url)
    }

    /// 曲と同じフォルダにある歌詞・字幕ファイルを探す
    static func sidecarLyrics(for audio: URL) -> URL? {
        let dir = audio.deletingLastPathComponent()
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        // 一覧は実際のパス表記で返るので、フォルダは曲の URL のものに合わせてからキーを引く
        let siblings = items.map { dir.appendingPathComponent($0.lastPathComponent) }
        return lyricsIndex(siblings)[lyricsKey(for: audio)]
    }

    static func findCover(in dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let images = items.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        for name in coverNames {
            if let m = images.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased().hasPrefix(name) }) { return m }
        }
        return nil
    }

    /// FLAC などに埋め込まれた CUESHEET タグから、トラックを分割する
    static func splitEmbeddedCue(_ track: Track) -> [Track]? {
        guard !track.isCueTrack, let text = track.meta.embeddedCueSheet else { return nil }
        let sheet = CueSheet.parse(text)
        guard sheet.entries.count > 1 else { return nil }
        return sheet.entries.map { e in
            var t = Track(url: track.url, start: e.start, end: e.end, folderArtURL: track.folderArtURL, meta: track.meta)
            t.meta.title = e.title ?? track.meta.title
            t.meta.artist = e.performer ?? sheet.performer ?? track.meta.artist
            t.meta.album = sheet.title ?? track.meta.album
            t.meta.trackNumber = e.number
            t.meta.embeddedCueSheet = nil
            return t
        }
    }
}
