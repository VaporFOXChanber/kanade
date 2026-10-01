import AVFoundation
import Testing
@testable import Kanade

/// EBU Tech 3341 の確認用の信号で、統合ラウドネスの測り方を確かめる
@Suite("ラウドネス (EBU R128)")
struct LoudnessTests {
    /// 区間ごとに大きさ (dBFS、正弦波の山の高さ) を決めた、左右同じ 1kHz の正弦波を測る
    private func measure(_ segments: [(seconds: Double, dbfs: Double)], rate: Double = 48000, channels: Int = 2) throws -> Double? {
        let meter = try #require(LoudnessMeter(sampleRate: rate, channels: channels))
        var index = 0
        for segment in segments {
            let n = Int(segment.seconds * rate)
            let amplitude = pow(10, segment.dbfs / 20)
            var samples = (0..<n).map { Float(amplitude * sin(2 * Double.pi * 1000 * Double(index + $0) / rate)) }
            index += n
            samples.withUnsafeMutableBufferPointer { p in
                var pointers = [UnsafeMutablePointer<Float>](repeating: p.baseAddress!, count: channels)
                // 実際の読み込みと同じように、いくつかに分けて渡す
                var offset = 0
                while offset < n {
                    let count = min(4099, n - offset)
                    for c in 0..<channels { pointers[c] = p.baseAddress! + offset }
                    pointers.withUnsafeBufferPointer { meter.add($0.baseAddress!, frames: count) }
                    offset += count
                }
            }
        }
        return meter.integrated()
    }

    @Test("-23 dBFS の 1kHz 正弦波 (ステレオ) は -23 LUFS", arguments: [44100.0, 48000, 96000])
    func referenceTone(rate: Double) throws {
        let lufs = try #require(try measure([(20, -23)], rate: rate))
        #expect(abs(lufs - -23) < 0.1, "\(lufs) LUFS")
    }

    @Test("-33 dBFS は -33 LUFS (大きさに比例する)")
    func scalesWithLevel() throws {
        let lufs = try #require(try measure([(20, -33)]))
        #expect(abs(lufs - -33) < 0.1)
    }

    @Test("相対ゲート: 小さい区間 (-36 dBFS) にはさまれた -23 dBFS は -23 LUFS")
    func relativeGate() throws {
        let lufs = try #require(try measure([(10, -36), (60, -23), (10, -36)]))
        #expect(abs(lufs - -23) < 0.1, "\(lufs) LUFS")
    }

    @Test("絶対ゲート: ごく小さい区間 (-72 dBFS) にはさまれても変わらない")
    func absoluteGate() throws {
        let lufs = try #require(try measure([(10, -72), (60, -23), (10, -72)]))
        #expect(abs(lufs - -23) < 0.1, "\(lufs) LUFS")
    }

    @Test("モノラルは、同じ大きさのステレオより 3 LU 小さい")
    func mono() throws {
        let lufs = try #require(try measure([(20, -23)], channels: 1))
        #expect(abs(lufs - -26) < 0.1, "\(lufs) LUFS")
    }

    @Test("無音や、短すぎる音は測れない")
    func silence() throws {
        #expect(try measure([(5, -120)]) == nil)
        #expect(try measure([(0.3, -23)]) == nil)
    }

    @Test("基準 (-18 LUFS) にそろえるゲインを求める")
    func gain() {
        #expect(LoudnessResult(lufs: -23, peak: 0.1).gainDB == 5)
        #expect(LoudnessResult(lufs: -8, peak: 1).gainDB == -10)
        #expect(LoudnessResult(lufs: nil, peak: 0).gainDB == nil)
    }

    @Test("ファイルを読んで測る (CUE の区間だけを測ることもできる)")
    func scansFile() throws {
        let rate = 44100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-loud-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        // 前半 10 秒は -23 dBFS、後半 10 秒は -13 dBFS
        let n = Int(20 * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)))
        buffer.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let amplitude = pow(10, (i < n / 2 ? -23.0 : -13.0) / 20)
            let v = Float(amplitude * sin(2 * Double.pi * 1000 * Double(i) / rate))
            buffer.floatChannelData![0][i] = v
            buffer.floatChannelData![1][i] = v
        }
        do {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings)
            try writer.write(from: buffer)
            writer.close()
        }
        let first = try #require(LoudnessScanner.measure(url, start: 0, end: 10))
        #expect(abs(try #require(first.lufs) - -23) < 0.15)
        #expect(abs(first.peak - pow(10, -23.0 / 20)) < 0.001)
        let second = try #require(LoudnessScanner.measure(url, start: 10, end: nil))
        #expect(abs(try #require(second.lufs) - -13) < 0.15)
        let whole = try #require(LoudnessScanner.measure(url))
        #expect(abs(whole.peak - pow(10, -13.0 / 20)) < 0.001)
        #expect((-17.0 ... -13.0).contains(try #require(whole.lufs)))
        #expect(LoudnessScanner.key(for: url, start: nil) != LoudnessScanner.key(for: url, start: 10))
        #expect(LoudnessScanner.measure(url.appendingPathExtension("none")) == nil)
    }

    @Test("測った結果を保存して読み直せる")
    func store() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-loudstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var store = LoudnessStore()
        store.set(LoudnessResult(lufs: -14.2, peak: 0.98), for: "a")
        store.set(LoudnessResult(lufs: nil, peak: 0), for: "b")
        store.save(to: dir)
        let loaded = LoudnessStore.load(from: dir)
        #expect(loaded == store)
        #expect(loaded["a"]?.lufs == -14.2)
    }
}
