import Foundation
import Testing
@testable import Kanade

@Suite("DLsite の作品情報")
struct DLsiteWorkTests {
    /// 作品情報の問い合わせの答えと同じ形の、架空のデータ
    private func response(voices: [String] = ["声優 一号", "声優 二号"], circle: String? = "架空サークル") -> Data {
        var work: [String: Any] = [
            "workno": "RJ01234567", "work_name": " 架空の作品 ", "regist_date": "2024-05-06 00:00:00",
            "creaters": ["voice_by": voices.map { ["id": "1", "name": $0, "classification": "voice_by"] },
                         "illust_by": [["id": "2", "name": "絵の人"]]],
        ]
        if let circle { work["maker_name"] = circle }
        return try! JSONSerialization.data(withJSONObject: [work])
    }

    @Test("答えから、作品名・サークル名・声優名・発売年を取り出す")
    func parses() throws {
        let work = try #require(DLsiteWork.parse(response()))
        #expect(work.title == "架空の作品")
        #expect(work.circle == "架空サークル")
        #expect(work.voices == ["声優 一号", "声優 二号"])
        #expect(work.year == "2024")
        #expect(!work.missing)
        #expect(work.artist == "声優 一号、声優 二号")
        // 同じ名前が重なっていたら 1 つにする。声優名のない作品は、サークル名をアーティストにする
        #expect(DLsiteWork.parse(response(voices: ["A", "A", " "]))?.voices == ["A"])
        #expect(DLsiteWork.parse(response(voices: []))?.artist == "架空サークル")
        #expect(DLsiteWork.parse(response(voices: [], circle: nil))?.artist == nil)
    }

    @Test("作品が見つからない答え (空の一覧) と、読めない答えを区別する")
    func missingAndBroken() throws {
        let missing = try #require(DLsiteWork.parse(Data("[]".utf8)))
        #expect(missing.missing)                                      // 見つからなかった: しばらく問い合わせ直さない
        #expect(DLsiteWork.parse(Data("<html>".utf8)) == nil)         // 読めなかった: 覚えずに、次の機会にまた問い合わせる
        #expect(DLsiteWork.parse(Data("{\"error\":1}".utf8)) == nil)
        #expect(DLsiteWork.infoURL(code: "RJ01234567")?.absoluteString == "https://www.dlsite.com/maniax/api/=/product.json?workno=RJ01234567")
    }

    @Test("タグが空の欄だけを埋める (アーティストに声優名、アルバムアーティストにサークル名)")
    func fillsOnlyBlanks() throws {
        let work = try #require(DLsiteWork.parse(response()))
        var blank = TrackMeta()
        #expect(DLsiteWork.wants(blank))
        #expect(work.fill(&blank))
        #expect(blank.artist == "声優 一号、声優 二号" && blank.albumArtist == "架空サークル" && blank.year == "2024")
        #expect(blank.album == nil)          // アルバム名は埋めない (フォルダごとのアルバム分けを変えないため)
        #expect(!DLsiteWork.wants(blank))
        #expect(!work.fill(&blank))          // もう埋めるところがない

        // タグに書いてある名前は変えない
        var tagged = TrackMeta()
        tagged.artist = "タグの名前"
        tagged.year = "1999"
        #expect(work.fill(&tagged))
        #expect(tagged.artist == "タグの名前" && tagged.year == "1999" && tagged.albumArtist == "架空サークル")

        // アルバムのタグがある曲は、アルバムアーティストを足さない (アルバムのまとめ方が変わってしまうため)
        var album = TrackMeta()
        album.album = "アルバム"
        album.artist = "誰か"
        #expect(!DLsiteWork.wants(album))
        _ = work.fill(&album)
        #expect(album.albumArtist == nil)

        // 見つからなかった作品では何もしない
        var untouched = TrackMeta()
        #expect(!DLsiteWork(missing: true).fill(&untouched) && untouched == TrackMeta())
    }
}
