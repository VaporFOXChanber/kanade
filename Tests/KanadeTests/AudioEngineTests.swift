import AVFoundation
import Testing
@testable import Kanade

/// 再生エンジンを音を出さない設定で動かし、出てくる波形を集める。
/// エンジン内の待ち時間 (フェードが終わるのを待つなど) は、描画したサンプル数から決まる仮の時計で進める
/// (実時間に頼ると、テストを並列に回したときに描画が遅れて結果がぶれる)
@MainActor
private final class OfflineRig {
    nonisolated static let sampleRate = 48000.0
    nonisolated static let amplitude: Float = 0.2
    nonisolated static let frequency = 1000.0

    let audio: AudioEngine
    let item: PlaybackItem
    private let chunk: AVAudioPCMBuffer
    private let fileURL: URL
    private var scheduled: [(due: Int, order: Int, work: () -> Void)] = []
    private var order = 0
    private(set) var left: [Float] = []
    /// 実際に描画したサンプルの数 (エンジンが止まっている間は 0 を足すだけ)
    private(set) var renderedFrames = 0

    /// - Parameters:
    ///   - fileRate: 再生するファイルのサンプルレート (出力は常に 48kHz)
    ///   - tones: ファイルに入れる正弦波の (周波数, 振幅)
    ///   - bits: 指定すると、そのビット数の整数で表せる値に丸める (24 ビットの音源を模す)
    init(fileRate: Double = OfflineRig.sampleRate, tones: [(Double, Float)] = [(OfflineRig.frequency, OfflineRig.amplitude)],
         bits: Int? = nil) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        audio = AudioEngine(offlineFormat: format)
        audio.volume = 1
        chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))

        // 正弦波 8 秒のファイル (何も指定しなければ 1kHz)
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-test-\(UUID().uuidString).caf")
        let fileFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: fileRate, channels: 2))
        let count = AVAudioFrameCount(8 * fileRate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: count))
        buffer.frameLength = count
        for i in 0..<Int(count) {
            var v = 0.0
            for (frequency, amplitude) in tones { v += Double(amplitude) * sin(2 * Double.pi * frequency * Double(i) / fileRate) }
            if let bits { v = (v * Double(1 << (bits - 1))).rounded() / Double(1 << (bits - 1)) }
            buffer.floatChannelData![0][i] = Float(v)
            buffer.floatChannelData![1][i] = Float(v)
        }
        do {
            let writer = try AVAudioFile(forWriting: fileURL, settings: fileFormat.settings)
            try writer.write(from: buffer)
            writer.close()
        }
        item = PlaybackItem(trackID: UUID(), file: try AVAudioFile(forReading: fileURL), source: fileURL, start: 0, end: nil, gain: 1)
        audio.after = { [unowned self] seconds, work in
            self.order += 1
            self.scheduled.append((self.left.count + Int(seconds * Self.sampleRate), self.order, work))
        }
    }

    deinit { try? FileManager.default.removeItem(at: fileURL) }

    /// seconds だけ進め、その間の出力を集める。予約された処理は、その時刻まで描画したところで実行する
    func run(_ seconds: Double) throws {
        let end = left.count + Int(seconds * Self.sampleRate)
        while true {
            let next = scheduled.filter { $0.due <= end }.min { ($0.due, $0.order) < ($1.due, $1.order) }
            try render(until: min(end, next?.due ?? end))
            guard let next else { break }
            scheduled.removeAll { $0.order == next.order }
            next.work()
        }
    }

    private func render(until target: Int) throws {
        while left.count < target {
            let frames = min(256, target - left.count)
            if audio.engine.isRunning {
                let status = try audio.engine.renderOffline(AVAudioFrameCount(frames), to: chunk)
                #expect(status == .success)
                left += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
                renderedFrames = left.count
            } else {
                left += [Float](repeating: 0, count: frames)
            }
        }
    }

    /// 落ち着いて鳴っているときの大きさ (dB) と、隣り合うサンプルの差の最大
    var steadyDB: Float { 20 * log10(Self.amplitude / Float(2).squareRoot()) }
    var steadyStep: Float { Self.amplitude * Float(2 * Double.pi * Self.frequency / Self.sampleRate) }

    func level(_ range: Range<Int>) -> Float { rmsDB(left, range) - steadyDB }

    func steepest(_ range: Range<Int>) -> Float {
        var m: Float = 0
        for i in range where i > 0 { m = max(m, abs(left[i] - left[i - 1])) }
        return m
    }

    func frames(_ seconds: Double) -> Int { Int(seconds * Self.sampleRate) }
}

@Suite("再生エンジンのつなぎ目", .serialized)
@MainActor
struct AudioEngineTests {
    @Test("ASMR モードの一時停止は、音を絞りきってから止まる (プツッと切らない)")
    func softPauseFadesOut() throws {
        let rig = try OfflineRig()
        rig.audio.softTransitions = true
        rig.audio.load(rig.item, play: true)
        try rig.run(0.5)
        let pausedAt = rig.left.count
        #expect(abs(rig.level((pausedAt - 4800)..<pausedAt)) < 0.2)

        rig.audio.pause()
        #expect(!rig.audio.isPlaying)                       // 表示上はすぐ止まる
        #expect(rig.audio.engine.isRunning)                 // 音はフェードが終わるまで出し続ける
        try rig.run(0.4)
        #expect(!rig.audio.engine.isRunning)
        let stoppedAt = rig.renderedFrames
        #expect(stoppedAt > pausedAt + rig.frames(0.1))
        #expect(rig.level((stoppedAt - 240)..<stoppedAt) < -30)                        // 止まる直前は十分小さい
        #expect(rig.steepest((pausedAt - 480)..<rig.left.count) <= rig.steadyStep * 1.02)  // 段差がない
        let position = rig.audio.position
        #expect((0.5...0.75).contains(position), "止まった位置 \(position)")
    }

    @Test("ASMR モードの再開は、無音からフェードインする")
    func softResumeFadesIn() throws {
        let rig = try OfflineRig()
        rig.audio.softTransitions = true
        rig.audio.load(rig.item, play: true)
        try rig.run(0.4)
        rig.audio.pause()
        try rig.run(0.4)

        let resumedAt = rig.left.count
        rig.audio.play()
        #expect(rig.audio.isPlaying)
        try rig.run(0.7)
        #expect(rig.level(resumedAt..<(resumedAt + rig.frames(0.03))) < -40)            // 出だしは無音
        let rising = rig.level((resumedAt + rig.frames(0.07))..<(resumedAt + rig.frames(0.08)))
        #expect((-20.0 ... -6.0).contains(rising), "0.07 秒後の大きさ \(rising) dB")      // 上がっていく途中
        #expect(abs(rig.level((rig.left.count - 4800)..<rig.left.count)) < 0.2)        // 元の大きさに戻る
        #expect(rig.steepest(resumedAt..<rig.left.count) <= rig.steadyStep * 1.02)
    }

    @Test("フェードアウトの途中で再生し直すと、止まらずに音が戻る")
    func playDuringFadeOutKeepsRunning() throws {
        let rig = try OfflineRig()
        rig.audio.softTransitions = true
        rig.audio.load(rig.item, play: true)
        try rig.run(0.4)
        rig.audio.pause()
        try rig.run(0.05)
        rig.audio.play()
        try rig.run(0.6)
        #expect(rig.audio.isPlaying)
        #expect(rig.audio.engine.isRunning)
        #expect(abs(rig.level((rig.left.count - 4800)..<rig.left.count)) < 0.2)
        #expect(rig.steepest(4800..<rig.left.count) <= rig.steadyStep * 1.02)
    }

    @Test("ASMR モードのシークは、一瞬絞ってから移動する")
    func softSeekDipsThroughSilence() throws {
        let rig = try OfflineRig()
        rig.audio.softTransitions = true
        rig.audio.load(rig.item, play: true)
        try rig.run(0.5)
        let seekAt = rig.left.count
        rig.audio.seek(to: 3.01234)                          // 波形の位相がずれる位置へ
        #expect(abs(rig.audio.position - 3.01234) < 0.001)   // 行き先はすぐ反映される
        try rig.run(0.6)

        var quietest: Float = 0
        for start in stride(from: seekAt, to: seekAt + rig.frames(0.2), by: 48) {
            quietest = min(quietest, rig.level(start..<(start + 96)))
        }
        #expect(quietest < -30, "移動の前後の最小 \(quietest) dB")
        #expect(abs(rig.level((rig.left.count - 4800)..<rig.left.count)) < 0.2)
        #expect(rig.steepest(seekAt..<rig.left.count) <= rig.steadyStep * 1.02)
        let position = rig.audio.position
        #expect((3.3...3.75).contains(position), "移動後の位置 \(position)")
    }

    @Test("続けてシークしても、最後の行き先に落ち着く")
    func repeatedSeeksLandOnLastTarget() throws {
        let rig = try OfflineRig()
        rig.audio.softTransitions = true
        rig.audio.load(rig.item, play: true)
        try rig.run(0.3)
        for step in 1...5 {
            rig.audio.seek(to: Double(step))
            try rig.run(0.012)
        }
        try rig.run(0.5)
        let position = rig.audio.position
        #expect((5.3...5.8).contains(position), "位置 \(position)")
        #expect(abs(rig.level((rig.left.count - 4800)..<rig.left.count)) < 0.2)
    }

    @Test("ASMR モードで曲の途中から再生を始めると、フェードインする")
    func softStartFromMiddle() throws {
        let rig = try OfflineRig()
        rig.audio.softTransitions = true
        rig.audio.load(rig.item, at: 2.00037, play: true)
        try rig.run(0.7)
        #expect(rig.level(0..<rig.frames(0.03)) < -40)
        #expect(abs(rig.level((rig.left.count - 4800)..<rig.left.count)) < 0.2)
        #expect(rig.steepest(1..<rig.left.count) <= rig.steadyStep * 1.02)
    }

    @Test("曲の頭からの再生は、フェードをかけずにそのまま鳴らす")
    func startFromBeginningIsNotFaded() throws {
        let rig = try OfflineRig()
        rig.audio.softTransitions = true
        rig.audio.load(rig.item, play: true)
        try rig.run(0.3)
        #expect(abs(rig.level(rig.frames(0.01)..<rig.frames(0.03))) < 0.2)
    }

    @Test("ASMR モードでなければ、一時停止もシークもこれまでどおりすぐに行う")
    func normalModeIsImmediate() throws {
        let rig = try OfflineRig()
        rig.audio.load(rig.item, play: true)
        try rig.run(0.3)
        rig.audio.seek(to: 4)
        try rig.run(0.2)
        #expect(abs(rig.level((rig.left.count - 2400)..<rig.left.count)) < 0.2)
        #expect((4.1...4.4).contains(rig.audio.position))
        rig.audio.pause()
        #expect(!rig.audio.engine.isRunning)
        rig.audio.play()
        try rig.run(0.2)
        #expect(abs(rig.level((rig.left.count - 2400)..<rig.left.count)) < 0.2)
    }
}

/// 出力に含まれる正弦波をまとめて当てはめ、それぞれの振幅と、取り除いた残り (誤差) の大きさ (dBFS) を返す
private func fitTones(_ x: [Float], _ range: Range<Int>, _ frequencies: [Double], rate: Double) -> (amplitudes: [Double], residualDB: Double) {
    let y = range.map { Double(x[$0]) }
    var basis: [[Double]] = []
    for f in frequencies {
        basis.append(range.map { cos(2 * Double.pi * f * Double($0) / rate) })
        basis.append(range.map { sin(2 * Double.pi * f * Double($0) / rate) })
    }
    let m = basis.count
    var a = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: m)
    for i in 0..<m {
        for j in 0..<m { a[i][j] = zip(basis[i], basis[j]).reduce(0) { $0 + $1.0 * $1.1 } }
        a[i][m] = zip(basis[i], y).reduce(0) { $0 + $1.0 * $1.1 }
    }
    for i in 0..<m {
        let pivot = (i..<m).max { abs(a[$0][i]) < abs(a[$1][i]) }!
        a.swapAt(i, pivot)
        for r in 0..<m where r != i {
            let k = a[r][i] / a[i][i]
            for c in i...m { a[r][c] -= k * a[i][c] }
        }
    }
    let coefficients = (0..<m).map { a[$0][m] / a[$0][$0] }
    var residual = y
    for i in 0..<m { for k in residual.indices { residual[k] -= coefficients[i] * basis[i][k] } }
    let rms = (residual.reduce(0) { $0 + $1 * $1 } / Double(residual.count)).squareRoot()
    let amplitudes = frequencies.indices.map { (coefficients[2 * $0] * coefficients[2 * $0] + coefficients[2 * $0 + 1] * coefficients[2 * $0 + 1]).squareRoot() }
    return (amplitudes, 20 * log10(rms + 1e-30))
}

@Suite("サンプルレートと音質", .serialized)
@MainActor
struct SampleRateTests {
    private static let tones: [(Double, Float)] = [(997, 0.25), (15000, 0.25), (19000, 0.25)]

    @Test("サンプルレートの違う曲 (44.1kHz → 48kHz) を、ほとんど誤差なく変換する")
    func highQualityConversion() throws {
        let rig = try OfflineRig(fileRate: 44100, tones: Self.tones)
        rig.audio.load(rig.item, play: true)
        try rig.run(3)
        let fit = fitTones(rig.left, 48000..<(48000 + 65536), Self.tones.map(\.0), rate: 48000)
        // 標準の品質のままだと、誤差は -110 dBFS 前後、19kHz は 2.6dB 落ちる
        #expect(fit.residualDB < -130, "変換の誤差 \(fit.residualDB) dBFS")
        #expect(abs(20 * log10(fit.amplitudes[0] / 0.25)) < 0.01)
        #expect(abs(20 * log10(fit.amplitudes[1] / 0.25)) < 0.05)
        #expect(20 * log10(fit.amplitudes[2] / 0.25) > -1, "19kHz の落ち込み")
    }

    @Test("経路と同じサンプルレートの曲は、1 ビットも変えずに出力まで届く")
    func bitExactWhenRatesMatch() throws {
        let rig = try OfflineRig()
        rig.audio.load(rig.item, play: true)
        try rig.run(1)
        func original(_ i: Int) -> Float {
            Float(Double(OfflineRig.amplitude) * sin(2 * Double.pi * OfflineRig.frequency * Double(i) / OfflineRig.sampleRate))
        }
        // 出力は、処理ユニットの先読みの分だけ遅れた、ファイルの波形そのもの
        let expected = ASMRKernel.latencyFrames(sampleRate: 48000)
        let delay = try #require(((expected - 2)...(expected + 2)).first { d in
            (4800..<4900).allSatisfy { rig.left[$0] == original($0 - d) }
        }, "出力がファイルの波形と一致する遅れが見つからない")
        var differing = 0
        for i in 4800..<40000 where rig.left[i] != original(i - delay) { differing += 1 }
        #expect(differing == 0)
    }

    @Test("速度を変えると変換の部品が入り、等速に戻すと外れて、元どおり 1 ビットも変えなくなる")
    func timeStretchIsRemovedAtNormalSpeed() throws {
        let rig = try OfflineRig()
        rig.audio.load(rig.item, play: true)
        try rig.run(0.5)
        rig.audio.rate = 1.25
        try rig.run(1)
        #expect(rig.audio.isPlaying)
        let fast = rig.audio.position
        #expect((1.5...1.95).contains(fast), "1.25 倍で 1 秒進めた位置 \(fast)")   // 0.5 + 1.25 秒前後
        #expect(abs(rig.level((rig.left.count - 4800)..<rig.left.count)) < 0.5)

        rig.audio.rate = 1
        let from = rig.left.count
        try rig.run(1)
        // 等速に戻したあとは、ファイルの波形とぴったり一致する (どこかの位置から続きが鳴っている)
        func original(_ i: Int) -> Float {
            Float(Double(OfflineRig.amplitude) * sin(2 * Double.pi * OfflineRig.frequency * Double(i) / OfflineRig.sampleRate))
        }
        let window = (from + 24000)..<(from + 24100)
        let exact = (-48000..<96000).contains { offset in window.allSatisfy { rig.left[$0] == original($0 + offset) } }
        #expect(exact, "等速に戻したあとの出力が、元の波形と 1 ビット単位で一致しない")
    }

    @Test("経路を別のサンプルレートに組み直しても、正しく鳴り続ける")
    func rebuildsChain() throws {
        let rig = try OfflineRig(fileRate: 44100)
        #expect(rig.audio.chainSampleRate == 48000)
        rig.audio.rebuildChain(sampleRate: 44100)
        #expect(rig.audio.chainSampleRate == 44100)
        rig.audio.load(rig.item, play: true)
        try rig.run(2)
        var fit = fitTones(rig.left, 48000..<(48000 + 32768), [1000], rate: 48000)
        #expect(abs(fit.amplitudes[0] - 0.2) < 0.0005)
        #expect(fit.residualDB < -120)

        // 元に戻して読み込み直す (出力デバイスが切り替わったときと同じ流れ)
        rig.audio.rebuildChain(sampleRate: 48000)
        #expect(rig.audio.chainSampleRate == 48000)
        rig.audio.load(rig.item, at: 1, play: true)
        try rig.run(2)
        fit = fitTones(rig.left, (rig.left.count - 40000)..<(rig.left.count - 4000), [1000], rate: 48000)
        #expect(abs(fit.amplitudes[0] - 0.2) < 0.0005)
    }

    @Test("パラメトリック EQ は、経路のサンプルレートが変わっても同じ周波数に同じだけ効く")
    func parametricEQFollowsChainRate() throws {
        let profile = EQProfile(name: "テスト", bands: [ParametricBand(kind: .peak, frequency: 1000, gain: 6, q: 2)])
        for rate in [48000.0, 44100] {
            let rig = try OfflineRig()
            rig.audio.eqProfile = profile
            rig.audio.rebuildChain(sampleRate: rate)
            rig.audio.load(rig.item, play: true)
            try rig.run(2)
            let fit = fitTones(rig.left, 48000..<(48000 + 32768), [1000], rate: 48000)
            #expect(abs(20 * log10(fit.amplitudes[0] / 0.2) - 6) < 0.05, "経路 \(rate) Hz")
        }
    }

    @Test("曲のサンプルレートに最も合うデバイスのサンプルレートを選ぶ", arguments: [
        (44100.0, [44100.0, 48000, 96000], 44100.0),      // 同じ値がある
        (44100.0, [48000.0, 88200, 96000], 88200.0),      // なければ整数倍
        (44100.0, [48000.0, 96000], 48000.0),             // それもなければ、高い中でいちばん低い
        (192000.0, [44100.0, 48000, 96000], 96000.0),     // 曲のほうが高い: 割り切れる中でいちばん高い
        (176400.0, [44100.0, 48000, 96000], 44100.0),
        (352800.0, [48000.0, 96000], 96000.0),            // 割り切れなければ最高値
    ])
    func choosesDeviceRate(fileRate: Double, available: [Double], expected: Double) {
        #expect(OutputDevice.bestRate(for: fileRate, available: available) == expected)
        #expect(OutputDevice.bestRate(for: fileRate, available: []) == nil)
    }

    @Test("今の出力デバイスの状態を読める (読むだけで、切り替えはしない)")
    func readsOutputDevice() throws {
        let device = try #require(AudioOutputs.defaultDeviceID())
        let rate = try #require(OutputDevice.nominalSampleRate(device))
        let available = OutputDevice.availableSampleRates(device)
        #expect(available.contains(rate))
        #expect(OutputDevice.name(device)?.isEmpty == false)
        #expect(OutputDevice.hogOwner(device) != nil)
    }
}

@Suite("音量", .serialized)
@MainActor
struct VolumeTests {
    private func original(_ i: Int) -> Float {
        Float(Double(OfflineRig.amplitude) * sin(2 * Double.pi * OfflineRig.frequency * Double(i) / OfflineRig.sampleRate))
    }

    @Test("音量が最大なら、曲の最初のサンプルから 1 ビットも変わらない (鳴らし始めに、音量がなめらかに動く区間がない)")
    func exactFromTheFirstSample() throws {
        let rig = try OfflineRig()
        rig.audio.load(rig.item, play: true)
        try rig.run(0.2)
        let latency = ASMRKernel.latencyFrames(sampleRate: 48000)
        let delay = try #require(((latency - 2)...(latency + 2)).first { d in (0..<200).allSatisfy { rig.left[d + $0] == original($0) } },
                                 "最初のサンプルから一致する遅れが見つからない")
        #expect((0..<(9600 - delay)).allSatisfy { rig.left[delay + $0] == original($0) })
        #expect(rig.left[0..<delay].allSatisfy { $0 == 0 })
    }

    @Test("止まっている間に決めた音量は、鳴らし始めからその大きさで出る (音量は 2 乗で効く)")
    func volumeAppliesFromTheStart() throws {
        let rig = try OfflineRig()
        rig.audio.volume = 0.5
        rig.audio.load(rig.item, play: true)
        try rig.run(0.3)
        let delay = ASMRKernel.latencyFrames(sampleRate: 48000)
        // 最初の山から、もう 0.25 倍になっている
        for i in [12, 36, 60, 600, 6000] { #expect(abs(rig.left[delay + i] - 0.25 * original(i)) < 1e-6, "\(i)") }
        #expect(abs(rig.level(rig.frames(0.1)..<rig.frames(0.3)) - (-12.04)) < 0.05)
    }

    @Test("再生中に音量を変えると、段差を作らずになめらかに変わる")
    func volumeChangesSmoothly() throws {
        let rig = try OfflineRig()
        rig.audio.load(rig.item, play: true)
        try rig.run(0.3)
        rig.audio.volume = 0.2
        try rig.run(0.3)
        #expect(abs(rig.level(rig.frames(0.1)..<rig.frames(0.3))) < 0.05)                       // 変える前
        #expect(abs(rig.level(rig.frames(0.45)..<rig.frames(0.6)) - (-27.96)) < 0.05)           // 変えたあと (0.2² = -28 dB)
        #expect(rig.steepest(rig.frames(0.29)..<rig.frames(0.45)) <= rig.steadyStep * 1.05)     // 移り変わりに段差がない
        // 消音も同じ
        rig.audio.volume = 0
        try rig.run(0.2)
        #expect(rig.left[rig.frames(0.75)..<rig.frames(0.8)].allSatisfy { $0 == 0 })
        #expect(rig.steepest(rig.frames(0.59)..<rig.frames(0.75)) <= rig.steadyStep * 0.05)
    }

    @Test("スリープタイマーのフェードも、同じように掛かる")
    func sleepFade() throws {
        let rig = try OfflineRig()
        rig.audio.load(rig.item, play: true)
        try rig.run(0.2)
        rig.audio.fadeMultiplier = 0.5
        try rig.run(0.3)
        #expect(abs(rig.level(rig.frames(0.35)..<rig.frames(0.5)) - (-6.02)) < 0.05)
    }
}

@Suite("左右の確認音")
struct ChannelCheckTests {
    @Test("左で 1 回、そのあと右で 2 回鳴る")
    func leftThenRight() {
        let (left, right) = ChannelCheck.samples()
        let rate = ChannelCheck.sampleRate
        func frames(_ seconds: Double) -> Int { Int(seconds * rate) }
        // 前半は左だけ、後半は右だけ
        #expect(peak(left, 0..<frames(0.6)) > 0.05)
        #expect(peak(right, 0..<frames(0.8)) == 0)
        #expect(peak(left, frames(0.6)..<left.count) == 0)
        #expect(peak(right, frames(0.86)..<frames(1.0)) > 0.05)
        #expect(peak(right, frames(1.21)..<frames(1.4)) > 0.05)
        // 大きすぎず、始まりと終わりは無音
        #expect(max(peak(left, 0..<left.count), peak(right, 0..<right.count)) <= ChannelCheck.level)
        #expect(left.first == 0 && right.last == 0)
        // 右の 2 回の間は、いったん小さくなる
        #expect(peak(right, frames(1.15)..<frames(1.2)) < 0.02)
    }
}
