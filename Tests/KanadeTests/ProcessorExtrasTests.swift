import Foundation
import Testing
@testable import Kanade

/// 2 つの信号を続けてつなぐ
private func joined(_ parts: Stereo...) -> Stereo {
    Stereo(left: parts.flatMap(\.left), right: parts.flatMap(\.right))
}

/// 隣り合うサンプルの差の最大
private func steepest(_ x: [Float], _ range: Range<Int>) -> Float {
    var m: Float = 0
    for i in range where i > 0 { m = max(m, abs(x[i] - x[i - 1])) }
    return m
}

/// サンプルの間も含めた山の大きさ (8 倍に補間して測る)
private func truePeak(_ x: [Float], _ range: Range<Int>) -> Float {
    var peak: Float = 0
    let half = 32
    for n in range where n - half >= 0 && n + half < x.count {
        for step in 0..<8 {
            let t = Double(step) / 8
            var sum = 0.0
            for k in -half...half {
                let d = Double(k) - t
                let sinc = d == 0 ? 1 : sin(Double.pi * d) / (Double.pi * d)
                let window = 0.5 + 0.5 * cos(Double.pi * d / Double(half + 1))
                sum += Double(x[n + k]) * sinc * window
            }
            peak = max(peak, Float(abs(sum)))
        }
    }
    return peak
}

@Suite("先読みとトゥルーピーク")
struct LookaheadTests {
    private static func settings(_ strength: ASMRStrength) -> ASMRSettings {
        var s = ASMRSettings()
        s.dynamics = true
        s.limiter = true
        strength.apply(to: &s)
        return s
    }

    @Test("遅れは設定によらず一定で、サンプルレートに合わせて決まる", arguments: [44100.0, 48000, 96000, 192000])
    func latencyIsConstant(rate: Double) {
        let expected = ASMRKernel.latencyFrames(sampleRate: rate)
        #expect(abs(Double(expected) / rate - 0.008) < 0.0004)
        // すべてオフでも、ASMR の処理を入れても、同じだけ遅れる
        let n = Int(rate / 4)
        var impulse = Stereo(left: [Float](repeating: 0, count: n), right: [Float](repeating: 0, count: n))
        impulse.left[100] = 0.5
        impulse.right[100] = 0.5
        for settings in [ASMRSettings(), Self.settings(.standard)] {
            let output = process(impulse, settings: settings, sampleRate: rate)
            let peakAt = output.left.indices.max { abs(output.left[$0]) < abs(output.left[$1]) }
            #expect(peakAt == 100 + expected)
        }
    }

    @Test("すべてオフなら、どのサンプルレートでも遅れるだけで 1 ビットも変えない", arguments: [44100.0, 48000, 96000])
    func bitExactWhenOff(rate: Double) {
        var random = TestRandom(seed: 7)
        let n = Int(rate / 2)
        let input = Stereo(left: (0..<n).map { _ in random.next() * 0.9 }, right: (0..<n).map { _ in random.next() * 0.9 })
        let output = process(input, settings: ASMRSettings(), sampleRate: rate)
        let delay = ASMRKernel.latencyFrames(sampleRate: rate)
        var differing = 0
        for i in 0..<(n - delay) where output.left[i + delay] != input.left[i] || output.right[i + delay] != input.right[i] { differing += 1 }
        #expect(differing == 0)
    }

    @Test("ささやきのあとの急な大音量: 出だしから抑えが効いていて、リミッター頼みにならない", arguments: ASMRStrength.allCases)
    func loudOnsetIsAnticipated(strength: ASMRStrength) {
        let segments = [Segment(3, -42), Segment(1, -6)]
        let input = noiseSignal(segments)
        let output = process(input, settings: Self.settings(strength))
        let onset = segments[0].frames + latency
        // 2ms ずつ区切って、いちばん大きい区間の大きさを比べる (雑音なので、短い区間の大きさは自然に揺れる)
        func loudest(from start: Int, windows: Int) -> Float {
            (0..<windows).map { rmsDB(output.left, (start + $0 * 96)..<(start + $0 * 96 + 96)) }.max() ?? -200
        }
        let atOnset = loudest(from: onset, windows: 15)                 // 出だしの 30ms
        let settled = loudest(from: onset + 24000, windows: 200)        // 落ち着いたあと
        // 先読みがないと、出だしは持ち上げがかかったままリミッターの上限 (-3 dBFS) まで出てしまう
        #expect(atOnset < settled + 3, "出だし \(atOnset) dB / 落ち着いたあと \(settled) dB")
        // 大きな音の直前のささやきは、持ち上げたまま
        let before = gainDB(input.left, output.left, (segments[0].frames - 9600)..<(segments[0].frames - 2400))
        #expect(before > 1.5)
    }

    @Test("サンプルの間にある山 (トゥルーピーク) も上限に収める")
    func limitsInterSamplePeaks() {
        // サンプルレートの 1/4 の正弦波を 45° ずらすと、サンプルの値は 0.707 でも、本当の山は 1.0 になる
        let n = 48000
        let x = (0..<n).map { Float(sin(Double.pi / 2 * Double($0) + Double.pi / 4)) }
        let input = Stereo(left: x, right: x)
        #expect(peak(input.left, 0..<n) < 0.7072)
        #expect(truePeak(input.left, 2000..<4000) > 0.99)
        var settings = ASMRSettings()
        settings.limiter = true
        let output = process(input, settings: settings)
        let measured = truePeak(output.left, 24000..<26000)
        #expect(measured <= settings.ceiling * 1.02, "出力のトゥルーピーク \(measured)")
        #expect(measured > settings.ceiling * 0.9)   // 下げすぎてもいない
    }

    @Test("リミッターの上限を変えられる (ASMR モード以外のクリップ防止は -0.1 dBFS)")
    func clipGuardCeiling() {
        let input = noiseSignal([Segment(1, -20), Segment(1, 0)])
        var settings = ASMRSettings()
        settings.limiter = true
        settings.ceiling = 0.9886
        let output = process(input, settings: settings)
        #expect(peak(output.left, 0..<output.count) <= 0.9886 + 1e-6)
        // 上限に届かない音は 1 ビットも変えない
        for i in 0..<40000 where output.left[i + latency] != input.left[i] {
            Issue.record("小さい音が変わっている (\(i))")
            break
        }
    }

    @Test("カスタムの強さ: 自分で決めた値で持ち上げ、抑える")
    func customCurve() {
        var settings = ASMRSettings()
        settings.dynamics = true      // リミッターは入れず、コンプレッサーだけの効き方を見る
        ASMRStrength.custom.apply(to: &settings, custom: ASMRCustomCurve(upThreshold: -30, maxBoost: 4, downThreshold: -12, downRatio: 2))
        #expect(settings.maxBoost == 4 && settings.downThreshold == -12 && settings.downRatio == 2)
        let segments = [Segment(4, -50), Segment(2, -6)]
        let input = noiseSignal(segments)
        let output = process(input, settings: settings)
        let whisper = gainDB(input.left, output.left, settledHalf(of: 0, in: segments))
        let loud = gainDB(input.left, output.left, settledHalf(of: 1, in: segments))
        #expect((3.0...4.1).contains(whisper), "持ち上げ \(whisper) dB")      // 上限の 4dB まで
        #expect((-6.0 ... -2.5).contains(loud), "抑え \(loud) dB")           // 超えた分をおよそ半分に
    }

    @Test("入力と出力の大きさを知らせる")
    func reportsLevels() {
        var kernel = ASMRKernel()
        kernel.prepare(sampleRate: testSampleRate, maxFrames: 4096)
        defer { kernel.release() }
        let shared = ASMRShared()
        shared.publish(Self.settings(.standard))
        var signal = noiseSignal([Segment(3, -42)])
        signal.left.withUnsafeMutableBufferPointer { l in
            signal.right.withUnsafeMutableBufferPointer { r in
                var position = 0
                while position < l.count {
                    kernel.sync(shared)
                    let frames = min(512, l.count - position)
                    kernel.process(l.baseAddress! + position, r.baseAddress! + position, frames: frames)
                    position += frames
                }
            }
        }
        kernel.publishMeters(shared)
        #expect(abs(shared.meters[4] - -42) < 3)                       // 入力
        #expect(shared.meters[5] > shared.meters[4] + 3)               // 出力は持ち上がっている
        #expect(abs((shared.meters[5] - shared.meters[4]) - shared.meters[0]) < 2)
    }
}

@Suite("低い雑音のカット")
struct LowCutTests {
    @Test("切る周波数より下だけを減らし、声の帯域は変えない", arguments: [40.0, 80])
    func removesRumble(cut: Double) {
        var settings = ASMRSettings()
        settings.lowCut = Float(cut)
        let input = tones([(cut / 4, 0.2, 0.2), (1000, 0.1, 0.1)], seconds: 2)
        let output = process(input, settings: settings)
        let range = 48000..<91200
        #expect(toneGainDB(input.left, output.left, cut / 4, range) < -20)
        #expect(abs(toneGainDB(input.left, output.left, 1000, range)) < 0.05)
    }

    @Test("再生中に入れたり切ったりしても、音が跳ばない")
    func togglesSmoothly() {
        let input = tones([(60, 0.3, 0.3)], seconds: 1.5)
        var on = ASMRSettings()
        on.lowCut = 80
        let output = process(input, settings: ASMRSettings(), changes: [(512 * 30, on), (512 * 90, ASMRSettings())])
        let natural = Float(0.3 * 2 * Double.pi * 60 / testSampleRate)
        #expect(steepest(output.left, 1000..<output.count) <= natural * 1.5)
        #expect(toneGainDB(input.left, output.left, 60, 30000..<43200) < -3)        // 入っている間は減る
        #expect(abs(toneGainDB(input.left, output.left, 60, 60000..<67200)) < 0.01) // 切ると元に戻る
    }
}

@Suite("クロスフィード")
struct CrossfeedTests {
    private static func settings(level: Float = 4.5, cut: Float = 700) -> ASMRSettings {
        var s = ASMRSettings()
        s.crossfeedCut = cut
        s.crossfeedLevel = level
        return s
    }

    @Test("中央の音 (左右同じ) は、低音の大きさを変えない")
    func keepsCenterLevel() {
        let input = tones([(100, 0.2, 0.2)], seconds: 1)
        let output = process(input, settings: Self.settings())
        #expect(abs(toneGainDB(input.left, output.left, 100, 24000..<43200)) < 0.3)
    }

    @Test("片側だけの音を、低音を中心に、指定した量だけ小さくして反対側へ回す", arguments: [(Float(4.5), -5.5 ... -4.0), (Float(9.5), -10.5 ... -9.0)])
    func feedsOppositeEar(level: Float, lowRatio: ClosedRange<Double>) {
        // 左だけに 150Hz と 6kHz
        let input = tones([(150, 0.2, 0), (6000, 0.2, 0)], seconds: 1)
        let output = process(input, settings: Self.settings(level: level))
        let range = (24000 + latency)..<(43200 + latency)
        func ratio(_ f: Double) -> Double {
            Double(20 * log10(toneAmplitude(output.right, f, range) / toneAmplitude(output.left, f, range)))
        }
        #expect(lowRatio.contains(ratio(150)), "150Hz の回り込み \(ratio(150)) dB")
        #expect(ratio(6000) < ratio(150) - 10, "6kHz の回り込み \(ratio(6000)) dB")   // 高音はほとんど回さない
    }

    @Test("再生中に入れたり切ったりしても音が跳ばず、切れば完全に元に戻る")
    func togglesSmoothly() {
        let input = tones([(200, 0.3, 0)], seconds: 1.5)
        let output = process(input, settings: ASMRSettings(), changes: [(512 * 30, Self.settings()), (512 * 90, ASMRSettings())])
        let natural = Float(0.3 * 2 * Double.pi * 200 / testSampleRate)
        #expect(steepest(output.left, 1000..<output.count) <= natural * 1.2)
        #expect(steepest(output.right, 1000..<output.count) <= natural * 1.2)
        #expect(rmsDB(output.right, 30000..<43200) > -40)       // 入っている間は右にも出る
        #expect(peak(output.right, 62000..<output.count) == 0)  // 切ると右は無音に戻る
        for i in 62000..<(output.count - latency) where output.left[i + latency] != input.left[i] {
            Issue.record("切ったあとの左が元の音と違う (\(i)): \(output.left[i + latency]) / \(input.left[i])")
            break
        }
    }
}

@Suite("パラメトリック EQ")
struct ParametricEQTests {
    private static let profile = EQProfile(name: "テスト", preamp: -3, bands: [
        ParametricBand(kind: .peak, frequency: 1000, gain: 6, q: 2),
        ParametricBand(kind: .lowShelf, frequency: 105, gain: 5, q: 0.7),
        ParametricBand(kind: .highShelf, frequency: 8000, gain: -4, q: 0.7),
    ])

    private func measured(_ profile: EQProfile, _ frequency: Double, rate: Double = testSampleRate) -> Double {
        let n = Int(rate)
        let x = (0..<n).map { Float(0.1 * sin(2 * Double.pi * frequency * Double($0) / rate)) }
        let output = process(Stereo(left: x, right: x), settings: ASMRSettings(),
                             eq: EQDesign.stages(for: profile, sampleRate: rate), sampleRate: rate)
        let delay = ASMRKernel.latencyFrames(sampleRate: rate)
        let range = (n / 2)..<(n - delay - 100)
        func amplitude(_ s: [Float], _ r: Range<Int>) -> Double {
            var re = 0.0, im = 0.0
            for i in r {
                let phase = 2 * Double.pi * frequency * Double(i) / rate
                re += Double(s[i]) * cos(phase)
                im += Double(s[i]) * sin(phase)
            }
            return 2 * (re * re + im * im).squareRoot() / Double(r.count)
        }
        return 20 * log10(amplitude(output.left, (range.lowerBound + delay)..<(range.upperBound + delay)) / amplitude(x, range))
    }

    @Test("設計どおりの周波数特性になる", arguments: [30.0, 105, 400, 1000, 1400, 4000, 8000, 15000])
    func matchesDesign(frequency: Double) {
        let designed = EQDesign.response(of: Self.profile, at: frequency, sampleRate: testSampleRate)
        #expect(abs(measured(Self.profile, frequency) - designed) < 0.05, "\(frequency) Hz: 設計 \(designed) dB")
    }

    @Test("各バンドの特性: ピークは中心でゲインどおり、シェルフは端でゲインどおり、ハイパス・ローパスは外を落とす")
    func bandShapes() {
        func response(_ band: ParametricBand, _ f: Double) -> Double {
            EQDesign.response(of: EQProfile(name: "", bands: [band]), at: f, sampleRate: 48000)
        }
        let peakBand = ParametricBand(kind: .peak, frequency: 1000, gain: 6, q: 2)
        #expect(abs(response(peakBand, 1000) - 6) < 0.01)
        #expect(abs(response(peakBand, 100)) < 0.2 && abs(response(peakBand, 10000)) < 0.2)
        let lowShelf = ParametricBand(kind: .lowShelf, frequency: 200, gain: 5, q: 0.7)
        #expect(abs(response(lowShelf, 20) - 5) < 0.1 && abs(response(lowShelf, 5000)) < 0.1)
        let highShelf = ParametricBand(kind: .highShelf, frequency: 4000, gain: -4, q: 0.7)
        #expect(abs(response(highShelf, 18000) - -4) < 0.2 && abs(response(highShelf, 100)) < 0.1)
        let highPass = ParametricBand(kind: .highPass, frequency: 100, q: 0.7071)
        #expect(response(highPass, 25) < -20 && abs(response(highPass, 100) - -3) < 0.1 && abs(response(highPass, 2000)) < 0.1)
        let lowPass = ParametricBand(kind: .lowPass, frequency: 8000, q: 0.7071)
        #expect(response(lowPass, 20000) < -12 && abs(response(lowPass, 200)) < 0.1)
        // オフのバンドや 0dB のバンドは何もしない
        #expect(EQDesign.coefficients(ParametricBand(gain: 6, enabled: false), sampleRate: 48000) == [1, 0, 0, 0, 0])
        #expect(EQDesign.coefficients(ParametricBand(gain: 0), sampleRate: 48000) == [1, 0, 0, 0, 0])
    }

    @Test("サンプルレートが違っても、同じ周波数に同じだけ効く", arguments: [44100.0, 96000])
    func sameAcrossRates(rate: Double) {
        for frequency in [105.0, 1000, 8000] {
            let designed = EQDesign.response(of: Self.profile, at: frequency, sampleRate: rate)
            #expect(abs(measured(Self.profile, frequency, rate: rate) - designed) < 0.05)
            #expect(abs(designed - EQDesign.response(of: Self.profile, at: frequency, sampleRate: 48000)) < 0.6)
        }
    }

    @Test("何も設定していなければ 1 ビットも変えない")
    func flatIsBitExact() {
        let flat = EQProfile(name: "フラット", bands: [ParametricBand(gain: 0), ParametricBand(kind: .peak, gain: 5, enabled: false)])
        #expect(flat.isFlat)
        #expect(EQDesign.stages(for: flat, sampleRate: 48000).isEmpty)
        #expect(!Self.profile.isFlat)
    }

    @Test("再生中に設定を変えても、音が跳ばずに新しい特性へ移る")
    func changesSmoothly() {
        let input = tones([(1000, 0.2, 0.2)], seconds: 1.2)
        let stages = EQDesign.stages(for: Self.profile, sampleRate: testSampleRate)
        let at = 512 * 40
        let output = process(input, settings: ASMRSettings(), eqChanges: [(at, stages), (512 * 80, [])])
        let natural = Float(0.2 * 2 * Double.pi * 1000 / testSampleRate)
        // 1kHz は +6dB -3dB = +3dB になる。切り替わりの途中にも段差がない
        // (いきなり切り替えると、山のところで natural の 3 倍ほどの段差になる)
        #expect(steepest(output.left, 1000..<output.count) <= natural * 1.42 * 1.15)
        #expect(abs(toneGainDB(input.left, output.left, 1000, (at + 4800)..<(at + 14400)) - 3) < 0.05)
        #expect(abs(toneGainDB(input.left, output.left, 1000, 48000..<52800)) < 0.001)   // 外すと元に戻る
    }

    @Test("プリアンプの自動調整に使う、持ち上げ量の最大を見積もる")
    func peakGain() {
        let gain = EQDesign.peakGain(of: Self.profile, sampleRate: 48000)
        #expect((5.9...7.5).contains(gain), "\(gain) dB")
        #expect(EQDesign.peakGain(of: EQProfile(name: "", bands: [ParametricBand(gain: -5)]), sampleRate: 48000) < 0.01)
    }

    @Test("AutoEQ の設定ファイルを読む")
    func parsesAutoEQ() throws {
        let text = """
        Preamp: -6.4 dB
        Filter 1: ON PK Fc 21 Hz Gain 6.1 dB Q 1.41
        Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
        Filter 3: OFF PK Fc 1500 Hz Gain -2.0 dB Q 3.00
        Filter 4: ON HSC Fc 10000 Hz Gain -3.5 dB Q 0.70
        Filter 5: ON HP Fc 20 Hz
        Filter 6: ON XYZ Fc 100 Hz Gain 1 dB Q 1
        """
        let parsed = try #require(EQDesign.parseAutoEQ(text))
        #expect(parsed.preamp == -6.4)
        #expect(parsed.bands.map(\.kind) == [.peak, .lowShelf, .peak, .highShelf, .highPass])
        #expect(parsed.bands.map(\.frequency) == [21, 105, 1500, 10000, 20])
        #expect(parsed.bands.map(\.gain) == [6.1, 5.5, -2, -3.5, 0])
        #expect(parsed.bands.map(\.enabled) == [true, true, false, true, true])
        #expect(parsed.bands[0].q == 1.41)
        #expect(EQDesign.parseAutoEQ("ただのテキスト") == nil)
    }
}
