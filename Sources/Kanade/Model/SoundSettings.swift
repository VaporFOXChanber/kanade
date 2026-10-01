import Foundation

/// ヘッドホン用のクロスフィードの強さ
enum CrossfeedLevel: String, CaseIterable, Identifiable {
    case off, light, medium, strong

    var id: String { rawValue }
    var label: String { ["off": "オフ", "light": "弱", "medium": "中", "strong": "強"][rawValue]! }

    /// (反対側へ回す音の上限の周波数 Hz, 回す量 dB)。回す量が小さいほど強く混ざる
    var parameters: (cut: Float, level: Float)? {
        switch self {
        case .off: nil
        case .light: (650, 9.5)    // Jan Meier の設定に相当
        case .medium: (700, 6)     // Chu Moy の設定に相当
        case .strong: (700, 4.5)
        }
    }
}

/// 音が出力までにたどる道筋 (表示用)
struct SignalPath: Equatable {
    struct Stage: Equatable, Identifiable {
        var id: String { name }
        var name: String
        var detail: String
        var symbol: String
    }

    enum Quality: Equatable {
        /// 元のデータを 1 ビットも変えずに出力している
        case bitPerfect
        /// DSD のデータを、PCM に直さずそのまま DAC へ送っている
        case dsdNative
        /// 加工はしていないが、アプリの音量を下げている
        case volumeOnly
        /// サンプルレートの変換だけをしている
        case resampled
        /// 加工はしていないが、出力までの途中でビット数が減っている
        case reduced
        /// EQ などの加工をしている
        case processed

        /// 元のデータを変えずに出力できているか
        var isPure: Bool { self == .bitPerfect || self == .dsdNative }

        var label: String {
            switch self {
            case .bitPerfect: "ビットパーフェクト"
            case .dsdNative: "DSD ネイティブ（DoP）"
            case .volumeOnly: "無加工（音量のみ調整）"
            case .resampled: "サンプルレートを変換"
            case .reduced: "ビット深度を変換"
            case .processed: "音を加工中"
            }
        }
    }

    var source: String
    var stages: [Stage]
    var output: String
    var quality: Quality

    /// 曲のビット数を出力までそのまま運べないときの説明 (運べていれば nil)。
    /// source は曲のビット深度 (圧縮音源などは nil)、output は出力デバイスの形式が運べるビット数
    static func depthReduction(source: Int?, output: Int?) -> String? {
        guard let source, source > 1 else { return nil }
        // アプリの中では 32bit 浮動小数点で扱うので、24bit を超える分は運べない
        let carried = min(24, output ?? 24)
        guard source > carried else { return nil }
        return carried < 24 ? "\(source)bit → \(carried)bit（デバイスの形式）" : "\(source)bit → 24bit 相当（32bit 浮動小数点で処理）"
    }
}

/// DAC が DoP に対応しているかを、実際に音を聴いて確かめている途中の状態
struct DoPCheck: Equatable {
    enum Step: Equatable {
        /// 小さい音量で鳴らして、聞こえ方を尋ねている
        case quiet
        /// 小さい音量ではきれいに鳴らなかった: DAC の音量を最大にして試すかを尋ねている
        case askFull
        /// DAC の音量を最大にして鳴らし、聞こえ方を尋ねている
        case full
        case done(DoP.Support)
    }

    enum Answer {
        /// 澄んだ音が聞こえた
        case clean
        /// ザーという雑音が聞こえた (雑音まじりの音も含む)
        case noise
        /// 何も聞こえなかった
        case nothing
    }

    /// 確かめているデバイスの UID
    var device: String
    /// 確認を始める前の、デバイス側の音量 (Mac から変えられないデバイスなら nil)。終わったら戻す
    var originalVolume: Double?
    var step = Step.quiet
    var playing = false
    var message: String?
}

/// ビットパーフェクト再生の間、アプリの音量の代わりに出力デバイス側で下げている音量 (デバイスごと)。
/// デバイス側の音量はデバイスごとに別々なので、出力デバイスを切り替えるたびに下げ直し、使わなくなったほうは戻す
struct DeviceVolumeOffsets: Codable, Equatable {
    /// デバイスの UID → 下げている量 (dB)。0 は「下げる必要がなかった」
    private var lowered: [String: Double] = [:]

    var devices: [String] { lowered.keys.sorted() }

    /// このデバイスの音量は、もう合わせてあるか (もう一度下げてはいけない)
    func isLowered(_ device: String) -> Bool { lowered[device] != nil }

    mutating func record(_ device: String, db: Double) { lowered[device] = max(0, db) }

    /// 下げていた量を取り出す (戻すときに使う)
    mutating func take(_ device: String) -> Double? { lowered.removeValue(forKey: device) }

    mutating func takeAll() -> [String: Double] {
        defer { lowered = [:] }
        return lowered
    }

    /// アプリの音量 (0〜1) で下げている量 (dB、0 以上)。出力はアプリの音量の 2 乗に比例する
    static func attenuation(ofAppVolume volume: Double) -> Double {
        volume >= 0.9995 ? 0 : -40 * log10(max(volume, 0.001))
    }
}

/// 再生回数・最後に再生した日時・お気に入り (曲ごと)
struct PlayStats: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var plays = 0
        var lastPlayed: Date?
        var favorite = false
    }

    /// 1 回の再生として数える条件: 曲の半分、または 4 分を聴いた
    static func counts(listened: Double, duration: Double) -> Bool {
        listened >= 240 || (duration > 0 && listened >= duration / 2 && listened >= 5)
    }

    private(set) var entries: [String: Entry] = [:]

    subscript(key: String) -> Entry { entries[key] ?? Entry() }

    mutating func recordPlay(_ key: String, at date: Date = Date()) {
        var e = self[key]
        e.plays += 1
        e.lastPlayed = date
        entries[key] = e
    }

    mutating func setFavorite(_ key: String, _ on: Bool) {
        var e = self[key]
        e.favorite = on
        entries[key] = e.plays == 0 && !on && e.lastPlayed == nil ? nil : e
    }

    static func load(from dir: URL) -> PlayStats {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("stats.json")),
              let stats = try? JSONDecoder().decode(PlayStats.self, from: data) else { return PlayStats() }
        return stats
    }

    func save(to dir: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: dir.appendingPathComponent("stats.json"), options: .atomic)
    }
}
