import Foundation

/// スリープタイマーの終わりの音量の下げ方
enum SleepFade {
    /// ここまで下げてから止める (dB)
    static let floorDB = -45.0
    /// 音量を戻すときに 1 回 (約 1/30 秒) で上げる幅。延長や解除でいきなり大きくならないよう、1.5 秒ほどかけて戻す
    static let riseStep: Float = 1.122   // 約 1dB

    /// 残り時間に対する音量の倍率。フェードに入る前は 1、そこから dB で一定の速さで下げる
    /// (耳には一様に小さくなっていくように聞こえる)
    static func target(remaining: Double, fade: Double) -> Float {
        guard fade > 0, remaining < fade else { return 1 }
        let progress = 1 - max(0, remaining) / fade
        return Float(pow(10, floorDB / 20 * progress))
    }

    /// 今の倍率から目標へ進めた値。下げるときはそのまま、上げるときは少しずつ
    static func step(from current: Float, to target: Float) -> Float {
        guard target > current else { return target }
        let floor = Float(pow(10, floorDB / 20))
        return min(target, max(current, floor) * riseStep)
    }
}

/// スリープタイマーをセットした (最後に起きていた) ときの再生位置
struct SleepPoint: Codable, Equatable {
    /// 曲を見分けるキー (Track.bookmarkKey)
    var key: String
    var title: String
    var time: Double
    var date: Date
}

/// 長い音源を途中まで聴いた位置の記録 (続きから再生するため)
struct ResumeStore: Codable, Equatable {
    struct Point: Codable, Equatable {
        var time: Double
        var date: Date
    }

    /// これより短い曲は覚えない
    static let minimumDuration = 600.0
    /// 頭と終わりのこの秒数は「途中」とみなさない
    static let margin = 30.0
    /// 続きから再生するときに、少し手前から始める秒数
    static let rewind = 3.0
    static let capacity = 300

    private(set) var points: [String: Point] = [:]

    /// 曲を離れるときに呼ぶ。途中なら位置を覚え、頭や終わりの近くなら忘れる
    mutating func leave(_ key: String, at position: Double, duration: Double?, now: Date = Date()) {
        guard let duration, duration >= Self.minimumDuration,
              position > Self.margin, position < duration - Self.margin else {
            points[key] = nil
            return
        }
        points[key] = Point(time: position, date: now)
        if points.count > Self.capacity {
            // 古いものから捨てる
            let oldest = points.sorted { $0.value.date < $1.value.date }.prefix(points.count - Self.capacity)
            for (key, _) in oldest { points[key] = nil }
        }
    }

    /// 曲を再生し始めるときに呼ぶ。覚えていた位置があれば、その少し手前を返して忘れる
    mutating func take(_ key: String, duration: Double?) -> Double? {
        guard let point = points.removeValue(forKey: key) else { return nil }
        if let duration, point.time >= duration - Self.margin { return nil }
        return max(0, point.time - Self.rewind)
    }

    mutating func forget(_ key: String) { points[key] = nil }

    // MARK: 保存 (Application Support/Kanade/resume.json)

    static func load(from dir: URL) -> ResumeStore {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("resume.json")),
              let store = try? JSONDecoder().decode(ResumeStore.self, from: data) else { return ResumeStore() }
        return store
    }

    func save(to dir: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: dir.appendingPathComponent("resume.json"), options: .atomic)
    }
}
