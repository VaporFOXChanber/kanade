import Foundation
import Testing
@testable import Kanade

@Suite("スリープタイマーの音量")
struct SleepFadeTests {
    @Test("フェードに入るまでは下げず、そこから -45dB まで一定の速さで下げる")
    func fadeCurve() {
        #expect(SleepFade.target(remaining: 600, fade: 180) == 1)
        #expect(SleepFade.target(remaining: 180, fade: 180) == 1)
        let half = 20 * log10(SleepFade.target(remaining: 90, fade: 180))
        let end = 20 * log10(SleepFade.target(remaining: 0, fade: 180))
        #expect(abs(half - -22.5) < 0.01)
        #expect(abs(end - -45) < 0.01)
        // 1 秒あたりの下げ幅が一定
        let a = 20 * log10(SleepFade.target(remaining: 150, fade: 180)) - 20 * log10(SleepFade.target(remaining: 149, fade: 180))
        let b = 20 * log10(SleepFade.target(remaining: 20, fade: 180)) - 20 * log10(SleepFade.target(remaining: 19, fade: 180))
        #expect(abs(a - b) < 0.001)
    }

    @Test("下げるときはそのまま、戻すときは 1 回に約 1dB ずつ")
    func stepping() {
        #expect(SleepFade.step(from: 1, to: 0.5) == 0.5)
        #expect(SleepFade.step(from: 0.5, to: 0.5) == 0.5)
        let up = SleepFade.step(from: 0.1, to: 1)
        #expect(abs(20 * log10(up / 0.1) - 1) < 0.01)
        #expect(SleepFade.step(from: 0.95, to: 1) == 1)

        // 延長したとき: フェードの底 (-45dB) からでも、毎秒 30 回の更新で 2 秒以内に元の音量へ戻る
        var volume = SleepFade.target(remaining: 0, fade: 180)
        var steps = 0
        while volume < 1, steps < 1000 {
            volume = SleepFade.step(from: volume, to: 1)
            steps += 1
        }
        #expect(volume == 1)
        #expect((30...60).contains(steps), "\(steps) 回")
        // 無音 (0) からでも戻れる
        #expect(SleepFade.step(from: 0, to: 1) > 0)
    }
}

@Suite("続きから再生")
struct ResumeStoreTests {
    private let hour = 3600.0

    @Test("長い音源の途中で離れると位置を覚え、次は少し手前から始める")
    func remembersMiddleOfLongTracks() {
        var store = ResumeStore()
        store.leave("a", at: 1234, duration: hour)
        #expect(store.take("a", duration: hour) == 1231)
        #expect(store.take("a", duration: hour) == nil)      // 1 回使ったら忘れる
    }

    @Test("短い曲、頭や終わりの近くでは覚えない", arguments: [
        (100.0, 300.0), (10.0, 3600.0), (3590.0, 3600.0), (3600.0, 3600.0),
    ])
    func ignoresShortTracksAndEdges(position: Double, duration: Double) {
        var store = ResumeStore()
        store.leave("a", at: position, duration: duration)
        #expect(store.take("a", duration: duration) == nil)
    }

    @Test("最後まで聴いたら、前に覚えた位置を忘れる")
    func finishingForgets() {
        var store = ResumeStore()
        store.leave("a", at: 1000, duration: hour)
        store.leave("a", at: hour - 1, duration: hour)
        #expect(store.take("a", duration: hour) == nil)
    }

    @Test("長さの分からない曲は覚えない")
    func unknownDuration() {
        var store = ResumeStore()
        store.leave("a", at: 1000, duration: nil)
        #expect(store.points.isEmpty)
    }

    @Test("覚える数には上限があり、古いものから捨てる")
    func capacity() {
        var store = ResumeStore()
        let start = Date(timeIntervalSince1970: 0)
        for i in 0..<(ResumeStore.capacity + 5) {
            store.leave("track\(i)", at: 100, duration: hour, now: start.addingTimeInterval(Double(i)))
        }
        #expect(store.points.count == ResumeStore.capacity)
        #expect(store.points["track0"] == nil)
        #expect(store.points["track5"] != nil)
        #expect(store.points["track\(ResumeStore.capacity + 4)"] != nil)
    }

    @Test("保存して読み直せる")
    func roundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-resume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ResumeStore.load(from: dir) == ResumeStore())
        var store = ResumeStore()
        store.leave("a|0.0", at: 700, duration: hour)
        store.save(to: dir)
        #expect(ResumeStore.load(from: dir) == store)
    }
}
