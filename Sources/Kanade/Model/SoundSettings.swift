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
        /// 加工はしていないが、アプリの音量を下げている
        case volumeOnly
        /// サンプルレートの変換だけをしている
        case resampled
        /// EQ などの加工をしている
        case processed

        var label: String {
            switch self {
            case .bitPerfect: "ビットパーフェクト"
            case .volumeOnly: "無加工（音量のみ調整）"
            case .resampled: "サンプルレートを変換"
            case .processed: "音を加工中"
            }
        }
    }

    var source: String
    var stages: [Stage]
    var output: String
    var quality: Quality
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
