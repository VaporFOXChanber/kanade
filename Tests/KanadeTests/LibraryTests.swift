import Foundation
import Testing
@testable import Kanade

@Suite("ライブラリ")
struct LibraryTests {
    private func track(_ path: String, title: String? = nil, artist: String? = nil, album: String? = nil,
                       albumArtist: String? = nil, number: Int? = nil, year: String? = nil, loaded: Bool = true) -> Track {
        var t = Track(url: URL(fileURLWithPath: path))
        t.meta.title = title
        t.meta.artist = artist
        t.meta.album = album
        t.meta.albumArtist = albumArtist
        t.meta.trackNumber = number
        t.meta.year = year
        t.meta.loaded = loaded
        t.meta.fileDuration = 100
        return t
    }

    @Test("曲をアルバムごとにまとめ、アーティスト → 年 → アルバム名の順に並べる")
    func groupsAlbums() {
        let albums = LibraryIndex.albums(from: [
            track("/m/b/2.flac", title: "B2", artist: "ビー", album: "二枚目", albumArtist: "ビー", number: 2, year: "2020"),
            track("/m/a/1.flac", title: "A1", artist: "エー", album: "アルバム", albumArtist: "エー", number: 1, year: "2019"),
            track("/m/b/1.flac", title: "B1", artist: "ビー", album: "二枚目", albumArtist: "ビー", number: 1, year: "2020"),
            track("/m/c/1.flac", title: "C1", artist: "ビー", album: "一枚目", albumArtist: "ビー", number: 1, year: "2018"),
        ])
        #expect(albums.map(\.title) == ["アルバム", "一枚目", "二枚目"])
        #expect(albums.map(\.artist) == ["エー", "ビー", "ビー"])
        #expect(albums[2].tracks.map(\.displayTitle) == ["B1", "B2"])      // トラック番号の順
        #expect(albums[2].duration == 200)
        #expect(albums[2].year == "2020")
    }

    @Test("タグのない作品は、作品のフォルダ名をアルバム名にする。形式ごとのフォルダは別のアルバムにする")
    func untaggedWorks() {
        let albums = LibraryIndex.albums(from: [
            track("/lib/x/RJ01234567 耳かき/mp3/01 はじめ.mp3"),
            track("/lib/x/RJ01234567 耳かき/mp3/02 おわり.mp3"),
            track("/lib/x/RJ01234567 耳かき/wav/01 はじめ.wav"),
            track("/lib/x/単品/サークル - 曲.mp3"),
        ])
        #expect(albums.map(\.title).sorted() == ["RJ01234567 耳かき / mp3", "RJ01234567 耳かき / wav", "単品"])
        let single = albums.first { $0.title == "単品" }
        #expect(single?.artist == "サークル")                                  // ファイル名の「アーティスト - 曲名」から
        #expect(albums.first { $0.title.hasSuffix("mp3") }?.artist == LibraryIndex.unknownArtist)
    }

    @Test("コンピレーション: アルバムアーティストがなければ、いちばん多いアーティストを使う")
    func compilationArtist() {
        let albums = LibraryIndex.albums(from: [
            track("/m/v/1.mp3", artist: "A", album: "Best"), track("/m/v/2.mp3", artist: "B", album: "Best"),
            track("/m/v/3.mp3", artist: "B", album: "Best"),
        ])
        #expect(albums.count == 1)
        #expect(albums[0].artist == "B")
    }

    @Test("アーティストごとにまとめる")
    func artists() {
        let albums = LibraryIndex.albums(from: [
            track("/m/a/1.flac", album: "A1", albumArtist: "エー"), track("/m/b/1.flac", album: "A2", albumArtist: "エー"),
            track("/m/c/1.flac", album: "B1", albumArtist: "ビー"),
        ])
        let artists = LibraryIndex.artists(from: albums)
        #expect(artists.map(\.name) == ["エー", "ビー"])
        #expect(artists[0].albums.map(\.title) == ["A1", "A2"])
    }

    @Test("検索: 空白で区切った語をすべて含むものを、曲名・アーティスト・アルバム・ファイル名から探す")
    func search() {
        let tracks = [
            track("/m/a/01 rain.flac", title: "雨の音", artist: "サークル A", album: "環境音集"),
            track("/m/a/02 fire.flac", title: "焚き火", artist: "サークル A", album: "環境音集"),
            track("/m/b/whisper.flac", title: "ささやき", artist: "サークル B", album: "耳もと"),
        ]
        #expect(LibraryIndex.search(tracks, "焚き火").map(\.displayTitle) == ["焚き火"])
        #expect(LibraryIndex.search(tracks, "サークル 環境").count == 2)
        #expect(LibraryIndex.search(tracks, "RAIN").map(\.displayTitle) == ["雨の音"])     // ファイル名、大文字小文字を区別しない
        #expect(LibraryIndex.search(tracks, "  ").count == 3)
        #expect(LibraryIndex.search(tracks, "ない").isEmpty)
        let albums = LibraryIndex.albums(from: tracks)
        #expect(LibraryIndex.search(albums, "ささやき").map(\.title) == ["耳もと"])        // 曲名でもアルバムが見つかる
    }

    @Test("調べ直し: 前からある曲はタグを使い回し、新しい曲と書き換えられた曲だけを読み直す。消えた曲は外す")
    func merge() {
        var library = LibraryData()
        let first = Date(timeIntervalSince1970: 1000), second = Date(timeIntervalSince1970: 2000)
        library.merge(scanned: [track("/m/a.mp3", loaded: false), track("/m/b.mp3", loaded: false)],
                      modified: ["/m/a.mp3": 1, "/m/b.mp3": 1], now: first)
        // タグを読み終えた状態にする
        library.tracks = library.tracks.map { var t = $0; t.meta.loaded = true; t.meta.title = "読み込み済み"; return t }
        let keyA = library.tracks[0].bookmarkKey

        library.merge(scanned: [track("/m/a.mp3", loaded: false), track("/m/b.mp3", loaded: false), track("/m/c.mp3", loaded: false)],
                      modified: ["/m/a.mp3": 1, "/m/b.mp3": 2, "/m/c.mp3": 1], now: second)
        #expect(library.tracks.map(\.fileName) == ["a.mp3", "b.mp3", "c.mp3"])
        #expect(library.tracks.map(\.meta.loaded) == [true, false, false])     // b は書き換えられた、c は新しい
        #expect(library.tracks[0].meta.title == "読み込み済み")
        #expect(library.added[keyA] == first)                                   // 入れた日時は最初のまま
        #expect(library.added[library.tracks[2].bookmarkKey] == second)

        library.merge(scanned: [track("/m/c.mp3", loaded: false)], modified: ["/m/c.mp3": 1], now: second)
        #expect(library.tracks.map(\.fileName) == ["c.mp3"])
        #expect(library.added.count == 1)
    }

    @Test("保存して読み直せる")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var library = LibraryData()
        library.folders = [URL(fileURLWithPath: "/m")]
        library.merge(scanned: [track("/m/a.mp3", title: "A")], modified: ["/m/a.mp3": 1])
        library.playlists = [Playlist(name: "寝る前", tracks: library.tracks)]
        library.save(to: dir)
        let loaded = LibraryData.load(from: dir)
        #expect(loaded.tracks == library.tracks)
        #expect(loaded.playlists.map(\.name) == ["寝る前"])
        #expect(loaded.folders == library.folders)
    }
}

@Suite("再生回数とお気に入り")
struct PlayStatsTests {
    @Test("曲の半分か 4 分を聴いたら、1 回の再生として数える")
    func countingRule() {
        #expect(!PlayStats.counts(listened: 59, duration: 120))
        #expect(PlayStats.counts(listened: 60, duration: 120))
        #expect(PlayStats.counts(listened: 240, duration: 3600))       // 長い音源は 4 分で数える
        #expect(!PlayStats.counts(listened: 239, duration: 3600))
        #expect(!PlayStats.counts(listened: 2, duration: 3))           // ごく短い音は 5 秒聴くまで数えない
        #expect(!PlayStats.counts(listened: 100, duration: 0))
    }

    @Test("再生回数・最後に再生した日時・お気に入りを覚える")
    func records() throws {
        var stats = PlayStats()
        let date = Date(timeIntervalSince1970: 5000)
        stats.recordPlay("a", at: date)
        stats.recordPlay("a", at: date.addingTimeInterval(10))
        stats.setFavorite("b", true)
        #expect(stats["a"].plays == 2)
        #expect(stats["a"].lastPlayed == date.addingTimeInterval(10))
        #expect(stats["b"].favorite && !stats["a"].favorite)
        #expect(stats["none"].plays == 0)
        stats.setFavorite("b", false)
        #expect(stats.entries["b"] == nil)                              // 何も残っていない曲は消す
        stats.setFavorite("a", true)
        stats.setFavorite("a", false)
        #expect(stats["a"].plays == 2)                                  // 再生回数は残る

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-stats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        stats.save(to: dir)
        #expect(PlayStats.load(from: dir) == stats)
    }
}
