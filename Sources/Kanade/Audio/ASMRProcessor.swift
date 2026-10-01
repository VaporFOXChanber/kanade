import AudioToolbox
import AVFoundation
import Synchronization

// MARK: - 設定

/// ASMR モードの「音量のならし」の強さ
enum ASMRStrength: String, CaseIterable, Identifiable {
    case gentle, standard, firm

    var id: String { rawValue }
    var label: String { ["gentle": "穏やか", "standard": "標準", "firm": "しっかり"][rawValue]! }

    /// 圧縮カーブ。小さい音は upThreshold から下を最大 maxBoost まで持ち上げ、
    /// 大きい音は downThreshold から上を downRatio で抑える。
    func apply(to s: inout ASMRSettings) {
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
        }
    }
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
    /// 急な大音量を ceiling で止める (3ms 先読み)
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

    /// リミッターの上限 (-3 dBFS)
    var ceiling: Float = 0.708
    /// 音を一時的に絞る (1 = そのまま、0 = 無音)。ループのつなぎ目・一時停止・シークで使う
    var duck: Float = 1
    /// duck の値へ近づく時定数 (秒)
    var duckTime: Float = 0.006
    /// 値が変わったら、いったん無音にしてから duck へ向けて上げ直す (曲の途中から鳴らし始めるときのフェードイン)
    var duckRestart: UInt32 = 0
}

/// メインスレッドと音声スレッドの受け渡し。
///
/// 設定はシーケンスロックで渡す。書く側は番号を奇数にしてから書き、書き終えたら偶数に進める。
/// 読む側はコピーの前後で番号を読み、奇数だったり前後で違っていたりしたら (= 書き込みと重なった) 読み直す。
/// 読む側 (音声スレッド) はロックを取らず、待たされることがない。
///
/// 設定の中身も 1 語 (8 バイト) ずつアトミックに読み書きする。番号だけをアトミックにして中身を普通にコピーすると、
/// ARM では中身の読み書きが番号の読み書きと前後して実行されることがあり、番号が一致しているのに
/// 書きかけの値を読んでしまう (テストで実際に起きた)。すべてをアトミックにすれば全体に順序が付く。
final class ASMRShared: @unchecked Sendable {
    /// 読み直しの上限。書き込みと重なり続けたら諦め、次の描画でやり直す (音声スレッドを回し続けない)
    private static let readAttempts = 4
    private static let byteCount = MemoryLayout<ASMRSettings>.size
    private static let wordCount = (byteCount + 7) / 8

    private let sequence = Atomic<Int>(0)
    private let words = UnsafeMutablePointer<Atomic<UInt64>>.allocate(capacity: wordCount)
    /// 書く側どうしの順番待ち (読む側は取らない)
    private let writeLock = NSLock()
    /// 表示用: [持ち上げ量 dB, 抑え量 dB (負), リミッター dB (負), 高音のやわらげ dB (負)]
    let meters = UnsafeMutablePointer<Float>.allocate(capacity: 4)

    init() {
        for i in 0..<Self.wordCount { (words + i).initialize(to: Atomic(0)) }
        meters.initialize(repeating: 0, count: 4)
        store(ASMRSettings())
    }

    deinit {
        words.deinitialize(count: Self.wordCount)
        words.deallocate()
        meters.deallocate()
    }

    func publish(_ s: ASMRSettings) {
        writeLock.lock()
        defer { writeLock.unlock() }
        let v = sequence.load(ordering: .sequentiallyConsistent)
        sequence.store(v &+ 1, ordering: .sequentiallyConsistent)   // 奇数: 書き込み中
        store(s)
        sequence.store(v &+ 2, ordering: .sequentiallyConsistent)   // 偶数: 書き終えた
    }

    /// 音声スレッド用: 新しい設定があれば、その番号と一緒に返す
    @inline(__always)
    func read(ifNewerThan version: Int) -> (Int, ASMRSettings)? {
        for _ in 0..<Self.readAttempts {
            let before = sequence.load(ordering: .sequentiallyConsistent)
            if before == version { return nil }
            guard before & 1 == 0 else { continue }
            let copy = load()
            if sequence.load(ordering: .sequentiallyConsistent) == before { return (before, copy) }
        }
        return nil
    }

    private func store(_ s: ASMRSettings) {
        withUnsafeBytes(of: s) { source in
            for i in 0..<Self.wordCount {
                var word: UInt64 = 0
                let offset = i * 8
                withUnsafeMutableBytes(of: &word) {
                    $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[offset..<min(offset + 8, Self.byteCount)]))
                }
                words[i].store(word, ordering: .sequentiallyConsistent)
            }
        }
    }

    @inline(__always)
    private func load() -> ASMRSettings {
        var result = ASMRSettings()
        withUnsafeMutableBytes(of: &result) { destination in
            for i in 0..<Self.wordCount {
                let word = words[i].load(ordering: .sequentiallyConsistent)
                let offset = i * 8
                withUnsafeBytes(of: word) {
                    destination.baseAddress!.advanced(by: offset)
                        .copyMemory(from: $0.baseAddress!, byteCount: min(8, Self.byteCount - offset))
                }
            }
        }
        return result
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

/// 音声スレッドだけが触る処理本体。メモリ確保・ロック・参照カウントを伴う操作をしない
struct ASMRKernel {
    private static let block = 16          // ゲインを計算し直す間隔 (サンプル)
    private static let loudnessTime: Float = 0.04 // ラウドネス補正量が目標に近づく時定数 (秒)
    private static let delayCapacity = 2048 // 先読み用の遅延バッファ (2 の累乗)

    private var sr: Float = 48000
    private var s = ASMRSettings()
    private var version = -1

    // 係数
    private var envAtt: Float = 0, envRel: Float = 0
    private var levelUp: Float = 0, levelDown: Float = 0
    private var cutAtt: Float = 0, cutRel: Float = 0
    private var boostRise: Float = 0, boostDrop: Float = 0, silenceDecay: Float = 0
    private var noiseRise: Float = 0
    private var limRel: Float = 0
    private var duckCoef: Float = 0
    private var loudCoef: Float = 0
    private var lowTrig = (cw: 1.0, sw: 0.0), highTrig = (cw: 1.0, sw: 0.0), essTrig = (cw: 1.0, sw: 0.0)
    private var low = Biquad(), high = Biquad()
    private var hfAtt: Float = 0, hfRel: Float = 0
    private var essAtt: Float = 0, essRel: Float = 0
    /// 高音の大きさを測るためのハイパス (2 段で 4 次。声の中域に反応しないよう急にする) と、高音を下げるシェルビング
    private var side1 = Biquad(), side2 = Biquad(), ess = Biquad()

    // 状態
    private var env: Float = 0
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
    private var duck: Float = 1
    private var lastRestart: UInt32 = 0
    /// 今かかっているラウドネス補正量 (dB)。設定値へ少しずつ近づける
    private var loudLow: Float = 0
    private var loudHigh: Float = 0
    /// 再生を始めた直後は、近づけずにその場で設定値に合わせる
    private var snapLoudness = true

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

    private(set) var scratch: UnsafeMutablePointer<Float>?
    private(set) var maxFrames = 0

    // 表示用 (ブロックごとの値)
    private var meterLimit: Float = 1

    mutating func prepare(sampleRate: Double, maxFrames: Int) {
        release()
        sr = Float(sampleRate)
        self.maxFrames = maxFrames
        scratch = .allocate(capacity: 2 * maxFrames)
        scratch?.initialize(repeating: 0, count: 2 * maxFrames)
        delay = .allocate(capacity: 2 * Self.delayCapacity)
        delay?.initialize(repeating: 0, count: 2 * Self.delayCapacity)
        queueValue = .allocate(capacity: Self.delayCapacity)
        queueValue?.initialize(repeating: 1, count: Self.delayCapacity)
        queueTime = .allocate(capacity: Self.delayCapacity)
        queueTime?.initialize(repeating: 0, count: Self.delayCapacity)
        average = .allocate(capacity: Self.delayCapacity)
        average?.initialize(repeating: 1, count: Self.delayCapacity)
        delayLen = max(1, min(Self.delayCapacity - 2, Int(0.003 * sampleRate)))
        delayPos = 0
        queueHead = 0; queueCount = 0; time = 0
        limHold = 1
        averageSum = Double(delayLen + 1)
        env = 0; levelDB = -100; noiseDB = -100; boostDB = 0; cutDB = 0; gainLin = 1; gainStep = 0; counter = 0
        fz = (0, 0, 0, 0, 0, 0, 0, 0)
        sz = (0, 0, 0, 0, 0, 0, 0, 0); ez = (0, 0, 0, 0)
        hfEnv = 0; essDB = 0; essApplied = 0; ess = Biquad()
        envAtt = 1 - exp(-1 / (0.005 * sr))
        envRel = 1 - exp(-1 / (0.04 * sr))
        limRel = 1 - exp(-1 / (0.12 * sr))
        hfAtt = 1 - exp(-1 / (0.001 * sr))
        hfRel = 1 - exp(-1 / (0.015 * sr))
        loudCoef = 1 - exp(-Float(Self.block) / (Self.loudnessTime * sr))
        func trig(_ frequency: Double) -> (cw: Double, sw: Double) {
            let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
            return (cos(w0), sin(w0))
        }
        lowTrig = trig(110)
        highTrig = trig(9000)
        essTrig = trig(5500)
        let sideTrig = trig(5000)
        side1 = .highPass(cw: sideTrig.cw, sw: sideTrig.sw, q: 0.5412)
        side2 = .highPass(cw: sideTrig.cw, sw: sideTrig.sw, q: 1.3066)
        snapLoudness = true
        version = -1
    }

    mutating func release() {
        scratch?.deallocate(); scratch = nil
        delay?.deallocate(); delay = nil
        queueValue?.deallocate(); queueValue = nil
        queueTime?.deallocate(); queueTime = nil
        average?.deallocate(); average = nil
        maxFrames = 0
    }

    /// 新しい設定を取り込み、係数を計算し直す
    @inline(__always)
    mutating func sync(_ shared: ASMRShared) {
        guard let (v, settings) = shared.read(ifNewerThan: version) else { return }
        version = v
        s = settings
        let b = Float(Self.block)
        func coef(_ t: Float) -> Float { 1 - exp(-b / (max(0.001, t) * sr)) }
        cutAtt = coef(s.attack)
        cutRel = coef(s.release)
        levelUp = coef(0.03)
        levelDown = coef(0.25)
        boostRise = coef(s.boostRise)
        boostDrop = coef(0.05)
        silenceDecay = coef(4)
        essAtt = coef(0.002)
        essRel = coef(0.08)
        noiseRise = 0.5 * b / sr   // ノイズの推定値は 1 秒に 0.5dB ずつしか上げない
        duckCoef = 1 - exp(-1 / (max(0.001, s.duckTime) * sr))
        if s.duckRestart != lastRestart {
            lastRestart = s.duckRestart
            duck = 0
        }
        if snapLoudness {
            snapLoudness = false
            loudLow = s.loudnessLow
            loudHigh = s.loudnessHigh
            updateLoudnessFilters()
        }
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
        guard let delay, let queueValue, let queueTime, let average else { return }
        let mask = Self.delayCapacity - 1
        let ceiling = s.ceiling
        let limiterOn = s.limiter
        let swap = s.swap
        let duckTarget = s.duck
        let softening = s.deEssMax > 0
        let window = delayLen + 1
        let windowScale = 1 / Double(window)
        var minLim: Float = 1

        for i in 0..<frames {
            var l = left[i], r = right[i]
            if swap { (l, r) = (r, l) }

            // レベル検出 (左右をまとめた二乗平均)
            let p = 0.5 * (l * l + r * r)
            env += (p > env ? envAtt : envRel) * (p - env)
            if counter == 0 {
                let level = 10 * log10(env + 1e-12)
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
                if !s.dynamics { boostDB -= boostDrop * boostDB }
                // 抑え: 大きな音にはすぐ、戻すのはゆっくり
                let cut = targetCut(level)
                cutDB += (cut < cutDB ? cutAtt : cutRel) * (cut - cutDB)
                let next = exp((boostDB + cutDB) * 0.11512925) // 10^(dB/20)
                gainStep = (next - gainLin) / Float(Self.block)
                // ラウドネス補正: 補正量が動いている間だけ係数を計算し直す
                if loudLow != s.loudnessLow || loudHigh != s.loudnessHigh { stepLoudness() }
                stepSoftening()
            }
            counter = counter + 1 == Self.block ? 0 : counter + 1
            gainLin += gainStep
            l *= gainLin
            r *= gainLin

            // ラウドネス補正 (低域・高域のシェルビング、転置直接形 II)
            var y = low.b0 * l + fz.0
            fz.0 = low.b1 * l - low.a1 * y + fz.1
            fz.1 = low.b2 * l - low.a2 * y + 1e-20
            l = y
            y = low.b0 * r + fz.2
            fz.2 = low.b1 * r - low.a1 * y + fz.3
            fz.3 = low.b2 * r - low.a2 * y + 1e-20
            r = y
            y = high.b0 * l + fz.4
            fz.4 = high.b1 * l - high.a1 * y + fz.5
            fz.5 = high.b2 * l - high.a2 * y + 1e-20
            l = y
            y = high.b0 * r + fz.6
            fz.6 = high.b1 * r - high.a1 * y + fz.7
            fz.7 = high.b2 * r - high.a2 * y + 1e-20
            r = y

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

            // リミッター: 今のサンプルから先読みの長さだけ前までで、最も小さい「必要なゲイン」を求める
            var required: Float = 1
            let peak = max(abs(l), abs(r))
            if limiterOn, peak > ceiling { required = ceiling / peak }
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

            delay[delayPos] = l
            delay[Self.delayCapacity + delayPos] = r
            let readPos = (delayPos - delayLen) & mask
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
            left[i] = ol
            right[i] = or
        }
        env = max(env, 1e-14)
        hfEnv = max(hfEnv, 1e-14)
        meterLimit = minLim
    }

    func publishMeters(_ shared: ASMRShared) {
        shared.meters[0] = boostDB
        shared.meters[1] = cutDB
        shared.meters[2] = 20 * log10(max(meterLimit, 1e-6))
        shared.meters[3] = essDB
    }
}

// MARK: - AudioUnit

/// ASMR モードの処理をまとめた自前のエフェクト。
/// 入れ替え → コンプレッサー (持ち上げ・抑え) → ラウドネス補正 → 高音のやわらげ → リミッター の順に通す。
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
    override var latency: TimeInterval { 0.003 }

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
