import Foundation

/// ライブラリの中の 1 枚のアルバム (同人音声では 1 つの作品、またはその中の 1 つのフォルダ)
struct LibraryAlbum: Identifiable, Equatable {
    /// アルバムを見分けるキー (AlbumPosition.album)
    var id: String
    var title: String
    var artist: String
    var year: String?
    /// ディスク → トラック番号の順
    var tracks: [Track]

    var duration: Double { tracks.reduce(0) { $0 + ($1.duration ?? 0) } }
}

/// 名前を付けて保存した曲の並び
struct Playlist: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var tracks: [Track]
    var created = Date()
}

/// ライブラリの曲から、アルバム・アーティストごとの一覧を作る
enum LibraryIndex {
    static let unknownArtist = "不明なアーティスト"

    /// 曲をアルバムごとにまとめる。並びはアーティスト名 → 年 → アルバム名
    static func albums(from tracks: [Track]) -> [LibraryAlbum] {
        var groups: [String: [Track]] = [:]
        var order: [String] = []
        for track in tracks {
            let key = track.albumPosition.album
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }
        let albums = order.map { key -> LibraryAlbum in
            let sorted = groups[key]!.inAlbumTrackOrder()
            return LibraryAlbum(id: key, title: title(of: sorted), artist: artist(of: sorted),
                                year: sorted.compactMap(\.meta.year).first, tracks: sorted)
        }
        return albums.sorted {
            let byArtist = $0.artist.localizedStandardCompare($1.artist)
            if byArtist != .orderedSame { return byArtist == .orderedAscending }
            if $0.year != $1.year { return ($0.year ?? "") < ($1.year ?? "") }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    /// アルバム名。タグがなければ作品のフォルダ名を使い、その中の一部なら「作品名 / mp3」のようにする
    private static func title(of tracks: [Track]) -> String {
        if let album = tracks.lazy.compactMap({ $0.meta.album?.nilIfBlank }).first { return album }
        guard let first = tracks.first else { return "" }
        let work = ArtworkFinder.workFolder(for: first.url)
        var folder = first.url.deletingLastPathComponent()
        var parts: [String] = []
        while folder.path != work.path, folder.path.count > work.path.count {
            parts.insert(folder.lastPathComponent, at: 0)
            folder = folder.deletingLastPathComponent()
        }
        return ([work.lastPathComponent] + parts).joined(separator: " / ")
    }

    /// アルバムのアーティスト: アルバムアーティストのタグ、なければいちばん多いアーティスト
    private static func artist(of tracks: [Track]) -> String {
        if let albumArtist = tracks.lazy.compactMap({ $0.meta.albumArtist?.nilIfBlank }).first { return albumArtist }
        var counts: [String: Int] = [:]
        for t in tracks {
            if let a = t.meta.artist?.nilIfBlank ?? Track.artistFromFileName(t.url) { counts[a, default: 0] += 1 }
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? unknownArtist
    }

    /// アーティストごとのアルバム。名前の順
    static func artists(from albums: [LibraryAlbum]) -> [(name: String, albums: [LibraryAlbum])] {
        var groups: [String: [LibraryAlbum]] = [:]
        for album in albums { groups[album.artist, default: []].append(album) }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { ($0, groups[$0]!) }
    }

    /// 曲名・アーティスト・アルバム・ファイル名のどれかに、検索語がすべて含まれる曲 (空白で区切ると、すべてを含むもの)
    static func search(_ tracks: [Track], _ query: String) -> [Track] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return tracks }
        return tracks.filter { t in
            let fields = [t.displayTitle, t.displayArtist, t.meta.album ?? "", t.fileName]
            return words.allSatisfy { w in fields.contains { $0.localizedCaseInsensitiveContains(w) } }
        }
    }

    static func search(_ albums: [LibraryAlbum], _ query: String) -> [LibraryAlbum] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return albums }
        return albums.filter { a in
            words.allSatisfy { w in
                a.title.localizedCaseInsensitiveContains(w) || a.artist.localizedCaseInsensitiveContains(w)
                    || a.tracks.contains { $0.displayTitle.localizedCaseInsensitiveContains(w) }
            }
        }
    }
}

/// ライブラリの保存内容 (Application Support/Kanade/library.json)
struct LibraryData: Codable, Equatable {
    /// 読み込むフォルダ
    var folders: [URL] = []
    var tracks: [Track] = []
    /// 曲をライブラリに入れた日時 (Track.bookmarkKey → 日時)
    var added: [String: Date] = [:]
    /// ファイルの更新日時 (パス → 秒)。変わっていたらタグを読み直す
    var modified: [String: Double] = [:]
    var playlists: [Playlist] = []

    /// フォルダを調べ直した結果を取り込む。
    /// 前からある曲は読み込み済みのタグをそのまま使い、新しい曲と書き換えられた曲だけを「未読み込み」にする
    mutating func merge(scanned: [Track], modified newModified: [String: Double], now: Date = Date()) {
        var known: [String: Track] = [:]
        for t in tracks { known[t.bookmarkKey] = t }
        var merged: [Track] = []
        var seen = Set<String>()
        for var t in scanned {
            let key = t.bookmarkKey
            guard seen.insert(key).inserted else { continue }
            let unchanged = modified[t.url.path] == newModified[t.url.path]
            if let old = known[key], unchanged, old.meta.loaded {
                let (lyrics, art) = (t.lyricsURL, t.folderArtURL)
                t = old
                t.lyricsURL = lyrics
                t.folderArtURL = art
            }
            if added[key] == nil { added[key] = now }
            merged.append(t)
        }
        tracks = merged
        modified = newModified
        added = added.filter { seen.contains($0.key) }
    }

    static func load(from dir: URL) -> LibraryData {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("library.json")),
              let library = try? JSONDecoder().decode(LibraryData.self, from: data) else { return LibraryData() }
        return library
    }

    func save(to dir: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: dir.appendingPathComponent("library.json"), options: .atomic)
    }
}
