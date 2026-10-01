import Foundation
import Synchronization
import Testing
@testable import Kanade

/// 設定の受け渡し (シーケンスロック) のテスト
@Suite("ASMR の設定の受け渡し")
struct ASMRSharedTests {
    /// すべての値を同じ数にした設定。読んだ結果で値がばらばらなら、書き込みの途中を読んだことになる
    private static func pattern(_ x: Float) -> ASMRSettings {
        var s = ASMRSettings()
        s.dynamics = Int(x) % 2 == 0
        s.limiter = s.dynamics
        s.swap = s.dynamics
        s.upThreshold = x; s.upRatio = x; s.maxBoost = x; s.noiseFloor = x
        s.downThreshold = x; s.downRatio = x; s.attack = x; s.release = x; s.boostRise = x
        s.loudnessLow = x; s.loudnessHigh = x; s.ceiling = x; s.duck = x
        s.deEssThreshold = x; s.deEssMax = x; s.duckTime = x; s.duckRestart = UInt32(x)
        return s
    }

    private static func isConsistent(_ s: ASMRSettings) -> Bool {
        let x = s.upThreshold
        let flag = Int(x) % 2 == 0
        return [s.upRatio, s.maxBoost, s.noiseFloor, s.downThreshold, s.downRatio, s.attack, s.release,
                s.boostRise, s.loudnessLow, s.loudnessHigh, s.ceiling, s.duck,
                s.deEssThreshold, s.deEssMax, s.duckTime].allSatisfy { $0 == x }
            && s.dynamics == flag && s.limiter == flag && s.swap == flag && s.duckRestart == UInt32(x)
    }

    @Test("新しい設定は 1 回だけ返り、番号は書くたびに進む")
    func readReturnsEachSettingOnce() throws {
        let shared = ASMRShared()
        let initial = try #require(shared.read(ifNewerThan: -1))
        #expect(initial.0 == 0)
        #expect(shared.read(ifNewerThan: initial.0) == nil)

        shared.publish(Self.pattern(7))
        let first = try #require(shared.read(ifNewerThan: initial.0))
        #expect(first.0 == 2)                 // 書き終えた番号は偶数
        #expect(first.1.maxBoost == 7)
        #expect(shared.read(ifNewerThan: first.0) == nil)

        shared.publish(Self.pattern(8))
        shared.publish(Self.pattern(9))
        let latest = try #require(shared.read(ifNewerThan: first.0))
        #expect(latest.0 == 6)
        #expect(latest.1.maxBoost == 9)       // 間の設定は飛ばして、最新だけを受け取る
    }

    @Test("書き込みと重なっても、書きかけの設定を読まない", arguments: [1, 2])
    func concurrentReadsAreNeverTorn(writers: Int) {
        final class Progress: Sendable {
            let finished = Atomic<Int>(0)
            let written = Atomic<Int>(0)
            let reads = Atomic<Int>(0)
        }
        let shared = ASMRShared()
        let progress = Progress()
        let minimumWrites = 200_000, minimumReads = 2_000
        // 最初の既定値はパターンになっていないので、先に 1 回書いておく
        shared.publish(Self.pattern(0))

        for w in 0..<writers {
            Thread.detachNewThread {
                // 読む側が十分な回数だけ重なるまで書き続ける (ほかのテストで混んでいても、重なりを確保する)。
                // 休みなく書き続けると読む側は読み直しばかりになるので、ときどき短く休む
                var i = 0
                let deadline = Date().addingTimeInterval(20)
                while i < minimumWrites || (progress.reads.load(ordering: .relaxed) < minimumReads && Date() < deadline) {
                    i += 1
                    shared.publish(Self.pattern(Float((i * writers + w) % 1_000_000)))
                    if i % 64 == 0 { usleep(1) }
                }
                progress.written.add(i, ordering: .sequentiallyConsistent)
                progress.finished.add(1, ordering: .sequentiallyConsistent)
            }
        }

        var version = -1, reads = 0, torn = 0, outOfOrder = 0
        while progress.finished.load(ordering: .sequentiallyConsistent) < writers {
            guard let (v, settings) = shared.read(ifNewerThan: version) else { continue }
            if v <= version || v & 1 == 1 { outOfOrder += 1 }
            version = v
            reads += 1
            progress.reads.store(reads, ordering: .relaxed)
            if !Self.isConsistent(settings) { torn += 1 }
        }
        // 書き終えたあとは必ず最新が読める
        if let (v, settings) = shared.read(ifNewerThan: version) {
            version = v
            reads += 1
            if !Self.isConsistent(settings) { torn += 1 }
        }

        #expect(torn == 0, "\(reads) 回の読み取りのうち \(torn) 回で、別々の書き込みの値が混ざっていた")
        #expect(outOfOrder == 0)
        #expect(reads >= minimumReads)
        let total = progress.written.load(ordering: .sequentiallyConsistent)
        #expect(version == (total + 1) * 2)   // 1 回の書き込みで番号は 2 進む
    }
}
