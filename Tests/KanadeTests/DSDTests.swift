import AVFoundation
import Testing
@testable import Kanade

/// テスト用の DSD のデータ: 左右で違う、決まったビットの並び (時間の早いビットを上位にしたバイト列)
private func pattern(_ count: Int, seed: UInt32) -> [UInt8] {
    var state = seed
    return (0..<count).map { _ in
        state = state &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: state >> 24)
    }
}

private func reversedBits(_ byte: UInt8) -> UInt8 {
    var x = byte, r: UInt8 = 0
    for _ in 0..<8 { r = r << 1 | x & 1; x >>= 1 }
    return r
}

private func le<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }
private func be<T: FixedWidthInteger>(_ v: T) -> [UInt8] { withUnsafeBytes(of: v.bigEndian) { Array($0) } }

/// DSF のファイルを作る (ブロック 4096 バイト、最後のブロックは 0 で埋める)
private func makeDSF(left: [UInt8], right: [UInt8], rate: UInt32 = 2_822_400, lsbFirst: Bool = true) -> Data {
    let blockSize = 4096
    let blocks = (left.count + blockSize - 1) / blockSize
    var body = [UInt8]()
    for b in 0..<blocks {
        for channel in [left, right] {
            var block = [UInt8](repeating: 0, count: blockSize)
            for i in 0..<blockSize where b * blockSize + i < channel.count {
                block[i] = lsbFirst ? reversedBits(channel[b * blockSize + i]) : channel[b * blockSize + i]
            }
            body += block
        }
    }
    var d = [UInt8]("DSD ".utf8) + le(UInt64(28)) + le(UInt64(92 + body.count)) + le(UInt64(0))
    d += [UInt8]("fmt ".utf8) + le(UInt64(52)) + le(UInt32(1)) + le(UInt32(0)) + le(UInt32(2)) + le(UInt32(2)) + le(rate)
    d += le(UInt32(lsbFirst ? 1 : 8)) + le(UInt64(left.count * 8)) + le(UInt32(blockSize)) + le(UInt32(0))
    d += [UInt8]("data".utf8) + le(UInt64(12 + body.count))
    return Data(d + body)
}

/// DSDIFF のファイルを作る (左右が 1 バイトずつ交互)
private func makeDFF(left: [UInt8], right: [UInt8], rate: UInt32 = 2_822_400, compression: String = "DSD ") -> Data {
    func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] { [UInt8](id.utf8) + be(UInt64(body.count)) + body + (body.count % 2 == 1 ? [0] : []) }
    var sound = [UInt8]()
    for i in 0..<left.count { sound += [left[i], right[i]] }
    let prop = [UInt8]("SND ".utf8) + chunk("FS  ", be(rate)) + chunk("CHNL", be(UInt16(2)) + [UInt8]("SLFTSRGT".utf8))
        + chunk("CMPR", [UInt8](compression.utf8) + [14] + [UInt8]("not compressed".utf8))
    let body = [UInt8]("DSD ".utf8) + chunk("FVER", be(UInt32(0x0105_0000))) + chunk("PROP", prop) + chunk(compression, sound)
    return Data([UInt8]("FRM8".utf8) + be(UInt64(body.count)) + body)
}

/// DoP のファイルを読んで、(目印, 先の 8 ビット, あとの 8 ビット) を左右それぞれ取り出す
private func readDoP(_ url: URL) throws -> (rate: Double, left: [(UInt8, UInt8, UInt8)], right: [(UInt8, UInt8, UInt8)]) {
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    func words(_ channel: Int) -> [(UInt8, UInt8, UInt8)] {
        (0..<Int(buffer.frameLength)).map { i in
            let w = UInt32(bitPattern: Int32((buffer.floatChannelData![channel][i] * 8_388_608).rounded())) & 0xFF_FFFF
            return (UInt8(w >> 16), UInt8(w >> 8 & 0xFF), UInt8(w & 0xFF))
        }
    }
    return (file.processingFormat.sampleRate, words(0), words(1))
}

private func temporaryFile(_ name: String, _ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-dsd-\(UUID().uuidString)-\(name)")
    try data.write(to: url)
    return url
}

@Suite("DSD のネイティブ再生 (DoP)")
struct DSDTests {
    @Test("DSF と DSDIFF の形式を読める")
    func readsInfo() throws {
        let left = pattern(10_000, seed: 1), right = pattern(10_000, seed: 2)
        let dsf = try temporaryFile("a.dsf", makeDSF(left: left, right: right))
        let dff = try temporaryFile("a.dff", makeDFF(left: left, right: right, rate: 5_644_800))
        defer { [dsf, dff].forEach { try? FileManager.default.removeItem(at: $0) } }

        let a = try #require(DSDFile.info(dsf))
        #expect(a.sampleRate == 2_822_400 && a.channels == 2 && a.bitCount == 80_000)
        #expect(a.layout == .dsf(blockSize: 4096, lsbFirst: true))
        #expect(a.label == "DSD64")
        #expect(abs(a.duration - 80_000 / 2_822_400) < 1e-9)

        let b = try #require(DSDFile.info(dff))
        #expect(b.sampleRate == 5_644_800 && b.channels == 2 && b.bitCount == 80_000 && b.layout == .dff)
        #expect(b.label == "DSD128")
        #expect(DoP.pcmRate(forDSD: a.sampleRate) == 176_400 && DoP.pcmRate(forDSD: b.sampleRate) == 352_800)
    }

    @Test("DSD でないファイルと、圧縮された DSD (DST) は、DSD として扱わない")
    func rejectsOthers() throws {
        let wav = try temporaryFile("a.wav", DoP.wavHeader(frames: 0, rate: 44100))
        let dst = try temporaryFile("a.dff", makeDFF(left: [1, 2], right: [3, 4], compression: "DST "))
        defer { [wav, dst].forEach { try? FileManager.default.removeItem(at: $0) } }
        #expect(DSDFile.info(wav) == nil)
        #expect(DSDFile.info(dst) == nil)
        #expect(DSDFile.info(URL(fileURLWithPath: "/nonexistent.dsf")) == nil)
    }

    @Test("DoP に包んでも、DSD のビットは 1 つも変わらない (DSF・DSDIFF とも)", arguments: ["dsf-lsb", "dsf-msb", "dff"])
    func wrapsWithoutChangingBits(kind: String) throws {
        // ブロックの境目 (4096 バイト) をまたぐ長さにする
        let left = pattern(9_001, seed: 11), right = pattern(9_001, seed: 22)
        let data = kind == "dff" ? makeDFF(left: left, right: right) : makeDSF(left: left, right: right, lsbFirst: kind == "dsf-lsb")
        let source = try temporaryFile("a." + (kind == "dff" ? "dff" : "dsf"), data)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-dop-\(UUID().uuidString).wav")
        defer { [source, dest].forEach { try? FileManager.default.removeItem(at: $0) } }

        try DoP.wrap(source, info: try #require(DSDFile.info(source)), to: dest)
        let dop = try readDoP(dest)
        #expect(dop.rate == 176_400)
        // 16 ビットで 1 サンプル。端数は捨て、偶数個にそろえる
        #expect(dop.left.count == 4500 && dop.right.count == 4500)
        var wrong = 0
        for i in 0..<dop.left.count {
            let marker: UInt8 = i % 2 == 0 ? 0x05 : 0xFA
            if dop.left[i] != (marker, left[2 * i], left[2 * i + 1]) { wrong += 1 }
            if dop.right[i] != (marker, right[2 * i], right[2 * i + 1]) { wrong += 1 }
        }
        #expect(wrong == 0)
    }

    @Test("ステレオ以外の DSD は、DoP にしない")
    func refusesNonStereo() throws {
        var info = DSDFile.Info(sampleRate: 2_822_400, channels: 6, bitCount: 1600, dataOffset: 0, dataLength: 1200, layout: .dff)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-dop-\(UUID().uuidString).wav")
        #expect(throws: DoP.Failure.self) { try DoP.wrap(URL(fileURLWithPath: "/nonexistent"), info: info, to: dest) }
        info.channels = 2
        #expect(DoP.plan(for: info, conditions()) == .send(rate: 176_400))
        info.channels = 6
        #expect(DoP.plan(for: info, conditions()) == .convert(reason: "ステレオ以外の DSD"))
    }

    private func conditions(enabled: Bool = true, bitPerfect: Bool = true, exclusive: Bool = true, support: DoP.Support? = .verified,
                            rates: [Double] = [44100, 48000, 88200, 96000, 176_400, 192_000], bits: Int? = 24,
                            volume: Double? = 0.5) -> DoP.Conditions {
        DoP.Conditions(enabled: enabled, bitPerfect: bitPerfect, exclusive: exclusive, support: support, deviceRates: rates,
                       integerBits: bits, deviceVolume: volume)
    }

    @Test("対応していると確かめた DAC にだけ、条件がすべてそろったときに送る")
    func decidesWhenToSend() {
        let dsd64 = DSDFile.Info(sampleRate: 2_822_400, channels: 2, bitCount: 1 << 20, dataOffset: 0, dataLength: 1 << 18, layout: .dff)
        var dsd128 = dsd64
        dsd128.sampleRate = 5_644_800

        #expect(DoP.plan(for: dsd64, conditions()) == .send(rate: 176_400))
        // DSD でない曲と、設定がオフのときは、何も知らせずに普通に再生する
        #expect(DoP.plan(for: nil, conditions()) == .convert(reason: nil))
        #expect(DoP.plan(for: dsd64, conditions(enabled: false)) == .convert(reason: nil))
        // 対応しているか分からない DAC へは送らない
        #expect(DoP.plan(for: dsd64, conditions(support: nil)) == .convert(reason: "DAC の対応を未確認"))
        #expect(DoP.plan(for: dsd64, conditions(support: .unsupported)) == .convert(reason: "DAC が DoP に非対応"))
        // 加工やほかの音が入りうる状態では送らない
        #expect(DoP.plan(for: dsd64, conditions(bitPerfect: false)) == .convert(reason: "ビットパーフェクト再生がオフ"))
        #expect(DoP.plan(for: dsd64, conditions(exclusive: false)) == .convert(reason: "排他モードがオフ"))
        // デバイスが必要な形式に対応していなければ送らない
        #expect(DoP.plan(for: dsd128, conditions()) == .convert(reason: "デバイスが 352.8kHz に非対応"))
        #expect(DoP.plan(for: dsd64, conditions(rates: [44100, 48000, 96000])) == .convert(reason: "デバイスが 176.4kHz に非対応"))
        #expect(DoP.plan(for: dsd64, conditions(bits: 16)) == .convert(reason: "デバイスに 24bit の形式がない"))
        #expect(DoP.plan(for: dsd64, conditions(bits: nil)) == .convert(reason: "デバイスに 24bit の形式がない"))
        #expect(DoP.plan(for: dsd128, conditions(rates: [176_400, 352_800], bits: 32)) == .send(rate: 352_800))
    }

    @Test("音量を下げると DSD として読めなくなる DAC には、音量が最大のときだけ送る")
    func fullVolumeOnly() {
        let dsd = DSDFile.Info(sampleRate: 2_822_400, channels: 2, bitCount: 1 << 20, dataOffset: 0, dataLength: 1 << 18, layout: .dff)
        #expect(DoP.plan(for: dsd, conditions(support: .verifiedAtFullVolume, volume: 1)) == .send(rate: 176_400))
        #expect(DoP.plan(for: dsd, conditions(support: .verifiedAtFullVolume, volume: 0.6)) == .convert(reason: "DAC の音量が最大でない"))
        // Mac から音量を変えられない DAC は、いつも最大で出ている
        #expect(DoP.plan(for: dsd, conditions(support: .verifiedAtFullVolume, volume: nil)) == .send(rate: 176_400))
    }

    @Test("確認用の音は、正しい DoP で、440Hz の音が入っている")
    func testToneIsValid() throws {
        let url = try temporaryFile("tone.wav", DoP.testTone(seconds: 0.5))
        defer { try? FileManager.default.removeItem(at: url) }
        let dop = try readDoP(url)
        #expect(dop.rate == 176_400 && dop.left.count % 2 == 0)
        #expect(dop.left.indices.allSatisfy { dop.left[$0].0 == (($0 % 2 == 0) ? 0x05 : 0xFA) && dop.right[$0].0 == dop.left[$0].0 })
        // DSD に戻して、440Hz の成分の大きさを確かめる (鳴っている 0.1〜0.4 秒の区間)
        let wave = DSDModulator.decode(dop.left.flatMap { [$0.1, $0.2] })
        let rate = 2_822_400.0
        var re = 0.0, im = 0.0
        let range = Int(0.1 * rate)..<Int(0.4 * rate)
        for i in range {
            let phase = 2 * Double.pi * 440 * Double(i + 32) / rate
            re += wave[i] * sin(phase)
            im += wave[i] * cos(phase)
        }
        let amplitude = 2 * (re * re + im * im).squareRoot() / Double(range.count)
        #expect(abs(amplitude - 0.1) < 0.005)
    }
}

/// 再生エンジンを音を出さない設定で動かして、出てくる波形を集める (出力のサンプルレートを選べる)
@MainActor
private func render(_ audio: AudioEngine, frames: Int, rate: Double) throws -> (left: [Float], right: [Float]) {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
    let chunk = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
    var left = [Float](), right = [Float]()
    while left.count < frames {
        let status = try audio.engine.renderOffline(AVAudioFrameCount(min(1024, frames - left.count)), to: chunk)
        #expect(status == .success)
        left += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
        right += UnsafeBufferPointer(start: chunk.floatChannelData![1], count: Int(chunk.frameLength))
    }
    return (left, right)
}

@Suite("DoP を流している間の再生エンジン", .serialized)
@MainActor
struct DoPEngineTests {
    private func makeItem(seconds: Double = 2) throws -> (item: PlaybackItem, url: URL, left: [UInt8], right: [UInt8]) {
        let count = Int(seconds * 176_400) * 2
        let left = pattern(count, seed: 5), right = pattern(count, seed: 9)
        let source = try temporaryFile("a.dff", makeDFF(left: left, right: right))
        defer { try? FileManager.default.removeItem(at: source) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-dop-\(UUID().uuidString).wav")
        try DoP.wrap(source, info: try #require(DSDFile.info(source)), to: url)
        let item = PlaybackItem(trackID: UUID(), file: try AVAudioFile(forReading: url), source: url, start: 0, end: nil, gain: 0.5, isDoP: true)
        return (item, url, left, right)
    }

    @Test("音量・フェード・EQ・ASMR の処理・左右バランスをどう設定していても、DoP のデータは 1 ビットも変わらずに出力まで届く")
    func nothingTouchesDoP() throws {
        let made = try makeItem()
        defer { try? FileManager.default.removeItem(at: made.url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 176_400, channels: 2))
        let audio = AudioEngine(offlineFormat: format)
        // わざと、音を変える設定をすべて入れておく
        audio.volume = 0.4
        audio.fadeMultiplier = 0.3
        audio.balance = 0.6
        audio.softTransitions = true
        audio.crossfadeDuration = 5
        audio.setEQ(bands: [6, 3, 0, -2, 0, 0, 4, 0, 0, 5], preamp: -3, enabled: true)
        var asmr = ASMRSettings()
        asmr.dynamics = true
        asmr.limiter = true
        asmr.swap = true
        asmr.crossfeedCut = 700
        audio.asmrSettings = asmr
        audio.eqProfile = EQProfile(name: "test", preamp: -4, bands: [ParametricBand(kind: .peak, frequency: 1000, gain: 6, q: 1)])

        #expect(audio.dopReady(for: made.item))
        audio.load(made.item, at: 0.25, play: true)     // 曲の途中から (ふだんならフェードインする場面)
        let out = try render(audio, frames: 60_000, rate: 176_400)

        // 出力は、処理ユニットの遅れの分だけずれた、ファイルのデータそのもの
        func word(_ x: Float) -> UInt32 { UInt32(bitPattern: Int32((x * 8_388_608).rounded())) & 0xFF_FFFF }
        func expected(_ bytes: [UInt8], _ frame: Int) -> UInt32 {
            UInt32(frame % 2 == 0 ? 0x05 : 0xFA) << 16 | UInt32(bytes[2 * frame]) << 8 | UInt32(bytes[2 * frame + 1])
        }
        let start = Int(0.25 * 176_400)
        let latency = ASMRKernel.latencyFrames(sampleRate: 176_400)
        let delay = try #require(((latency - 4)...(latency + 4)).first { d in
            (2000..<2100).allSatisfy { word(out.left[$0]) == expected(made.left, start + $0 - d) }
        }, "出力が DoP のデータと一致する遅れが見つからない")
        var wrong = 0
        for i in (delay + 16)..<60_000 {
            if word(out.left[i]) != expected(made.left, start + i - delay) { wrong += 1 }
            if word(out.right[i]) != expected(made.right, start + i - delay) { wrong += 1 }
        }
        #expect(wrong == 0)
        // 一時停止も、絞らずにすぐ止まる
        audio.pause()
        #expect(!audio.isPlaying)
    }

    @Test("消音にしたときだけ、出力を 0 にする (中途半端な音量にはしない)")
    func muteIsSilence() throws {
        let made = try makeItem(seconds: 1)
        defer { try? FileManager.default.removeItem(at: made.url) }
        let audio = AudioEngine(offlineFormat: try #require(AVAudioFormat(standardFormatWithSampleRate: 176_400, channels: 2)))
        audio.volume = 0
        audio.load(made.item, play: true)
        let out = try render(audio, frames: 20_000, rate: 176_400)
        #expect(out.left.allSatisfy { $0 == 0 } && out.right.allSatisfy { $0 == 0 })
    }

    @Test("サンプルレートが合わない出力へは、DoP を流さない (変換されると雑音になる)")
    func refusesWhenRateDiffers() throws {
        let made = try makeItem(seconds: 1)
        defer { try? FileManager.default.removeItem(at: made.url) }
        let audio = AudioEngine(offlineFormat: try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)))
        var failed = false
        audio.onStartFailure = { failed = true }
        #expect(!audio.dopReady(for: made.item))
        audio.load(made.item, play: true)
        #expect(failed && !audio.isPlaying && audio.current == nil)
    }

    @Test("速度を変える部品が入っているときも、DoP を流さない")
    func refusesWhenRateChanged() throws {
        let made = try makeItem(seconds: 1)
        defer { try? FileManager.default.removeItem(at: made.url) }
        let audio = AudioEngine(offlineFormat: try #require(AVAudioFormat(standardFormatWithSampleRate: 176_400, channels: 2)))
        audio.rate = 1.25
        #expect(!audio.dopReady(for: made.item))
        audio.rate = 1
        #expect(audio.dopReady(for: made.item))
    }
}

@Suite("アップサンプリング", .serialized)
@MainActor
struct UpsamplingTests {
    private static let rates: [Double] = [44100, 48000, 88200, 96000, 176_400, 192_000, 352_800, 384_000]

    nonisolated private static let cases: [(Upsampling, Double, Double?)] = [
        (.off, 44100, nil),
        (.double, 44100, 88200), (.double, 48000, 96000), (.double, 96000, 192_000), (.double, 192_000, 384_000),
        (.quadruple, 44100, 176_400), (.quadruple, 96000, 384_000), (.quadruple, 192_000, 384_000),
        (.maximum, 44100, 352_800), (.maximum, 48000, 384_000), (.maximum, 88200, 352_800),
        (.maximum, 384_000, nil),      // もうデバイスの上限
        (.double, 32000, nil),         // 倍のレート (64kHz) に対応していない
    ]

    @Test("曲の 2 倍・4 倍…のうち、デバイスが対応していて上限を超えない、いちばん高いサンプルレートを選ぶ", arguments: cases)
    func choosesRate(mode: Upsampling, fileRate: Double, expected: Double?) {
        #expect(mode.rate(for: fileRate, available: Self.rates) == expected)
    }

    @Test("対応するレートがなければ上げない")
    func noRates() {
        #expect(Upsampling.maximum.rate(for: 44100, available: []) == nil)
        #expect(Upsampling.maximum.rate(for: 44100, available: [44100, 48000]) == nil)
        #expect(Upsampling.quadruple.rate(for: 44100, available: [44100, 88200]) == 88200)   // 4 倍がなければ 2 倍
    }

    @Test("サンプルレートの変換は、20kHz まで元の大きさを保ち、折り返しの成分を出さない (アップサンプリングでも、ふつうの変換でも)",
          arguments: [176_400.0, 88200, 48000])
    func conversionQuality(outRate: Double) throws {
        // 1kHz・10kHz・19kHz・20kHz を入れた 44.1kHz のファイル
        let tones: [(Double, Double)] = [(1000, 0.2), (10000, 0.2), (19000, 0.2), (20000, 0.2)]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-up-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let fileFormat = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: 44100 * 3))
        buffer.frameLength = 44100 * 3
        for i in 0..<Int(buffer.frameLength) {
            let v = tones.reduce(0.0) { $0 + $1.1 * sin(2 * Double.pi * $1.0 * Double(i) / 44100) }
            buffer.floatChannelData![0][i] = Float(v)
            buffer.floatChannelData![1][i] = Float(v)
        }
        do {
            let writer = try AVAudioFile(forWriting: url, settings: fileFormat.settings)
            try writer.write(from: buffer)
            writer.close()
        }
        let audio = AudioEngine(offlineFormat: try #require(AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2)))
        audio.volume = 1
        audio.load(PlaybackItem(trackID: UUID(), file: try AVAudioFile(forReading: url), source: url, start: 0, end: nil, gain: 1), play: true)
        let out = try render(audio, frames: Int(outRate) * 2, rate: outRate).left

        // 落ち着いたあとの 1 秒分で、それぞれの周波数の大きさを測る (ハン窓をかけて)
        let range = Int(outRate / 2)..<Int(outRate * 3 / 2)
        func level(_ frequency: Double) -> Double {
            var re = 0.0, im = 0.0, norm = 0.0
            for (k, i) in range.enumerated() {
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(k) / Double(range.count))
                let phase = 2 * Double.pi * frequency * Double(i) / outRate
                re += w * Double(out[i]) * sin(phase)
                im += w * Double(out[i]) * cos(phase)
                norm += w
            }
            return 20 * log10(max(1e-12, 2 * (re * re + im * im).squareRoot() / norm))
        }
        // 元の音は、20kHz でも大きさが変わらない (ミキサーに任せていたときは、20kHz で約 8 dB 落ちていた)
        for (frequency, amplitude) in tones {
            #expect(abs(level(frequency) - 20 * log10(amplitude)) < 0.01, "\(frequency) Hz")
        }
        // 元のサンプルレートで折り返した成分 (44.1kHz - f など) と、何もないはずの周波数は、-130 dBFS 以下
        let images: [Double] = [24100, 25100, 34100, 45100, 68200, 5000, 15000, 21500].filter { $0 < outRate / 2 - 500 }
        for image in images {
            #expect(level(image) < -130, "\(image) Hz")
        }
    }
}
