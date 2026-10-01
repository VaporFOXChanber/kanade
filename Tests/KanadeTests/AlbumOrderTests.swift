import Foundation
import Testing
@testable import Kanade

/// 再生キューの「アルバムのトラック順」のテスト
@Suite("アルバムのトラック順")
struct AlbumOrderTests {
    private func track(_ path: String, album: String? = nil, albumArtist: String? = nil,
                       disc: Int? = nil, number: Int? = nil, start: Double? = nil) -> Track {
        var t = Track(url: URL(fileURLWithPath: path), start: start)
        t.meta.album = album
        t.meta.albumArtist = albumArtist
        t.meta.discNumber = disc
        t.meta.trackNumber = number
        return t
    }

    private func names(_ tracks: [Track]) -> [String] { tracks.map(\.fileName) }

    @Test("タグのディスク番号・トラック番号の順に並ぶ")
    func ordersByDiscAndTrackTags() {
        let queue = [
            track("/m/a/c.flac", album: "夜", albumArtist: "奏", disc: 2, number: 1),
            track("/m/a/a.flac", album: "夜", albumArtist: "奏", disc: 1, number: 10),
            track("/m/a/d.flac", album: "夜", albumArtist: "奏", disc: 1, number: 2),
            track("/m/a/b.flac", album: "夜", albumArtist: "奏", disc: 1, number: 1),
        ]
        #expect(names(queue.inAlbumTrackOrder()) == ["b.flac", "d.flac", "a.flac", "c.flac"])
    }

    @Test("アルバムの順番は変えず、混ざっていた曲をアルバムごとにまとめる")
    func keepsAlbumOrder() {
        let queue = [
            track("/m/z/2.flac", album: "Z", albumArtist: "奏", number: 2),
            track("/m/a/2.flac", album: "A", albumArtist: "奏", number: 2),
            track("/m/z/1.flac", album: "Z", albumArtist: "奏", number: 1),
            track("/m/a/1.flac", album: "A", albumArtist: "奏", number: 1),
        ]
        #expect(queue.inAlbumTrackOrder().map(\.url.path) == ["/m/z/1.flac", "/m/z/2.flac", "/m/a/1.flac", "/m/a/2.flac"])
    }

    @Test("タグがなければ、フォルダをアルバムとみなしてファイル名の番号で並べる")
    func fallsBackToFileNames() {
        let queue = [
            track("/m/作品/10 おやすみ.wav"),
            track("/m/作品/おまけ.wav"),
            track("/m/作品/2_耳かき.wav"),
            track("/m/別の作品/01 はじめに.wav"),
            track("/m/作品/01 はじめに.wav"),
        ]
        #expect(queue.inAlbumTrackOrder().map(\.url.path) == [
            "/m/作品/01 はじめに.wav", "/m/作品/2_耳かき.wav", "/m/作品/10 おやすみ.wav", "/m/作品/おまけ.wav",
            "/m/別の作品/01 はじめに.wav",
        ])
    }

    @Test("ファイル名の先頭の番号を読む", arguments: [
        ("01 曲名.flac", nil, 1), ("03_曲名.mp3", nil, 3), ("7. 曲名.mp3", nil, 7), ("1-03 曲名.flac", 1, 3),
        ("トラック2 曲名.wav", nil, 2), ("Track 12.wav", nil, 12), ("#4 曲名.wav", nil, 4), ("０５ 曲名.wav", nil, 5),
    ] as [(String, Int?, Int)])
    func readsNumberInFileName(name: String, disc: Int?, number: Int) throws {
        let found = try #require(Track.numberInFileName(URL(fileURLWithPath: "/m/" + name)))
        #expect(found.disc == disc)
        #expect(found.track == number)
    }

    @Test("番号ではない数字は読まない", arguments: ["3年目の春.mp3", "2024-01-05 録音.wav", "1999.mp3", "曲名 01.mp3"])
    func ignoresOtherDigits(name: String) {
        #expect(Track.numberInFileName(URL(fileURLWithPath: "/m/" + name)) == nil)
    }

    @Test("Disc フォルダに分かれたアルバムは 1 枚にまとめ、ディスクの順に並べる")
    func mergesDiscFolders() {
        let queue = [
            track("/m/作品/Disc 2/01 後編.wav"),
            track("/m/作品/Disc 1/02 中編.wav"),
            track("/m/作品/Disc 1/01 前編.wav"),
        ]
        let sorted = queue.inAlbumTrackOrder()
        #expect(names(sorted) == ["01 前編.wav", "02 中編.wav", "01 後編.wav"])
        #expect(Set(sorted.map(\.albumPosition.album)).count == 1)
        #expect(sorted.map(\.albumPosition.disc) == [1, 1, 2])
    }

    @Test("アルバムアーティストのない同名アルバムは、フォルダが違えば別のアルバム")
    func separatesSameNamedAlbums() {
        let queue = [
            track("/m/x/02.mp3", album: "Best", number: 2),
            track("/m/y/01.mp3", album: "Best", number: 1),
            track("/m/x/01.mp3", album: "Best", number: 1),
        ]
        #expect(queue.inAlbumTrackOrder().map(\.url.path) == ["/m/x/01.mp3", "/m/x/02.mp3", "/m/y/01.mp3"])
    }

    @Test("CUE で切り出した曲は、番号がなくても開始位置の順に並ぶ")
    func ordersCueTracksByStart() {
        let queue = [
            track("/m/image.flac", start: 300),
            track("/m/image.flac", start: 0),
            track("/m/image.flac", start: 120),
        ]
        #expect(queue.inAlbumTrackOrder().map(\.start) == [0, 120, 300])
    }
}
