import AudioToolbox
import AVFoundation
import Synchronization

// MARK: - 設定

/// ASMR モードの「音量のならし」の強さ
enum ASMRStrength: String, CaseIterable, Identifiable {
    case gentle, standard, firm, custom

    var id: String { rawValue }
    var label: String { ["gentle": "穏やか", "standard": "標準", "firm": "しっかり", "custom": "カスタム"][rawValue]! }

    /// 圧縮カーブ。小さい音は upThreshold から下を最大 maxBoost まで持ち上げ、
    /// 大きい音は downThreshold から上を downRatio で抑える。
    /// カスタムのときは custom の値を使う
    func apply(to s: inout ASMRSettings, custom: ASMRCustomCurve = ASMRCustomCurve()) {
        switch self {
        case .gentle:
            (s.upThreshold, s.upRatio, s.maxBoost, s.noiseFloor, s.boostRise) = (-32, 1.8, 8, -60, 0.6)
            (s.downThreshold, s.downRatio, s.attack, s.release) = (-18, 2.2, 0.008, 0.5)
        case .standard:
            (s.upThreshold, s.upRatio, s.maxBoost, s.noiseFloor, s.boostRise) = (-30, 2.3, 11, -62, 0.45)
            (s.downThreshold, s.downRatio, s.attack, s.release) = (-21, 3, 0.006, 0.4)
        case .firm:
            (s.upThreshold, s.upRatio, s.maxBoost, s.noiseFloor, s.boostRise) = (-28, 3, 14, -64, 0.35)
            (s.downThreshold, s.downRatio, s.attack, s.release) = (-24, 4, 0.005, 0.3)
        case .custom:
            (s.upThreshold, s.upRatio, s.maxBoost, s.noiseFloor, s.boostRise) = (custom.upThreshold, 2.3, custom.maxBoost, -62, 0.45)
            (s.downThreshold, s.downRatio, s.attack, s.release) = (custom.downThreshold, custom.downRatio, 0.006, 0.4)
        }
    }
}

/// 「カスタム」の強さで自分で決める値
struct ASMRCustomCurve: Codable, Equatable {
    /// これより小さい音を持ち上げる (dBFS)
    var upThreshold: Float = -30
    /// 持ち上げる量の上限 (dB)
    var maxBoost: Float = 11
    /// これより大きい音を抑える (dBFS)
    var downThreshold: Float = -21
    /// 抑える比率 (3 なら、超えた分を 1/3 にする)
    var downRatio: Float = 3
}

/// 高音の刺さり (サ行の音や金属音) のやわらげ方
enum ASMRSoftening: String, CaseIterable, Identifiable {
    case off, light, strong

    var id: String { rawValue }
    var label: String { ["off": "オフ", "light": "弱", "strong": "強"][rawValue]! }

    func apply(to s: inout ASMRSettings) {
        switch self {
        case .off: s.deEssMax = 0
        case .light: (s.deEssThreshold, s.deEssMax) = (-30, 5)
        case .strong: (s.deEssThreshold, s.deEssMax) = (-36, 9)
        }
    }
}

/// 処理ユニットへ渡す設定 (メインスレッドで作り、音声スレッドが読む)
struct ASMRSettings {
    /// 小さい音を持ち上げ、大きい音を抑える (左右は同じゲインで動かし、定位を崩さない)
    var dynamics = false
    /// 急な大音量を ceiling で止める (先読みして、山が来る前に下げておく)
    var limiter = false
    /// 左右の入れ替え
    var swap = false

    var upThreshold: Float = -32
    var upRatio: Float = 1.8
    var maxBoost: Float = 8
    /// これより静かな間 (言葉の合間・無音) は持ち上げ量を据え置き、ノイズだけが大きくならないようにする。
    /// 録音のノイズがこれより大きいときは、ノイズの推定値から決める
    var noiseFloor: Float = -60
    var downThreshold: Float = -18
    var downRatio: Float = 2.2
    /// 大きな音が来たときに下げる速さと、抑えを戻す速さ (秒)
    var attack: Float = 0.008
    var release: Float = 0.5
    /// 小さな音が続いたときに持ち上げていく速さ (秒)。音節ごとに揺れないよう、ゆっくりにする
    var boostRise: Float = 0.6

    /// ラウドネス補正 (dB)。小音量で聞こえにくくなる低域・高域を持ち上げる
    var loudnessLow: Float = 0
    var loudnessHigh: Float = 0

    /// 高音の刺さりをやわらげる: 5kHz より上の大きさが deEssThreshold (dBFS) を超えたら、
    /// 超えた分の半分だけ高音を下げる。deEssMax は下げる量の上限 (dB)。0 ならオフ
    var deEssThreshold: Float = -30
    var deEssMax: Float = 0

    /// 低い雑音 (マイクに触れる音・空調・風) を切る周波数 (Hz)。0 ならオフ
    var lowCut: Float = 0

    /// ヘッドホン用のクロスフィード: 反対側の耳に、低音を中心に少しだけ音を回す。
    /// crossfeedCut は回す音の上限の周波数 (Hz、0 ならオフ)、crossfeedLevel は回す量 (dB)
    var crossfeedCut: Float = 0
    var crossfeedLevel: Float = 4.5

    /// リミッターの上限 (ASMR モードでは -3 dBFS)
    var ceiling: Float = 0.708
    /// 音を一時的に絞る (1 = そのまま、0 = 無音)。ループのつなぎ目・一時停止・シークで使う
    var duck: Float = 1
    /// duck の値へ近づく時定数 (秒)
    var duckTime: Float = 0.006
    /// 値が変わったら、いったん無音にしてから duck へ向けて上げ直す (曲の途中から鳴らし始めるときのフェードイン)
    var duckRestart: UInt32 = 0
}

/// スレッド間で、決まった長さのデータを待たせずに渡す (シーケンスロック)。
///
/// 書く側は番号を奇数にしてから書き、書き終えたら偶数に進める。
/// 読む側はコピーの前後で番号を読み、奇数だったり前後で違っていたりしたら (= 書き込みと重なった) 読み直す。
/// 読む側 (音声スレッド) はロックを取らず、待たされることがない。
///
/// 中身も 1 語 (8 バイト) ずつアトミックに読み書きする。番号だけをアトミックにして中身を普通にコピーすると、
/// ARM では中身の読み書きが番号の読み書きと前後して実行されることがあり、番号が一致しているのに
/// 書きかけの値を読んでしまう (テストで実際に起きた)。すべてをアトミックにすれば全体に順序が付く。
final class SeqlockWords: @unchecked Sendable {
    /// 読み直しの上限。書き込みと重なり続けたら諦め、次の描画でやり直す (音声スレッドを回し続けない)
    private static let readAttempts = 4
    let wordCount: Int
    private let sequence = Atomic<Int>(0)
    private let words: UnsafeMutablePointer<Atomic<UInt64>>
    /// 書く側どうしの順番待ち (読む側は取らない)
    private let writeLock = NSLock()

    init(wordCount: Int) {
        self.wordCount = wordCount
        words = .allocate(capacity: wordCount)
        for i in 0..<wordCount { (words + i).initialize(to: Atomic(0)) }
    }

    deinit {
        words.deinitialize(count: wordCount)
        words.deallocate()
    }

    /// 最初の値を入れる (番号は進めない)
    func prime(_ source: UnsafePointer<UInt64>) {
        for i in 0..<wordCount { words[i].store(source[i], ordering: .sequentiallyConsistent) }
    }

    func publish(_ source: UnsafePointer<UInt64>) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let v = sequence.load(ordering: .sequentiallyConsistent)
        sequence.store(v &+ 1, ordering: .sequentiallyConsistent)   // 奇数: 書き込み中
        for i in 0..<wordCount { words[i].store(source[i], ordering: .sequentiallyConsistent) }
        sequence.store(v &+ 2, ordering: .sequentiallyConsistent)   // 偶数: 書き終えた
    }

    /// 音声スレッド用: version より新しい値があれば destination に写し、その番号を返す
    @inline(__always)
    func read(ifNewerThan version: Int, into destination: UnsafeMutablePointer<UInt64>) -> Int? {
        for _ in 0..<Self.readAttempts {
            let before = sequence.load(ordering: .sequentiallyConsistent)
            if before == version { return nil }
            guard before & 1 == 0 else { continue }
            for i in 0..<wordCount { destination[i] = words[i].load(ordering: .sequentiallyConsistent) }
            if sequence.load(ordering: .sequentiallyConsistent) == before { return before }
        }
        return nil
    }
}

/// メインスレッドと音声スレッドの受け渡し
final class ASMRShared: @unchecked Sendable {
    /// パラメトリック EQ のバンド数の上限
    static let eqBands = 16
    /// EQ の係数の受け渡しに使う語数 (バンド数 + 1 バンドあたり b0 b1 b2 a1 a2)
    static let eqWords = (1 + 5 * eqBands + 1) / 2
    static let meterCount = 6

    private static let settingsBytes = MemoryLayout<ASMRSettings>.size
    private static let settingsWords = (settingsBytes + 7) / 8
    private let settings = SeqlockWords(wordCount: settingsWords)
    private let eq = SeqlockWords(wordCount: eqWords)
    /// 表示用: [持ち上げ量 dB, 抑え量 dB (負), リミッター dB (負), 高音のやわらげ dB (負), 入力の大きさ dBFS, 出力の大きさ dBFS]
    let meters = UnsafeMutablePointer<Float>.allocate(capacity: meterCount)

    init() {
        meters.initialize(repeating: 0, count: Self.meterCount)
        withWords(of: ASMRSettings()) { settings.prime($0) }
        withEQWords([]) { eq.prime($0) }
    }

    deinit { meters.deallocate() }

    func publish(_ s: ASMRSettings) {
        withWords(of: s) { settings.publish($0) }
    }

    /// 音声スレッド用: 新しい設定があれば、その番号と一緒に返す
    @inline(__always)
    func read(ifNewerThan version: Int) -> (Int, ASMRSettings)? {
        withUnsafeTemporaryAllocation(of: UInt64.self, capacity: Self.settingsWords) { buffer -> (Int, ASMRSettings)? in
            guard let v = settings.read(ifNewerThan: version, into: buffer.baseAddress!) else { return nil }
            var result = ASMRSettings()
            withUnsafeMutableBytes(of: &result) { $0.copyMemory(from: UnsafeRawBufferPointer(start: buffer.baseAddress, count: Self.settingsBytes)) }
            return (v, result)
        }
    }

    private func withWords(of s: ASMRSettings, _ body: (UnsafePointer<UInt64>) -> Void) {
        var words = [UInt64](repeating: 0, count: Self.settingsWords)
        withUnsafeBytes(of: s) { source in
            words.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<Self.settingsBytes])) }
        }
        words.withUnsafeBufferPointer { body($0.baseAddress!) }
    }

    // MARK: パラメトリック EQ の係数

    /// バンドごとの係数 [b0, b1, b2, a1, a2] を渡す (eqBands 個まで)
    func publishEQ(_ bands: [[Float]]) {
        withEQWords(bands) { eq.publish($0) }
    }

    /// 音声スレッド用: 新しい係数があれば destination (1 + 5 × eqBands 個の Float) に写し、その番号を返す
    @inline(__always)
    func readEQ(ifNewerThan version: Int, into destination: UnsafeMutablePointer<Float>) -> Int? {
        destination.withMemoryRebound(to: UInt64.self, capacity: Self.eqWords) { eq.read(ifNewerThan: version, into: $0) }
    }

    private func withEQWords(_ bands: [[Float]], _ body: (UnsafePointer<UInt64>) -> Void) {
        var floats = [Float](repeating: 0, count: Self.eqWords * 2)
        let count = min(bands.count, Self.eqBands)
        floats[0] = Float(count)
        for i in 0..<Self.eqBands {
            let c = i < count && bands[i].count == 5 ? bands[i] : [1, 0, 0, 0, 0]
            for k in 0..<5 { floats[1 + i * 5 + k] = c[k] }
        }
        floats.withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: UInt64.self)) }
    }
}

// MARK: - 信号処理

private struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0

    enum Kind { case lowShelf, highShelf }

    /// RBJ のシェルビングフィルター。cw / sw は折れ点の周波数の cos / sin
    /// (サンプルレートだけで決まるので先に計算しておき、補正量が動くたびの計算を軽くする)
    init(_ kind: Kind, cw: Double, sw: Double, gainDB: Double, slope: Double) {
        guard abs(gainDB) > 0.001 else { return }
        let A = pow(10, gainDB / 40)
        let alpha = sw / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2)
        let k = 2 * sqrt(A) * alpha
        let (nb0, nb1, nb2, na0, na1, na2): (Double, Double, Double, Double, Double, Double)
        switch kind {
        case .lowShelf:
            (nb0, nb1, nb2) = (A * ((A + 1) - (A - 1) * cw + k), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - k))
            (na0, na1, na2) = ((A + 1) + (A - 1) * cw + k, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - k)
        case .highShelf:
            (nb0, nb1, nb2) = (A * ((A + 1) + (A - 1) * cw + k), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - k))
            (na0, na1, na2) = ((A + 1) - (A - 1) * cw + k, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - k)
        }
        b0 = Float(nb0 / na0); b1 = Float(nb1 / na0); b2 = Float(nb2 / na0)
        a1 = Float(na1 / na0); a2 = Float(na2 / na0)
    }

    init() {}

    /// 2 次のハイパス
    static func highPass(cw: Double, sw: Double, q: Double) -> Biquad {
        let alpha = sw / (2 * q)
        let a0 = 1 + alpha
        var f = Biquad()
        f.b0 = Float((1 + cw) / 2 / a0); f.b1 = Float(-(1 + cw) / a0); f.b2 = f.b0
        f.a1 = Float(-2 * cw / a0); f.a2 = Float((1 - alpha) / a0)
        return f
    }
}

/// 音声スレッドだけが触る処理本体。メモリ確保・ロック・参照カウントを伴う操作をしない。
///
/// 通す順番: 左右の入れ替え → パラメトリック EQ → クロスフィード → 低い雑音のカット →
/// コンプレッサー (先読み) → ラウドネス補正 → 高音のやわらげ → リミッター (先読み・トゥルーピーク)
struct ASMRKernel {
    private static let block = 16           // ゲインを計算し直す間隔 (サンプル)
    private static let loudnessTime: Float = 0.04 // ラウドネス補正量が目標に近づく時定数 (秒)
    private static let delayCapacity = 2048 // リミッターの先読み用の遅延バッファ (2 の累乗)
    private static let lookCapacity = 4096  // コンプレッサーの先読み用の遅延バッファ (2 の累乗)
    private static let lookSeconds = 0.005  // コンプレッサーの先読み
    private static let limitSeconds = 0.003 // リミッターの先読み
    private static let eqBands = ASMRShared.eqBands
    private static let eqRampBlocks = 96    // EQ の係数を新しい値へ動かす長さ (ブロック数、約 32ms)
    private static let mixTime: Float = 0.02 // クロスフィード・低域カットを入れたり切ったりするときのつなぎ (秒)

    /// サンプルの間の山 (トゥルーピーク) を見積もるための 4 倍補間フィルター。
    /// 1 サンプルの間を 4 つに分けた 1/4, 2/4, 3/4 の位置の値を、前後 12 サンプルから求める
    private static let peakTaps = 12
    private static let peakDelay = 6
    private static let peakFilter: [Float] = {
        var taps = [Float](repeating: 0, count: 3 * peakTaps)
        for phase in 1...3 {
            for j in 0..<peakTaps {
                // 補間する位置から見た、j 番目のサンプルまでの距離 (サンプル単位)
                let x = Double(j - (peakTaps / 2 - 1)) - Double(phase) / 4
                let sinc = sin(Double.pi * x) / (Double.pi * x)
                let window = 0.5 + 0.5 * cos(Double.pi * x / Double(peakTaps / 2))   // ハン窓
                taps[(phase - 1) * peakTaps + j] = Float(sinc * max(0, window))
            }
        }
        return taps
    }()

    /// 入力から出力までの遅れ (サンプル)。設定にかかわらず一定
    static func latencyFrames(sampleRate: Double) -> Int {
        lookFrames(sampleRate) + limitFrames(sampleRate) + peakDelay
    }

    private static func lookFrames(_ sampleRate: Double) -> Int { max(1, min(lookCapacity - 1, Int(lookSeconds * sampleRate))) }
    private static func limitFrames(_ sampleRate: Double) -> Int { max(1, min(delayCapacity - 2 - peakDelay, Int(limitSeconds * sampleRate))) }

    private var sr: Float = 48000
    private var s = ASMRSettings()
    private var version = -1
    private var eqVersion = -1

    // 係数
    private var envAtt: Float = 0, envRel: Float = 0, envFastAtt: Float = 0
    private var levelUp: Float = 0, levelDown: Float = 0
    private var cutAtt: Float = 0, cutRel: Float = 0
    private var boostRise: Float = 0, boostDrop: Float = 0, boostFast: Float = 0, silenceDecay: Float = 0
    private var noiseRise: Float = 0
    private var limRel: Float = 0
    private var duckCoef: Float = 0
    private var loudCoef: Float = 0
    private var mixCoef: Float = 0
    private var lowTrig = (cw: 1.0, sw: 0.0), highTrig = (cw: 1.0, sw: 0.0), essTrig = (cw: 1.0, sw: 0.0)
    private var low = Biquad(), high = Biquad()
    private var hfAtt: Float = 0, hfRel: Float = 0
    private var essAtt: Float = 0, essRel: Float = 0
    /// 高音の大きさを測るためのハイパス (2 段で 4 次。声の中域に反応しないよう急にする) と、高音を下げるシェルビング
    private var side1 = Biquad(), side2 = Biquad(), ess = Biquad()
    /// 低い雑音を切るハイパスと、今使っている周波数
    private var rumble = Biquad()
    private var rumbleFrequency: Float = 0
    /// クロスフィードの係数
    private var feedLowA: Float = 0, feedLowB: Float = 0
    private var feedHighA0: Float = 1, feedHighA1: Float = 0, feedHighB: Float = 0, feedGain: Float = 1
    private var feedCut: Float = 0, feedLevel: Float = 0

    // 状態
    private var env: Float = 0
    /// 抑え用の、立ち上がりの速いレベル検出 (先読みの間に、大きな音の本当の大きさまで追いつく)
    private var envFast: Float = 0
    private var outEnv: Float = 0
    /// 持ち上げ量の判定に使う、dB で平滑化したレベルと、録音のノイズの推定値
    private var levelDB: Float = -100
    private var noiseDB: Float = -100
    private var boostDB: Float = 0
    private var cutDB: Float = 0
    private var gainLin: Float = 1
    private var gainStep: Float = 0
    private var counter = 0
    private var fz = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
    /// 高音のやわらげ: 測定用フィルターの状態、高音の大きさ、今の下げ量 (dB, 0 以下) と係数に反映済みの値
    private var sz = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
    private var ez = (Float(0), Float(0), Float(0), Float(0))
    private var hfEnv: Float = 0
    private var essDB: Float = 0
    private var essApplied: Float = 0
    /// 低い雑音のカット: フィルターの状態と、かかり具合 (0 = 素通し、1 = すべてフィルター後)
    private var rz = (Float(0), Float(0), Float(0), Float(0))
    private var rumbleMix: Float = 0
    /// クロスフィード: フィルターの状態 (低域 L R、高域 L R、1 つ前の入力 L R) と、かかり具合
    private var cz = (Float(0), Float(0), Float(0), Float(0), Float(0), Float(0))
    private var feedMix: Float = 0
    private var duck: Float = 1
    private var lastRestart: UInt32 = 0
    /// 今かかっているラウドネス補正量 (dB)。設定値へ少しずつ近づける
    private var loudLow: Float = 0
    private var loudHigh: Float = 0
    /// 再生を始めた直後は、近づけずにその場で設定値に合わせる
    private var snapLoudness = true
    /// 補正量が 0 に戻ったあと、フィルターに残った値を流しきるまでのサンプル数
    private var loudFlush = 0

    // パラメトリック EQ: 今の係数・目標の係数 (バンドごとに b0 b1 b2 a1 a2)、状態 (バンドごとに L の z1 z2、R の z1 z2)
    private var eqCurrent: UnsafeMutablePointer<Float>?
    private var eqTarget: UnsafeMutablePointer<Float>?
    private var eqState: UnsafeMutablePointer<Float>?
    private var eqIncoming: UnsafeMutablePointer<Float>?
    private var eqCount = 0
    private var eqTargetCount = 0
    private var eqRamp = 0
    private var snapEQ = true

    // コンプレッサーの先読み
    private var look: UnsafeMutablePointer<Float>?
    private var lookLen = 240
    private var lookPos = 0

    // リミッター
    private var delay: UnsafeMutablePointer<Float>?
    private var delayLen = 144
    private var delayPos = 0
    /// 先読みする区間 (delayLen + 1 サンプル) の中で、必要なゲインが最も小さいものを追うための列
    /// (値が小さい順に並ぶように保つ。先頭がその区間の最小)
    private var queueValue: UnsafeMutablePointer<Float>?
    private var queueTime: UnsafeMutablePointer<Int>?
    private var queueHead = 0
    private var queueCount = 0
    private var time = 0
    /// 山を過ぎたあとゆっくり戻すゲインと、その移動平均
    private var limHold: Float = 1
    private var average: UnsafeMutablePointer<Float>?
    private var averageSum = 0.0
    /// トゥルーピーク用の補間フィルターの係数 (音声スレッドで静的な配列を初期化しないよう、先に写しておく)
    private var peakFilter: UnsafeMutablePointer<Float>?

    private(set) var scratch: UnsafeMutablePointer<Float>?
    private(set) var maxFrames = 0

    // 表示用 (ブロックごとの値)
    private var meterLimit: Float = 1

    mutating func prepare(sampleRate: Double, maxFrames: Int) {
        release()
        sr = Float(sampleRate)
        self.maxFrames = maxFrames
        func buffer(_ count: Int, _ value: Float = 0) -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: count)
            p.initialize(repeating: value, count: count)
            return p
        }
        scratch = buffer(2 * maxFrames)
        delay = buffer(2 * Self.delayCapacity)
        look = buffer(2 * Self.lookCapacity)
        queueValue = buffer(Self.delayCapacity, 1)
        queueTime = .allocate(capacity: Self.delayCapacity)
        queueTime?.initialize(repeating: 0, count: Self.delayCapacity)
        average = buffer(Self.delayCapacity, 1)
        eqCurrent = buffer(5 * Self.eqBands)
        eqTarget = buffer(5 * Self.eqBands)
        eqState = buffer(4 * Self.eqBands)
        eqIncoming = buffer(ASMRShared.eqWords * 2)
        peakFilter = buffer(Self.peakFilter.count)
        for (i, tap) in Self.peakFilter.enumerated() { peakFilter?[i] = tap }
        for i in 0..<Self.eqBands {
            eqCurrent?[i * 5] = 1
            eqTarget?[i * 5] = 1
        }
        eqCount = 0; eqTargetCount = 0; eqRamp = 0; snapEQ = true; eqVersion = -1
        lookLen = Self.lookFrames(sampleRate)
        lookPos = 0
        delayLen = Self.limitFrames(sampleRate)
        delayPos = 0
        queueHead = 0; queueCount = 0; time = 0
        limHold = 1
        averageSum = Double(delayLen + 1)
        env = 0; envFast = 0; outEnv = 0; levelDB = -100; noiseDB = -100; boostDB = 0; cutDB = 0; gainLin = 1; gainStep = 0; counter = 0
        fz = (0, 0, 0, 0, 0, 0, 0, 0)
        sz = (0, 0, 0, 0, 0, 0, 0, 0); ez = (0, 0, 0, 0)
        rz = (0, 0, 0, 0); cz = (0, 0, 0, 0, 0, 0)
        rumbleMix = 0; rumbleFrequency = 0; feedMix = 0; feedCut = 0; feedLevel = 0
        hfEnv = 0; essDB = 0; essApplied = 0; ess = Biquad()
        envAtt = 1 - exp(-1 / (0.005 * sr))
        envRel = 1 - exp(-1 / (0.04 * sr))
        envFastAtt = 1 - exp(-1 / (Float(Self.lookSeconds) / 4 * sr))
        limRel = 1 - exp(-1 / (0.12 * sr))
        hfAtt = 1 - exp(-1 / (0.001 * sr))
        hfRel = 1 - exp(-1 / (0.015 * sr))
        loudCoef = 1 - exp(-Float(Self.block) / (Self.loudnessTime * sr))
        mixCoef = 1 - exp(-1 / (Self.mixTime * sr))
        lowTrig = trig(110)
        highTrig = trig(9000)
        essTrig = trig(5500)
        let sideTrig = trig(5000)
        side1 = .highPass(cw: sideTrig.cw, sw: sideTrig.sw, q: 0.5412)
        side2 = .highPass(cw: sideTrig.cw, sw: sideTrig.sw, q: 1.3066)
        snapLoudness = true
        version = -1
    }

    private func trig(_ frequency: Double) -> (cw: Double, sw: Double) {
        let w0 = 2 * Double.pi * min(frequency, Double(sr) * 0.45) / Double(sr)
        return (cos(w0), sin(w0))
    }

    mutating func release() {
        scratch?.deallocate(); scratch = nil
        delay?.deallocate(); delay = nil
        look?.deallocate(); look = nil
        queueValue?.deallocate(); queueValue = nil
        queueTime?.deallocate(); queueTime = nil
        average?.deallocate(); average = nil
        eqCurrent?.deallocate(); eqCurrent = nil
        eqTarget?.deallocate(); eqTarget = nil
        eqState?.deallocate(); eqState = nil
        eqIncoming?.deallocate(); eqIncoming = nil
        peakFilter?.deallocate(); peakFilter = nil
        maxFrames = 0
    }

    /// 新しい設定を取り込み、係数を計算し直す
    @inline(__always)
    mutating func sync(_ shared: ASMRShared) {
        syncEQ(shared)
        guard let (v, settings) = shared.read(ifNewerThan: version) else { return }
        version = v
        s = settings
        let b = Float(Self.block)
        func coef(_ t: Float) -> Float { 1 - exp(-b / (max(0.0005, t) * sr)) }
        // 先読みの間に下げきれるよう、抑えは先読みの 1/3 の時定数より遅くしない
        cutAtt = coef(min(s.attack, Float(Self.lookSeconds) / 3))
        cutRel = coef(s.release)
        levelUp = coef(0.03)
        levelDown = coef(0.25)
        boostRise = coef(s.boostRise)
        boostDrop = coef(0.05)
        boostFast = coef(Float(Self.lookSeconds) / 3)
        silenceDecay = coef(4)
        essAtt = coef(0.002)
        essRel = coef(0.08)
        noiseRise = 0.5 * b / sr   // ノイズの推定値は 1 秒に 0.5dB ずつしか上げない
        duckCoef = 1 - exp(-1 / (max(0.001, s.duckTime) * sr))
        if s.duckRestart != lastRestart {
            lastRestart = s.duckRestart
            duck = 0
        }
        if s.lowCut > 0, s.lowCut != rumbleFrequency {
            rumbleFrequency = s.lowCut
            let t = trig(Double(s.lowCut))
            rumble = .highPass(cw: t.cw, sw: t.sw, q: 0.7071)
        }
        if s.crossfeedCut > 0, s.crossfeedCut != feedCut || s.crossfeedLevel != feedLevel {
            feedCut = s.crossfeedCut
            feedLevel = s.crossfeedLevel
            updateCrossfeed()
        }
        if snapLoudness {
            snapLoudness = false
            loudLow = s.loudnessLow
            loudHigh = s.loudnessHigh
            updateLoudnessFilters()
            // 再生を始めた時点で入っている処理は、つながずに最初からかける
            rumbleMix = s.lowCut > 0 ? 1 : 0
            feedMix = s.crossfeedCut > 0 ? 1 : 0
        }
    }

    /// パラメトリック EQ の新しい係数を取り込む。係数は約 32ms かけて新しい値へ動かす
    @inline(__always)
    private mutating func syncEQ(_ shared: ASMRShared) {
        guard let incoming = eqIncoming, let target = eqTarget, let current = eqCurrent,
              let v = shared.readEQ(ifNewerThan: eqVersion, into: incoming) else { return }
        eqVersion = v
        eqTargetCount = max(0, min(Self.eqBands, Int(incoming[0])))
        for i in 0..<(5 * Self.eqBands) { target[i] = incoming[1 + i] }
        if snapEQ {
            snapEQ = false
            for i in 0..<(5 * Self.eqBands) { current[i] = target[i] }
            eqCount = eqTargetCount
            eqRamp = 0
        } else {
            eqCount = max(eqCount, eqTargetCount)
            eqRamp = Self.eqRampBlocks
        }
    }

    @inline(__always)
    private mutating func stepEQ() {
        guard eqRamp > 0, let target = eqTarget, let current = eqCurrent else { return }
        let k = 1 / Float(eqRamp)
        for i in 0..<(5 * eqCount) { current[i] += (target[i] - current[i]) * k }
        eqRamp -= 1
        if eqRamp == 0 {
            for i in 0..<(5 * Self.eqBands) { current[i] = target[i] }
            eqCount = eqTargetCount
        }
    }

    /// クロスフィードの係数 (Bauer stereophonic-to-binaural: 反対側へ回す低域と、その分を補う高域の強調)
    private mutating func updateCrossfeed() {
        let level = Double(feedLevel)
        let lowDB = level * -5 / 6 - 3
        let highDB = level / 6 - 3
        let gLow = pow(10, lowDB / 20)
        let gHigh = 1 - pow(10, highDB / 20)
        let cutHigh = Double(feedCut) * pow(2, (lowDB - 20 * log10(gHigh)) / 12)
        var x = exp(-2 * Double.pi * Double(feedCut) / Double(sr))
        feedLowB = Float(x)
        feedLowA = Float(gLow * (1 - x))
        x = exp(-2 * Double.pi * cutHigh / Double(sr))
        feedHighB = Float(x)
        feedHighA0 = Float(1 - gHigh * (1 - x))
        feedHighA1 = Float(-x)
        feedGain = Float(1 / (1 - gHigh + gLow))
    }

    /// ラウドネス補正量を目標へ一歩近づけ、フィルターの係数を計算し直す。
    /// 係数をいきなり切り替えると音が跳ぶので、数十 ms かけて動かす
    @inline(__always)
    private mutating func stepLoudness() {
        loudLow += loudCoef * (s.loudnessLow - loudLow)
        loudHigh += loudCoef * (s.loudnessHigh - loudHigh)
        if abs(s.loudnessLow - loudLow) < 0.005 { loudLow = s.loudnessLow }
        if abs(s.loudnessHigh - loudHigh) < 0.005 { loudHigh = s.loudnessHigh }
        updateLoudnessFilters()
    }

    @inline(__always)
    private mutating func updateLoudnessFilters() {
        low = Biquad(.lowShelf, cw: lowTrig.cw, sw: lowTrig.sw, gainDB: Double(loudLow), slope: 0.8)
        high = Biquad(.highShelf, cw: highTrig.cw, sw: highTrig.sw, gainDB: Double(loudHigh), slope: 0.8)
        if loudLow == 0, loudHigh == 0 { loudFlush = 4 }
    }

    /// 高音のやわらげ: 高音の大きさから下げ量を決め、動いたときだけ係数を計算し直す
    @inline(__always)
    private mutating func stepSoftening() {
        var target: Float = 0
        if s.deEssMax > 0 {
            let over = 10 * log10(hfEnv + 1e-12) - s.deEssThreshold
            if over > 0 { target = -min(s.deEssMax, over * 0.5) }
        }
        guard target != 0 || essDB != 0 else { return }
        // 下げるのはすぐ、戻すのはゆっくり
        essDB += (target < essDB ? essAtt : essRel) * (target - essDB)
        if target == 0, essDB > -0.02 { essDB = 0 }
        if essDB == 0 || abs(essDB - essApplied) > 0.01 {
            essApplied = essDB
            ess = Biquad(.highShelf, cw: essTrig.cw, sw: essTrig.sw, gainDB: Double(essDB), slope: 0.8)
        }
    }

    /// 入力のレベル (dBFS) に対する持ち上げ量 (dB, 0 以上)
    @inline(__always)
    private func targetBoost(_ level: Float) -> Float {
        guard s.dynamics, level < s.upThreshold else { return 0 }
        return min(s.maxBoost, (s.upThreshold - level) * (1 - 1 / s.upRatio))
    }

    /// 入力のレベル (dBFS) に対する抑え量 (dB, 0 以下、6dB のソフトニー)
    @inline(__always)
    private func targetCut(_ level: Float) -> Float {
        guard s.dynamics else { return 0 }
        let knee: Float = 6
        let over = level - s.downThreshold
        guard over > -knee / 2 else { return 0 }
        let x = over < knee / 2 ? (over + knee / 2) * (over + knee / 2) / (2 * knee) : over
        return -x * (1 - 1 / s.downRatio)
    }

    /// 2ch (非インターリーブ) の Float をその場で処理する
    mutating func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        guard let delay, let look, let queueValue, let queueTime, let average, let eqCurrent, let eqState, let peakFilter else { return }
        let mask = Self.delayCapacity - 1
        let lookMask = Self.lookCapacity - 1
        let ceiling = s.ceiling
        let limiterOn = s.limiter
        let swap = s.swap
        let duckTarget = s.duck
        let softening = s.deEssMax > 0
        let rumbleTarget: Float = s.lowCut > 0 ? 1 : 0
        let feedTarget: Float = s.crossfeedCut > 0 ? 1 : 0
        let window = delayLen + 1
        let windowScale = 1 / Double(window)
        let taps = Self.peakTaps
        var minLim: Float = 1

        for i in 0..<frames {
            var l = left[i], r = right[i]
            if swap { (l, r) = (r, l) }

            // パラメトリック EQ (転置直接形 II)
            if eqCount > 0 {
                for band in 0..<eqCount {
                    let c = eqCurrent + band * 5, z = eqState + band * 4
                    var y = c[0] * l + z[0]
                    z[0] = c[1] * l - c[3] * y + z[1]
                    z[1] = c[2] * l - c[4] * y + 1e-20
                    l = y
                    y = c[0] * r + z[2]
                    z[2] = c[1] * r - c[3] * y + z[3]
                    z[3] = c[2] * r - c[4] * y + 1e-20
                    r = y
                }
            }

            // クロスフィード: 反対側の低域を足し、その分だけ自分の側の高域を持ち上げて全体の大きさを保つ
            if feedMix != feedTarget || feedTarget > 0 {
                feedMix += (feedTarget - feedMix) * mixCoef
                if abs(feedTarget - feedMix) < 1e-4 { feedMix = feedTarget }
                cz.0 = feedLowA * l + feedLowB * cz.0
                cz.1 = feedLowA * r + feedLowB * cz.1
                cz.2 = feedHighA0 * l + feedHighA1 * cz.4 + feedHighB * cz.2
                cz.3 = feedHighA0 * r + feedHighA1 * cz.5 + feedHighB * cz.3
                cz.4 = l
                cz.5 = r
                l += feedMix * ((cz.2 + cz.1) * feedGain - l)
                r += feedMix * ((cz.3 + cz.0) * feedGain - r)
            }

            // 低い雑音のカット
            if rumbleMix != rumbleTarget || rumbleTarget > 0 {
                rumbleMix += (rumbleTarget - rumbleMix) * mixCoef
                if abs(rumbleTarget - rumbleMix) < 1e-4 { rumbleMix = rumbleTarget }
                var y = rumble.b0 * l + rz.0
                rz.0 = rumble.b1 * l - rumble.a1 * y + rz.1
                rz.1 = rumble.b2 * l - rumble.a2 * y + 1e-20
                l += rumbleMix * (y - l)
                y = rumble.b0 * r + rz.2
                rz.2 = rumble.b1 * r - rumble.a1 * y + rz.3
                rz.3 = rumble.b2 * r - rumble.a2 * y + 1e-20
                r += rumbleMix * (y - r)
            }

            // レベル検出 (左右をまとめた二乗平均)。音そのものは先読みの分だけ遅らせてからゲインをかけるので、
            // 大きな音が来る前に下げ始められる
            let p = 0.5 * (l * l + r * r)
            env += (p > env ? envAtt : envRel) * (p - env)
            envFast += (p > envFast ? envFastAtt : envRel) * (p - envFast)
            if counter == 0 {
                let level = 10 * log10(env + 1e-12)
                let fastLevel = 10 * log10(envFast + 1e-12)
                levelDB += (level > levelDB ? levelUp : levelDown) * (level - levelDB)
                // 録音のノイズ: 下がるときはすぐ追い、上がるときはごくゆっくり (声が続いても上がりすぎない)
                noiseDB = level < noiseDB ? level : noiseDB + noiseRise
                let gate = max(s.noiseFloor, noiseDB + 8)
                // 音が消えていく途中 (瞬間のレベルが平滑化したレベルより下) は上げない
                if levelDB >= gate, level >= levelDB - 4 || boostDB > targetBoost(levelDB) {
                    // 持ち上げ: 小さな音が続けばゆっくり上げ、大きな音が来ればすぐ下げる
                    let boost = targetBoost(levelDB)
                    boostDB += (boost > boostDB ? boostRise : boostDrop) * (boost - boostDB)
                } else {
                    // 言葉の合間や無音では据え置き (長く続けばゆっくり戻す)
                    boostDB -= silenceDecay * boostDB
                }
                // 大きな音が近づいているときは、届く前に持ち上げを外しきる
                if fastLevel > s.downThreshold - 6, boostDB > targetBoost(fastLevel) {
                    boostDB += boostFast * (targetBoost(fastLevel) - boostDB)
                }
                if !s.dynamics { boostDB -= boostDrop * boostDB }
                // 抑え: 大きな音にはすぐ、戻すのはゆっくり
                let cut = targetCut(fastLevel)
                cutDB += (cut < cutDB ? cutAtt : cutRel) * (cut - cutDB)
                let next = exp((boostDB + cutDB) * 0.11512925) // 10^(dB/20)
                gainStep = (next - gainLin) / Float(Self.block)
                // ラウドネス補正: 補正量が動いている間だけ係数を計算し直す
                if loudLow != s.loudnessLow || loudHigh != s.loudnessHigh { stepLoudness() }
                stepSoftening()
                stepEQ()
            }
            counter = counter + 1 == Self.block ? 0 : counter + 1

            // 先読みの分だけ遅らせた音に、ゲインをかける
            look[lookPos] = l
            look[Self.lookCapacity + lookPos] = r
            let lookRead = (lookPos - lookLen) & lookMask
            lookPos = (lookPos + 1) & lookMask
            gainLin += gainStep
            l = look[lookRead] * gainLin
            r = look[Self.lookCapacity + lookRead] * gainLin

            // ラウドネス補正 (低域・高域のシェルビング、転置直接形 II)。補正していない間は通さない
            var y: Float
            if loudLow != 0 || loudHigh != 0 || loudFlush > 0 {
                if loudFlush > 0 { loudFlush -= 1 }
                y = low.b0 * l + fz.0
                fz.0 = low.b1 * l - low.a1 * y + fz.1
                fz.1 = low.b2 * l - low.a2 * y
                l = y
                y = low.b0 * r + fz.2
                fz.2 = low.b1 * r - low.a1 * y + fz.3
                fz.3 = low.b2 * r - low.a2 * y
                r = y
                y = high.b0 * l + fz.4
                fz.4 = high.b1 * l - high.a1 * y + fz.5
                fz.5 = high.b2 * l - high.a2 * y
                l = y
                y = high.b0 * r + fz.6
                fz.6 = high.b1 * r - high.a1 * y + fz.7
                fz.7 = high.b2 * r - high.a2 * y
                r = y
            }

            // 高音のやわらげ: 5kHz より上の大きさを左右まとめて測り、左右に同じだけ高音を下げる
            if softening {
                var hl = side1.b0 * l + sz.0
                sz.0 = side1.b1 * l - side1.a1 * hl + sz.1
                sz.1 = side1.b2 * l - side1.a2 * hl + 1e-20
                var hr = side1.b0 * r + sz.2
                sz.2 = side1.b1 * r - side1.a1 * hr + sz.3
                sz.3 = side1.b2 * r - side1.a2 * hr + 1e-20
                y = side2.b0 * hl + sz.4
                sz.4 = side2.b1 * hl - side2.a1 * y + sz.5
                sz.5 = side2.b2 * hl - side2.a2 * y + 1e-20
                hl = y
                y = side2.b0 * hr + sz.6
                sz.6 = side2.b1 * hr - side2.a1 * y + sz.7
                sz.7 = side2.b2 * hr - side2.a2 * y + 1e-20
                hr = y
                let hp = 0.5 * (hl * hl + hr * hr)
                hfEnv += (hp > hfEnv ? hfAtt : hfRel) * (hp - hfEnv)
            }
            if essApplied != 0 || ez.0 != 0 || ez.2 != 0 {
                y = ess.b0 * l + ez.0
                ez.0 = ess.b1 * l - ess.a1 * y + ez.1
                ez.1 = ess.b2 * l - ess.a2 * y
                l = y
                y = ess.b0 * r + ez.2
                ez.2 = ess.b1 * r - ess.a1 * y + ez.3
                ez.3 = ess.b2 * r - ess.a2 * y
                r = y
            }

            delay[delayPos] = l
            delay[Self.delayCapacity + delayPos] = r

            // リミッター: 必要なゲインは、サンプルの間の山 (トゥルーピーク) も含めた大きさから決める。
            // 補間フィルターの分 (peakDelay サンプル) だけ遅れて分かるので、その分も音を遅らせてある
            var required: Float = 1
            if limiterOn {
                let center = (delayPos - Self.peakDelay) & mask
                var peak = max(abs(delay[center]), abs(delay[Self.delayCapacity + center]))
                // 山が上限に近いときだけ補間する (小さい音では計算しない)
                if peak > ceiling * 0.5 {
                    for phase in 0..<3 {
                        var sumL: Float = 0, sumR: Float = 0
                        let base = phase * taps
                        for j in 0..<taps {
                            let at = (delayPos - (taps - 1) + j) & mask
                            sumL += peakFilter[base + j] * delay[at]
                            sumR += peakFilter[base + j] * delay[Self.delayCapacity + at]
                        }
                        peak = max(peak, abs(sumL), abs(sumR))
                    }
                }
                if peak > ceiling { required = ceiling / peak }
            }
            // 今のサンプルから先読みの長さだけ前までで、最も小さい「必要なゲイン」を求める
            while queueCount > 0, queueValue[(queueHead + queueCount - 1) & mask] >= required { queueCount -= 1 }
            let back = (queueHead + queueCount) & mask
            queueValue[back] = required
            queueTime[back] = time
            queueCount += 1
            if queueTime[queueHead] <= time - window {
                queueHead = (queueHead + 1) & mask
                queueCount -= 1
            }
            time += 1
            // 山を過ぎたらゆっくり戻す。その移動平均をゲインにすると、遅らせた音が出てくる時点で
            // 必ず必要なゲイン以下になっている (上限で切り落とす必要がない)
            limHold = min(queueValue[queueHead], limHold + limRel * (1 - limHold))
            averageSum += Double(limHold) - Double(average[(delayPos - window) & mask])
            average[delayPos] = limHold
            let limGain = Float(averageSum * windowScale)
            minLim = min(minLim, limGain)

            let readPos = (delayPos - delayLen - Self.peakDelay) & mask
            delayPos = (delayPos + 1) & mask
            duck += (duckTarget - duck) * duckCoef
            let g = limGain * duck
            var ol = delay[readPos] * g
            var or = delay[Self.delayCapacity + readPos] * g
            if limiterOn {
                // 計算の丸めで上限をわずかに超える分だけを止める
                ol = min(ceiling, max(-ceiling, ol))
                or = min(ceiling, max(-ceiling, or))
            }
            let q = 0.5 * (ol * ol + or * or)
            outEnv += (q > outEnv ? envAtt : envRel) * (q - outEnv)
            left[i] = ol
            right[i] = or
        }
        env = max(env, 1e-14)
        envFast = max(envFast, 1e-14)
        outEnv = max(outEnv, 1e-14)
        hfEnv = max(hfEnv, 1e-14)
        meterLimit = minLim
    }

    func publishMeters(_ shared: ASMRShared) {
        shared.meters[0] = boostDB
        shared.meters[1] = cutDB
        shared.meters[2] = 20 * log10(max(meterLimit, 1e-6))
        shared.meters[3] = essDB
        shared.meters[4] = 10 * log10(env + 1e-12)
        shared.meters[5] = 10 * log10(outEnv + 1e-12)
    }
}

// MARK: - AudioUnit

/// 再生の最後段に置く自前のエフェクト。
/// パラメトリック EQ・クロスフィード・クリップ防止と、ASMR モードの処理
/// (入れ替え・低域カット・コンプレッサー・ラウドネス補正・高音のやわらげ・リミッター) をまとめて行う。
final class ASMRProcessorUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6B61_736D,      // 'kasm'
        componentManufacturer: 0x4B6E_6465, // 'Knde'
        componentFlags: 0,
        componentFlagsMask: 0)

    private static let registration: Void = {
        AUAudioUnit.registerSubclass(ASMRProcessorUnit.self, as: componentDescription, name: "Kanade: ASMR", version: 1)
    }()

    static func register() { _ = registration }

    let shared = ASMRShared()
    private let kernel: UnsafeMutablePointer<ASMRKernel>
    private let inBus: AUAudioUnitBus
    private let outBus: AUAudioUnitBus
    private var inputArray: AUAudioUnitBusArray!
    private var outputArray: AUAudioUnitBusArray!

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        inBus = try AUAudioUnitBus(format: format)
        outBus = try AUAudioUnitBus(format: format)
        inBus.maximumChannelCount = 2
        outBus.maximumChannelCount = 2
        kernel = .allocate(capacity: 1)
        kernel.initialize(to: ASMRKernel())
        try super.init(componentDescription: componentDescription, options: options)
        inputArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inBus])
        outputArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outBus])
        maximumFramesToRender = 4096
    }

    deinit {
        kernel.pointee.release()
        kernel.deinitialize(count: 1)
        kernel.deallocate()
    }

    override var inputBusses: AUAudioUnitBusArray { inputArray }
    override var outputBusses: AUAudioUnitBusArray { outputArray }
    override var canProcessInPlace: Bool { true }
    override var latency: TimeInterval {
        let rate = outBus.format.sampleRate
        return Double(ASMRKernel.latencyFrames(sampleRate: rate)) / rate
    }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard inBus.format.channelCount == outBus.format.channelCount else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        kernel.pointee.prepare(sampleRate: outBus.format.sampleRate, maxFrames: Int(maximumFramesToRender))
    }

    override func deallocateRenderResources() {
        kernel.pointee.release()
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        unowned(unsafe) let shared = self.shared
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pull = pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            guard frames <= kernel.pointee.maxFrames, let scratch = kernel.pointee.scratch else {
                return kAudioUnitErr_TooManyFramesToProcess
            }
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            // 出力側がバッファを用意していなければ、自前のバッファで受ける
            for i in 0..<abl.count where abl[i].mData == nil {
                abl[i].mData = UnsafeMutableRawPointer(scratch + min(i, 1) * kernel.pointee.maxFrames)
                abl[i].mDataByteSize = UInt32(frames * MemoryLayout<Float>.size)
            }
            var pullFlags = AudioUnitRenderActionFlags()
            let err = pull(&pullFlags, timestamp, frameCount, 0, outputData)
            guard err == noErr else { return err }

            kernel.pointee.sync(shared)
            // 標準の形式 (Float・非インターリーブ) の 1〜2ch だけを処理する
            guard abl.count >= 1, abl[0].mNumberChannels == 1, let l = abl[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            let r = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) ?? l : l
            kernel.pointee.process(l, r, frames: frames)
            kernel.pointee.publishMeters(shared)
            return noErr
        }
    }
}
