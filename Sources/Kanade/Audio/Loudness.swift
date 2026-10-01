import Accelerate
import AVFoundation

/// 曲全体の大きさ (統合ラウドネス) と、いちばん大きな山
struct LoudnessResult: Codable, Equatable {
    /// 統合ラウドネス (LUFS)。無音などで測れなかったときは nil
    var lufs: Double?
    /// サンプルの最大値 (1.0 = フルスケール)
    var peak: Double

    /// 音量をそろえるときの基準 (ReplayGain 2.0 と同じ -18 LUFS)
    static let reference = -18.0

    /// 基準の大きさにそろえるためのゲイン (dB)
    var gainDB: Double? { lufs.map { Self.reference - $0 } }
}

/// ITU-R BS.1770 / EBU R128 の統合ラウドネスを測る。
///
/// 人の耳の感度に合わせたフィルター (K 特性) を通し、400ms の区間ごとの大きさを 100ms ずつずらして求め、
/// 無音や小さすぎる区間を除いて (ゲート) 平均する
final class LoudnessMeter {
    private let sampleRate: Double
    private let channels: Int
    private let setups: [vDSP_biquad_Setup]
    private var delays: [[Float]]
    private var filtered: [Float] = []
    /// 100ms ごとの、K 特性を通した二乗平均 (チャンネルの合計)
    private var steps: [Double] = []
    private let stepFrames: Int
    private var stepSum = 0.0
    private var stepCount = 0
    private(set) var peak: Float = 0

    init?(sampleRate: Double, channels: Int) {
        guard sampleRate > 0, channels > 0 else { return nil }
        self.sampleRate = sampleRate
        self.channels = channels
        stepFrames = max(1, Int((sampleRate / 10).rounded()))
        let coefficients = Self.kWeighting(sampleRate)
        var created: [vDSP_biquad_Setup] = []
        for _ in 0..<channels {
            guard let setup = vDSP_biquad_CreateSetup(coefficients, 2) else { return nil }
            created.append(setup)
        }
        setups = created
        delays = Array(repeating: [Float](repeating: 0, count: 2 * 2 + 2), count: channels)
    }

    deinit { setups.forEach(vDSP_biquad_DestroySetup) }

    /// K 特性: 高域を約 4dB 持ち上げるシェルビングと、低域を落とすハイパスの 2 段。係数は [b0 b1 b2 a1 a2] × 2
    static func kWeighting(_ sampleRate: Double) -> [Double] {
        // 1 段目 (頭の形による高域の持ち上がり)
        var f0 = 1681.974450955533, q = 0.7071752369554196
        let gain = 3.999843853973347
        var k = tan(Double.pi * f0 / sampleRate)
        let vh = pow(10, gain / 20), vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0, 2 * (k * k - vh) / a0, (vh - vb * k / q + k * k) / a0,
                     2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        // 2 段目 (低域を落とす)
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / sampleRate)
        a0 = 1 + k / q + k * k
        let highPass = [1.0, -2.0, 1.0, 2 * (k * k - 1) / a0, (1 - k / q + k * k) / a0]
        return shelf + highPass
    }

    /// チャンネルごとのサンプルを足していく (チャンネル数が足りなければ、ある分だけを使う)
    func add(_ data: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) {
        guard frames > 0 else { return }
        if filtered.count < frames { filtered = [Float](repeating: 0, count: frames) }
        var offset = 0
        while offset < frames {
            let count = min(frames - offset, stepFrames - stepCount)
            for c in 0..<channels {
                var maximum: Float = 0
                vDSP_maxmgv(data[c] + offset, 1, &maximum, vDSP_Length(count))
                peak = max(peak, maximum)
                var square: Float = 0
                filtered.withUnsafeMutableBufferPointer { out in
                    vDSP_biquad(setups[c], &delays[c], data[c] + offset, 1, out.baseAddress!, 1, vDSP_Length(count))
                    vDSP_svesq(out.baseAddress!, 1, &square, vDSP_Length(count))
                }
                stepSum += Double(square)
            }
            stepCount += count
            offset += count
            if stepCount == stepFrames {
                steps.append(stepSum / Double(stepFrames))
                stepSum = 0
                stepCount = 0
            }
        }
    }

    /// これまでに足した音の統合ラウドネス (LUFS)。0.4 秒に満たないか、すべてゲートで除かれたら nil
    func integrated() -> Double? {
        guard steps.count >= 4 else { return nil }
        // 400ms の区間 (100ms ずつずらす) の大きさ
        var blocks: [Double] = []
        blocks.reserveCapacity(steps.count - 3)
        for i in 0...(steps.count - 4) { blocks.append((steps[i] + steps[i + 1] + steps[i + 2] + steps[i + 3]) / 4) }
        func loudness(_ meanSquare: Double) -> Double { -0.691 + 10 * log10(meanSquare) }
        // 絶対ゲート: -70 LUFS より小さい区間を除く
        let absolute = blocks.filter { $0 > 0 && loudness($0) > -70 }
        guard !absolute.isEmpty else { return nil }
        // 相対ゲート: 残った区間の平均より 10 LU 以上小さい区間を除く
        let threshold = loudness(absolute.reduce(0, +) / Double(absolute.count)) - 10
        let gated = absolute.filter { loudness($0) > threshold }
        guard !gated.isEmpty else { return nil }
        return loudness(gated.reduce(0, +) / Double(gated.count))
    }
}

enum LoudnessScanner {
    /// ファイル (または CUE で切り出した区間) を読んで測る。読めなければ nil
    static func measure(_ url: URL, start: Double? = nil, end: Double? = nil, isCancelled: () -> Bool = { false }) -> LoudnessResult? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let channels = min(2, Int(format.channelCount))
        guard let meter = LoudnessMeter(sampleRate: format.sampleRate, channels: channels),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1 << 16) else { return nil }
        let first = min(file.length, AVAudioFramePosition((start ?? 0) * format.sampleRate))
        let last = end.map { min(file.length, AVAudioFramePosition($0 * format.sampleRate)) } ?? file.length
        file.framePosition = first
        var remaining = last - first
        while remaining > 0 {
            if isCancelled() { return nil }
            let want = AVAudioFrameCount(min(remaining, 1 << 16))
            guard (try? file.read(into: buffer, frameCount: want)) != nil, buffer.frameLength > 0,
                  let data = buffer.floatChannelData else { break }
            meter.add(UnsafePointer(data), frames: Int(buffer.frameLength))
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return LoudnessResult(lufs: meter.integrated(), peak: Double(meter.peak))
    }

    /// 測った結果を覚えるときのキー (ファイルが書き換えられたら測り直す)
    static func key(for url: URL, start: Double?) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return "\(url.path)|\(size)|\(Int(date.timeIntervalSince1970))|\(start ?? 0)"
    }
}

/// 測ったラウドネスの保存 (Application Support/Kanade/loudness.json)
struct LoudnessStore: Codable, Equatable {
    static let capacity = 20000
    private(set) var results: [String: LoudnessResult] = [:]

    subscript(key: String) -> LoudnessResult? { results[key] }

    mutating func set(_ result: LoudnessResult, for key: String) {
        if results.count >= Self.capacity { results.removeAll() }
        results[key] = result
    }

    static func load(from dir: URL) -> LoudnessStore {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("loudness.json")),
              let store = try? JSONDecoder().decode(LoudnessStore.self, from: data) else { return LoudnessStore() }
        return store
    }

    func save(to dir: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: dir.appendingPathComponent("loudness.json"), options: .atomic)
    }
}
