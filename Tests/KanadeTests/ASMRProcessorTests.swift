import AVFoundation
import Testing
@testable import Kanade

/// ASMR モードの信号処理 (ASMRKernel) を、合成した音で数値として確かめる
@Suite("ASMR の信号処理")
struct ASMRProcessorTests {
    /// ささやき → 言葉の合間のノイズ → 急な大音量 → ささやき → ふつうの声
    private static let speech: [Segment] = [
        Segment(3, -42), Segment(2, -72), Segment(0.6, -6), Segment(2, -42), Segment(2, -20),
    ]

    private static func settings(_ strength: ASMRStrength) -> ASMRSettings {
        var s = ASMRSettings()
        s.dynamics = true
        s.limiter = true
        strength.apply(to: &s)
        return s
    }

    // MARK: 素通し

    @Test("すべてオフなら、3ms 遅れるだけで音は変わらない")
    func passthroughWhenOff() {
        let input = noiseSignal(Self.speech)
        let output = process(input, settings: ASMRSettings())
        var worst: Float = 0
        for i in 0..<(input.count - latency) {
            worst = max(worst, abs(output.left[i + latency] - input.left[i]), abs(output.right[i + latency] - input.right[i]))
        }
        #expect(worst < 1e-6)
    }

    // MARK: コンプレッサー

    @Test("小さい音を持ち上げ、大きい音を抑える", arguments: [
        (ASMRStrength.gentle, 2.0...4.5, -6.0),
        (ASMRStrength.standard, 4.0...6.5, -10.0),
        (ASMRStrength.firm, 6.0...9.0, -13.0),
    ])
    func liftsQuietAndTamesLoud(strength: ASMRStrength, whisperLift: ClosedRange<Double>, loudCutAtLeast: Double) {
        let input = noiseSignal(Self.speech)
        let output = process(input, settings: Self.settings(strength))
        let whisper = Double(gainDB(input.left, output.left, settledHalf(of: 0, in: Self.speech)))
        let loud = Double(gainDB(input.left, output.left, settledHalf(of: 2, in: Self.speech)))
        #expect(whisperLift.contains(whisper), "ささやきの持ち上げ \(whisper) dB")
        #expect(loud <= loudCutAtLeast, "大きな音の抑え \(loud) dB")
    }

    @Test("強いほど、小さい音と大きい音の差が縮まる")
    func strongerSettingsCompressMore() {
        let input = noiseSignal(Self.speech)
        let ranges = ASMRStrength.allCases.map { strength -> Float in
            let output = process(input, settings: Self.settings(strength))
            let quiet = rmsDB(output.left, settledHalf(of: 0, in: Self.speech))
            let loud = rmsDB(output.left, settledHalf(of: 2, in: Self.speech))
            return loud - quiet
        }
        #expect(ranges[0] < 36)                          // 入力の差は 36dB
        #expect(ranges[0] > ranges[1] && ranges[1] > ranges[2])
    }

    @Test("言葉の合間のノイズを、直前の声より大きくは持ち上げない", arguments: ASMRStrength.allCases)
    func pauseNoiseIsNotLiftedAboveSpeech(strength: ASMRStrength) {
        let input = noiseSignal(Self.speech)
        let output = process(input, settings: Self.settings(strength))
        let whisper = gainDB(input.left, output.left, settledHalf(of: 0, in: Self.speech))
        let noise = gainDB(input.left, output.left, settledHalf(of: 1, in: Self.speech))
        #expect(noise <= whisper + 0.5, "声 \(whisper) dB / 合間のノイズ \(noise) dB")
    }

    @Test("大きな音のあと、ささやきの持ち上げが 2 秒以内に戻る", arguments: ASMRStrength.allCases)
    func recoversAfterLoudSound(strength: ASMRStrength) {
        let input = noiseSignal(Self.speech)
        let output = process(input, settings: Self.settings(strength))
        let before = gainDB(input.left, output.left, settledHalf(of: 0, in: Self.speech))
        let after = gainDB(input.left, output.left, settledHalf(of: 3, in: Self.speech))
        #expect(after > 0.4 * before, "前 \(before) dB / 後 \(after) dB")
    }

    @Test("左右には同じゲインをかける (定位を崩さない)", arguments: ASMRStrength.allCases)
    func channelsShareOneGain(strength: ASMRStrength) {
        // 左右で大きさの違う音: 片方だけ大きい / 片方がほぼ無音
        let segments = [Segment(2, -40, -52), Segment(2, -14, -40), Segment(2, -30, -90)]
        let input = noiseSignal(segments)
        let output = process(input, settings: Self.settings(strength))
        for index in segments.indices {
            let range = settledHalf(of: index, in: segments)
            let left = gainDB(input.left, output.left, range)
            let right = gainDB(input.right, output.right, range)
            #expect(abs(left - right) < 0.05, "区間 \(index): 左 \(left) dB / 右 \(right) dB")
        }
    }

    // MARK: リミッター

    @Test("急な大音量でも上限 (-3 dBFS) を超えない", arguments: ASMRStrength.allCases)
    func limiterHoldsCeiling(strength: ASMRStrength) {
        // 静かな状態 (持ち上げがかかっている) から、いきなりフルスケールを超える音
        let segments = [Segment(3, -45), Segment(0.5, -3), Segment(1, -45), Segment(0.3, 0)]
        let input = noiseSignal(segments)
        #expect(peak(input.left, 0..<input.count) > 1)
        let settings = Self.settings(strength)
        let output = process(input, settings: settings)
        #expect(peak(output.left, 0..<output.count) <= settings.ceiling + 1e-6)
        #expect(peak(output.right, 0..<output.count) <= settings.ceiling + 1e-6)
    }

    @Test("急な大音量でも、波形を上限で切り落とさない (歪ませない)", arguments: [100.0, 1000, 5000])
    func limiterDoesNotFlattenPeaks(frequency: Double) {
        // 小さな音から、いきなりフルスケールの音
        let quiet = sine(frequency, amplitude: 0.05, seconds: 0.5)
        let loud = sine(frequency, amplitude: 1, seconds: 0.5)
        let input = Stereo(left: quiet.left + loud.left, right: quiet.right + loud.right)
        var settings = ASMRSettings()
        settings.limiter = true
        let output = process(input, settings: settings)
        #expect(peak(output.left, 0..<output.count) <= settings.ceiling + 1e-6)

        // 切り落とされた波形は、上限ちょうどのサンプルが続く
        var run = 0, longest = 0
        for y in output.left {
            run = abs(y) >= settings.ceiling ? run + 1 : 0
            longest = max(longest, run)
        }
        #expect(longest <= 1, "上限に張り付いたサンプルが \(longest) 個続いた")

        // 落ち着いたあとは、元の波形をそのまま小さくしただけになっている
        let range = 40000..<45000
        let gain = pow(10, gainDB(input.left, output.left, range) / 20)
        var worst: Float = 0
        for i in range { worst = max(worst, abs(output.left[i + latency] - gain * input.left[i])) }
        #expect(worst < 0.002, "波形のずれ \(worst)")
    }

    @Test("リミッターがオフなら、上限で切らない")
    func limiterOffDoesNotClip() {
        let input = noiseSignal([Segment(1, -3)])
        let output = process(input, settings: ASMRSettings())
        #expect(peak(output.left, 0..<output.count) > 1)
    }

    // MARK: L/R 入れ替え

    @Test("左右を入れ替える")
    func swapExchangesChannels() {
        let input = noiseSignal([Segment(1, -30, -90)])
        var settings = ASMRSettings()
        settings.swap = true
        let output = process(input, settings: settings)
        for i in 0..<(input.count - latency) {
            #expect(output.left[i + latency] == input.right[i])
            #expect(output.right[i + latency] == input.left[i])
            if output.left[i + latency] != input.right[i] { break }
        }
    }

    // MARK: ラウドネス補正

    @Test("ラウドネス補正は低音と高音だけを持ち上げる")
    func loudnessShelves() {
        var settings = ASMRSettings()
        settings.loudnessLow = 6
        settings.loudnessHigh = 3
        func response(_ frequency: Double) -> Float {
            let input = sine(frequency, amplitude: 0.1, seconds: 1)
            let output = process(input, settings: settings)
            return gainDB(input.left, output.left, 24000..<43200)
        }
        #expect((4.8...6.2).contains(response(40)))
        #expect((2.0...3.6).contains(response(110)))     // 折れ点ではおよそ半分
        #expect(abs(response(1000)) < 0.3)
        #expect((2.0...3.0).contains(response(14000)))
    }

    @Test("再生を始めた直後は、最初から設定どおりの補正量になる")
    func loudnessStartsAtTarget() {
        var settings = ASMRSettings()
        settings.loudnessHigh = 3.5
        let input = sine(12000, amplitude: 0.1, seconds: 1)
        let output = process(input, settings: settings)
        let early = gainDB(input.left, output.left, 240..<480)
        let settled = gainDB(input.left, output.left, 40000..<44000)
        #expect(settled > 2)
        #expect(abs(early - settled) < 0.05)
    }

    @Test("再生中に補正量を変えると、数十 ms かけてなめらかに近づく")
    func loudnessChangeIsGradual() {
        let input = sine(12000, amplitude: 0.1, seconds: 1.2)
        var target = ASMRSettings()
        target.loudnessHigh = 3.5
        let changeAt = 512 * 40   // 描画の区切りで設定を差し替える
        let output = process(input, settings: ASMRSettings(), changes: [(changeAt, target)])
        let reference = process(input, settings: target)
        let final = gainDB(input.left, reference.left, 48000..<52000)

        func gain(afterMilliseconds ms: Double) -> Float {
            let start = changeAt + Int(ms / 1000 * testSampleRate)
            return gainDB(input.left, output.left, start..<(start + 96))
        }
        #expect(abs(gainDB(input.left, output.left, (changeAt - 2000)..<(changeAt - 200))) < 0.01)  // 変更前は素通し
        #expect(gain(afterMilliseconds: 0) < 0.15 * final)        // いきなり跳ばない
        #expect((0.4 * final...0.85 * final).contains(gain(afterMilliseconds: 40)))
        #expect(abs(gain(afterMilliseconds: 300) - final) < 0.05) // 落ち着けば設定どおり

        // 波形にも段差ができていない: 隣り合うサンプルの差が、落ち着いたあとの最大を超えない
        func steepest(_ x: [Float], _ range: Range<Int>) -> Float {
            var m: Float = 0
            for i in range { m = max(m, abs(x[i] - x[i - 1])) }
            return m
        }
        let during = steepest(output.left, (changeAt + latency)..<(changeAt + latency + 9600))
        let settled = steepest(reference.left, 48000..<52000)
        #expect(during <= settled * 1.001)
    }

    @Test("補正量を 0 に戻すと、完全な素通しに戻る")
    func loudnessReturnsToIdentity() {
        let input = sine(12000, amplitude: 0.1, seconds: 1.2)
        var boosted = ASMRSettings()
        boosted.loudnessLow = 9
        boosted.loudnessHigh = 3.5
        let changeAt = 512 * 40
        let output = process(input, settings: boosted, changes: [(changeAt, ASMRSettings())])
        #expect(abs(gainDB(input.left, output.left, 48000..<52000)) < 0.001)
    }

    // MARK: 高音のやわらげ

    private static func softening(_ level: ASMRSoftening) -> ASMRSettings {
        var s = ASMRSettings()
        level.apply(to: &s)
        return s
    }

    @Test("強い高音だけを下げ、低い音は変えない", arguments: [
        (ASMRSoftening.light, -5.2 ... -3.0), (ASMRSoftening.strong, -9.2 ... -6.0),
    ])
    func softeningTamesSharpHighs(level: ASMRSoftening, expected: ClosedRange<Double>) {
        // 300Hz の声に、8kHz の強い音 (-17 dBFS) が重なっている
        let input = tones([(300, 0.1, 0.1), (8000, 0.2, 0.2)], seconds: 1)
        let output = process(input, settings: Self.softening(level))
        let range = 24000..<43200
        let high = Double(toneGainDB(input.left, output.left, 8000, range))
        let low = Double(toneGainDB(input.left, output.left, 300, range))
        #expect(expected.contains(high), "8kHz の変化 \(high) dB")
        #expect(abs(low) < 0.3, "300Hz の変化 \(low) dB")
    }

    @Test("高音が強くなければ、音をまったく変えない", arguments: [ASMRSoftening.light, .strong])
    func softeningLeavesOtherSoundsAlone(level: ASMRSoftening) {
        // 大きな声 (300Hz + 2kHz) と、小さな高音 (8kHz, -50 dBFS)
        let input = tones([(300, 0.3, 0.3), (2000, 0.2, 0.1), (8000, 0.0045, 0.0045)], seconds: 1)
        let output = process(input, settings: Self.softening(level))
        var worst: Float = 0
        for i in 0..<(input.count - latency) {
            worst = max(worst, abs(output.left[i + latency] - input.left[i]), abs(output.right[i + latency] - input.right[i]))
        }
        #expect(worst < 1e-6)
    }

    @Test("強い高音が止めば、すぐに戻り始めて 1 秒以内に完全に元の音に戻る")
    func softeningRecovers() {
        let loud = tones([(8000, 0.3, 0.3)], seconds: 0.5)
        let quiet = tones([(8000, 0.003, 0.003)], seconds: 1.5)
        let input = Stereo(left: loud.left + quiet.left, right: loud.right + quiet.right)
        let output = process(input, settings: Self.softening(.strong))
        #expect(toneGainDB(input.left, output.left, 8000, 12000..<21600) < -6)          // 強い間は下げる
        #expect(abs(toneGainDB(input.left, output.left, 8000, 36000..<43200)) < 0.5)    // 0.25 秒後にはほぼ戻る
        #expect(abs(toneGainDB(input.left, output.left, 8000, 72000..<91200)) < 0.001)  // 1 秒後は素通し
    }

    @Test("片方の耳だけ高音が強くても、左右を同じだけ下げる (定位を崩さない)")
    func softeningIsLinked() {
        let input = tones([(8000, 0.3, 0.003), (300, 0.05, 0.1)], seconds: 1)
        let output = process(input, settings: Self.softening(.strong))
        let range = 24000..<43200
        let left = toneGainDB(input.left, output.left, 8000, range)
        let right = toneGainDB(input.right, output.right, 8000, range)
        #expect(left < -4)
        #expect(abs(left - right) < 0.05, "左 \(left) dB / 右 \(right) dB")
    }

    // MARK: 一時的な絞り

    @Test("duck を 0 にすると数十 ms で無音になり、1 に戻すと元に戻る")
    func duckFadesOutAndBack() {
        let input = sine(1000, amplitude: 0.2, seconds: 1)
        var ducked = ASMRSettings()
        ducked.duck = 0
        let output = process(input, settings: ASMRSettings(), changes: [(512 * 20, ducked), (512 * 60, ASMRSettings())])
        #expect(abs(gainDB(input.left, output.left, 4800..<9600)) < 0.01)
        #expect(rmsDB(output.left, (512 * 20 + 4800)..<(512 * 20 + 9600)) < -80)
        #expect(abs(gainDB(input.left, output.left, 40000..<45000)) < 0.01)
    }

    @Test("duckTime を長くすると、その時定数でゆっくり絞る")
    func duckTimeSetsFadeSpeed() {
        let input = sine(1000, amplitude: 0.2, seconds: 1)
        var ducked = ASMRSettings()
        ducked.duck = 0
        ducked.duckTime = 0.05
        let at = 512 * 20
        let output = process(input, settings: ASMRSettings(), changes: [(at, ducked)])
        // 絞りは出力の時刻でかかるので、出力どうしを比べる
        func gain(afterMilliseconds ms: Double) -> Float {
            let start = at + Int(ms / 1000 * testSampleRate)
            return rmsDB(output.left, start..<(start + 96)) - rmsDB(output.left, 4800..<9600)
        }
        #expect(gain(afterMilliseconds: 5) > -1.5)                   // すぐには消えない
        #expect((-10.0 ... -7.5).contains(gain(afterMilliseconds: 50)))  // 時定数ぶん経つと 1/e (-8.7dB)
        #expect(gain(afterMilliseconds: 400) < -60)
    }

    @Test("duckRestart を変えると、無音からフェードインし直す")
    func duckRestartFadesInFromSilence() {
        let input = sine(1000, amplitude: 0.2, seconds: 1)
        var restart = ASMRSettings()
        restart.duckRestart = 1
        restart.duckTime = 0.05
        let at = 512 * 20
        let output = process(input, settings: ASMRSettings(), changes: [(at, restart)])
        func gain(afterMilliseconds ms: Double) -> Float {
            let start = at + Int(ms / 1000 * testSampleRate)
            return rmsDB(output.left, start..<(start + 96)) - rmsDB(output.left, 4800..<9600)
        }
        #expect(abs(gainDB(input.left, output.left, 4800..<9600)) < 0.01)
        #expect(gain(afterMilliseconds: 0) < -30)                      // いったん無音
        #expect((-5.0 ... -3.0).contains(gain(afterMilliseconds: 50)))  // 1 - 1/e (-4dB)
        #expect(abs(gain(afterMilliseconds: 500)) < 0.01)
    }

    // MARK: エンジンに組み込んだ状態

    @Test("AVAudioEngine に組み込んでも同じ処理がかかる")
    func worksInsideAudioEngine() throws {
        ASMRProcessorUnit.register()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: testSampleRate, channels: 2))
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        let player = AVAudioPlayerNode()
        let effect = AVAudioUnitEffect(audioComponentDescription: ASMRProcessorUnit.componentDescription)
        let unit = try #require(effect.auAudioUnit as? ASMRProcessorUnit)
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)

        var settings = Self.settings(.standard)
        settings.swap = true
        unit.shared.publish(settings)

        // 左だけに、フルスケールを超える音
        let signal = noiseSignal([Segment(1, -3, -90)])
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(signal.count)))
        buffer.frameLength = AVAudioFrameCount(signal.count)
        for i in 0..<signal.count {
            buffer.floatChannelData![0][i] = signal.left[i]
            buffer.floatChannelData![1][i] = signal.right[i]
        }
        try engine.start()
        player.scheduleBuffer(buffer)
        player.play()

        let chunk = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096))
        var left: [Float] = [], right: [Float] = []
        while left.count < signal.count {
            let status = try engine.renderOffline(4096, to: chunk)
            #expect(status == .success)
            let n = Int(chunk.frameLength)
            left += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: n)
            right += UnsafeBufferPointer(start: chunk.floatChannelData![1], count: n)
        }
        engine.stop()

        let range = 24000..<44000
        #expect(peak(right, 0..<right.count) <= settings.ceiling + 1e-5)      // リミッター
        #expect(rmsDB(right, range) > rmsDB(left, range) + 40)                // 入れ替えで右に出る
        #expect(rmsDB(right, range) < rmsDB(signal.left, range) - 6)          // 大きい音は抑える
    }
}
