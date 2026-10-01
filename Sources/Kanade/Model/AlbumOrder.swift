import Foundation

/// アルバムの中での曲の位置。タグがなければファイル名やフォルダ名から推測する
struct AlbumPosition: Equatable {
    /// 同じアルバムの曲どうしで同じになるキー
    var album: String
    var disc: Int
    /// 番号が分からない曲は nil
    var track: Int?
}

extension Track {
    var albumPosition: AlbumPosition {
        let named = Self.numberInFileName(url)
        let folder = Self.albumFolder(of: url)
        return AlbumPosition(album: albumKey(folder: folder.url),
                             disc: meta.discNumber ?? named?.disc ?? folder.disc ?? 1,
                             track: meta.trackNumber ?? named?.track ?? titleWithoutAlbum?.number)
    }

    private func albumKey(folder: URL) -> String {
        guard let album = meta.album?.nilIfBlank else {
            // タグのない CUE イメージは 1 ファイルで 1 枚のアルバム
            return isCueTrack ? "file:\(url.path)" : "folder:\(folder.path)"
        }
        let name = Self.folded(album)
        // アルバムアーティストがあれば、ディスクごとにフォルダが分かれていても 1 枚にまとめる。
        // なければ、別のアーティストの同名アルバムが混ざらないようにフォルダでも分ける
        if let artist = meta.albumArtist?.nilIfBlank { return "album:\(name)|\(Self.folded(artist))" }
        return "album:\(name)|folder:\(folder.path)"
    }

    private static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    private static let discFolderPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:disc|disk|cd|ディスク)[\s._-]*(\d{1,2})(?!\d)"#, options: .caseInsensitive)

    /// アルバムのフォルダ。"Disc 2" のようなフォルダに入っていれば、その親とディスク番号を返す
    private static func albumFolder(of url: URL) -> (url: URL, disc: Int?) {
        let dir = url.deletingLastPathComponent()
        let name = folded(dir.lastPathComponent) as NSString
        guard let m = discFolderPattern.firstMatch(in: name as String, range: NSRange(location: 0, length: name.length)),
              let disc = Int(name.substring(with: m.range(at: 1))) else { return (dir, nil) }
        return (dir.deletingLastPathComponent(), disc)
    }

    private static let fileNumberPattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:track|tr|トラック)[\s._-]*|#)?(?:(\d{1,2})[-.](?=\d{2}))?(\d{1,3})(?:[\s\-._)\]】:]|$)"#,
        options: .caseInsensitive)

    /// "01 曲名" "03_曲名" "1-03 曲名" "トラック2 曲名" → (ディスク, トラック)
    static func numberInFileName(_ url: URL) -> (disc: Int?, track: Int)? {
        let stem = folded(url.deletingPathExtension().lastPathComponent) as NSString
        guard let m = fileNumberPattern.firstMatch(in: stem as String, range: NSRange(location: 0, length: stem.length)),
              let track = Int(stem.substring(with: m.range(at: 2))) else { return nil }
        let disc = m.range(at: 1).location == NSNotFound ? nil : Int(stem.substring(with: m.range(at: 1)))
        return (disc, track)
    }
}

extension Array where Element == Track {
    /// アルバムごとにまとめ、その中をディスク → トラック番号の順に並べる。
    /// アルバムの順番は、それぞれの最初の曲が今の並びで出てくる順のまま。
    /// 番号の分からない曲は、同じディスクの番号のある曲の後ろにファイル名の順で並べる。
    func inAlbumTrackOrder() -> [Track] {
        var firstSeen: [String: Int] = [:]
        let keyed = enumerated().map { index, track in
            let position = track.albumPosition
            let group = firstSeen[position.album] ?? index
            firstSeen[position.album] = group
            return (track: track, position: position, group: group, index: index)
        }
        return keyed.sorted { a, b in
            if a.group != b.group { return a.group < b.group }
            if a.position.disc != b.position.disc { return a.position.disc < b.position.disc }
            if a.position.track != b.position.track {
                return (a.position.track ?? .max) < (b.position.track ?? .max)
            }
            let byName = a.track.url.path.localizedStandardCompare(b.track.url.path)
            if byName != .orderedSame { return byName == .orderedAscending }
            if a.track.start != b.track.start { return (a.track.start ?? 0) < (b.track.start ?? 0) }
            return a.index < b.index
        }.map(\.track)
    }
}
