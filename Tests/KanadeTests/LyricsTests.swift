import Foundation
import Testing
@testable import Kanade

@Suite("歌詞・字幕の読み込み")
struct LyricsTests {
    @Test("SRT: 番号・時刻・複数行の本文を読み、タグを取り除く")
    func srt() {
        let text = """
        \u{FEFF}1
        00:00:01,500 --> 00:00:04,000
        こんばんは
        今日もおつかれさま

        2
        00:01:05,250 --> 00:01:08,000
        <i>ゆっくり</i>していってね {\\an8}

        3
        01:00:00,000 --> 01:00:02,000
        <font color="#ffffff">おやすみ</font>
        """
        let lyrics = Lyrics.parse(text)
        #expect(lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["こんばんは\n今日もおつかれさま", "ゆっくりしていってね", "おやすみ"])
        #expect(lyrics.lines.map(\.time) == [1.5, 65.25, 3600])
        #expect(lyrics.lines.map(\.end) == [4, 68, 3602])
    }

    @Test("SRT: Windows の改行 (CRLF) や、空行なしで続く字幕でも読める")
    func srtVariants() {
        let crlf = "1\r\n00:00:01,000 --> 00:00:02,000\r\n一行目\r\n二行目\r\n\r\n2\r\n00:00:03,000 --> 00:00:04,000\r\n次\r\n"
        #expect(Lyrics.parse(crlf).lines.map(\.text) == ["一行目\n二行目", "次"])

        let tight = "1\n00:00:01,000 --> 00:00:02,000\nひとつめ\n2\n00:00:03,000 --> 00:00:04,000\nふたつめ"
        #expect(Lyrics.parse(tight).lines.map(\.text) == ["ひとつめ", "ふたつめ"])
    }

    @Test("WebVTT: 見出し・注釈・スタイルを飛ばし、時を省いた時刻や位置の指定つきの字幕を読む")
    func vtt() {
        let text = """
        WEBVTT - サンプル

        NOTE これは注釈
        字幕には出ない

        STYLE
        ::cue { color: white }

        intro
        00:01.000 --> 00:03.500 line:0 position:50%
        <v 先輩>ねえ、聞こえる？</v>

        00:00:10.000 --> 00:00:12.000
        右 &amp; 左 <00:00:11.000><c.loud>両方</c>

        2
        01:02:03.250 --> 01:02:04.000
        おわり
        """
        let lyrics = Lyrics.parse(text)
        #expect(lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["ねえ、聞こえる？", "右 & 左 両方", "おわり"])
        #expect(lyrics.lines.map(\.time) == [1, 10, 3723.25])
        #expect(lyrics.lines.map(\.end) == [3.5, 12, 3724])
    }

    @Test("字幕は時刻の順に並べ、本文のない字幕は捨てる")
    func sortsAndDropsEmpty() {
        let text = """
        WEBVTT

        00:10.000 --> 00:11.000
        あと

        00:05.000 --> 00:06.000
        <i></i>

        00:01.000 --> 00:02.000
        さき
        """
        let lyrics = Lyrics.parse(text)
        #expect(lyrics.lines.map(\.text) == ["さき", "あと"])
        #expect(lyrics.lines.map(\.id) == [0, 1])
    }

    @Test("字幕は終わりの時刻を過ぎると、次の字幕まで表示を消す")
    func activeRange() {
        let lyrics = Lyrics.parse("1\n00:00:01,000 --> 00:00:03,000\na\n\n2\n00:00:10,000 --> 00:00:12,000\nb")
        #expect(lyrics.index(at: 0) == nil)
        #expect(lyrics.index(at: 2) == 0)
        #expect(lyrics.isActive(0, at: 2))
        #expect(lyrics.index(at: 6) == 0)          // 位置 (スクロール) は前の字幕のまま
        #expect(!lyrics.isActive(0, at: 6))        // 強調は消す
        #expect(lyrics.index(at: 10.5) == 1)
        #expect(lyrics.isActive(1, at: 10.5))
    }

    @Test("LRC はこれまでどおり読み、次の行まで表示したままにする")
    func lrcUnchanged() {
        let lyrics = Lyrics.parse("[ti:曲名]\n[00:01.00]一行目\n[00:05.50]二行目\n")
        #expect(lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["一行目", "二行目"])
        #expect(lyrics.lines.map(\.time) == [1, 5.5])
        #expect(lyrics.lines.allSatisfy { $0.end == nil })
        #expect(lyrics.isActive(0, at: 4.9))
    }

    @Test("時刻のないテキストは、CRLF でも空行を増やさずに読む")
    func plainText() {
        let lyrics = Lyrics.parse("一行目\r\n二行目\r\n\r\n三行目\r\n")
        #expect(!lyrics.synced)
        #expect(lyrics.lines.map(\.text) == ["一行目", "二行目", "", "三行目"])
    }
}

@Suite("歌詞・字幕ファイルの検出")
struct LyricsFileTests {
    private func makeFolder(_ names: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-lyrics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names { try Data().write(to: dir.appendingPathComponent(name)) }
        return dir
    }

    @Test("同じ名前の .srt / .vtt、音源名に付け足した名前、言語つきの名前を曲に結び付ける")
    func matchesSidecars() throws {
        let dir = try makeFolder([
            "01 耳かき.wav", "01 耳かき.wav.vtt",          // 音源のファイル名 + .vtt
            "02 囁き.mp3", "02 囁き.srt",                  // 同じ名前
            "03 添い寝.flac", "03 添い寝.ja.srt",          // 言語つき
            "04 おまけ.mp3", "04 おまけ.wav.vtt",          // 別の形式の音源名に付いた字幕
            "05 字幕なし.mp3", "readme.txt",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let result = Importer.expand([dir])
        #expect(result.skipped == 0)
        let found = Dictionary(uniqueKeysWithValues: result.tracks.map { ($0.fileName, $0.lyricsURL?.lastPathComponent) })
        #expect(found == [
            "01 耳かき.wav": "01 耳かき.wav.vtt", "02 囁き.mp3": "02 囁き.srt", "03 添い寝.flac": "03 添い寝.ja.srt",
            "04 おまけ.mp3": "04 おまけ.wav.vtt", "05 字幕なし.mp3": nil,
        ])
    }

    @Test("複数あるときは、名前がそのまま一致するものを、次に .lrc → .srt → .vtt の順で選ぶ")
    func priority() throws {
        let dir = try makeFolder([
            "a.mp3", "a.vtt", "a.srt", "a.lrc",
            "b.mp3", "b.vtt", "b.srt",
            "c.mp3", "c.mp3.srt", "c.vtt",
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = Dictionary(uniqueKeysWithValues: Importer.expand([dir]).tracks.map { ($0.fileName, $0.lyricsURL?.lastPathComponent) })
        #expect(found == ["a.mp3": "a.lrc", "b.mp3": "b.srt", "c.mp3": "c.vtt"])
    }

    @Test("曲のファイルだけを開いたときも、同じフォルダの字幕を拾う")
    func singleFile() throws {
        let dir = try makeFolder(["track.m4a", "track.m4a.vtt", "other.srt"])
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("track.m4a")
        #expect(Importer.expand([audio]).tracks.first?.lyricsURL?.lastPathComponent == "track.m4a.vtt")
        #expect(Importer.sidecarLyrics(for: audio)?.lastPathComponent == "track.m4a.vtt")
        // 字幕ファイルだけを開いても、曲としては扱わない
        #expect(Importer.expand([dir.appendingPathComponent("other.srt")]).tracks.isEmpty)
    }
}
