import Foundation

/// DLsite の作品の情報 (作品名・サークル名・声優名)
struct DLsiteWork: Codable, Equatable {
    var title: String?
    var circle: String?
    var voices: [String] = []
    /// 発売された年
    var year: String?
    /// 問い合わせた日時
    var fetched = Date()
    /// 作品が見つからなかった (しばらくは問い合わせ直さない)
    var missing = false

    /// 作品情報の問い合わせ先
    static func infoURL(code: String) -> URL? {
        URL(string: "https://www.dlsite.com/maniax/api/=/product.json?workno=\(code)")
    }

    /// 問い合わせの答え (JSON) から、作品の情報を取り出す。答えとして読めなければ nil、作品がなければ missing にする
    static func parse(_ data: Data, now: Date = Date()) -> DLsiteWork? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entry: [String: Any]?
        if let list = json as? [Any] {
            guard !list.isEmpty else { return DLsiteWork(fetched: now, missing: true) }
            entry = list.first as? [String: Any]
        } else {
            entry = json as? [String: Any]
        }
        guard let entry, entry["workno"] != nil || entry["work_name"] != nil else { return nil }
        func text(_ key: String) -> String? { (entry[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
        var work = DLsiteWork(title: text("work_name"), circle: text("maker_name"), fetched: now)
        if let creators = entry["creaters"] as? [String: Any], let voices = creators["voice_by"] as? [[String: Any]] {
            var seen = Set<String>()
            work.voices = voices.compactMap { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
                .filter { seen.insert($0).inserted }
        }
        if let date = text("regist_date"), date.count >= 4, Int(date.prefix(4)) != nil { work.year = String(date.prefix(4)) }
        return work
    }

    /// アーティスト欄に入れる名前: 声優名 (複数なら「、」でつなぐ)。声優名のない作品はサークル名
    var artist: String? {
        voices.isEmpty ? circle : voices.joined(separator: "、")
    }

    /// タグが空の欄だけを、作品の情報で埋める (タグに書いてあるものは変えない)。何か埋めたら true。
    /// アーティストは声優名、アルバムアーティストはサークル名。
    /// アルバム名は埋めない: 作品の中のフォルダ (mp3 / wav など) ごとに分かれているアルバムが、1 つにまとまってしまうため
    func fill(_ meta: inout TrackMeta) -> Bool {
        guard !missing else { return false }
        var changed = false
        if meta.artist?.nilIfBlank == nil, let artist {
            meta.artist = artist
            changed = true
        }
        // アルバムのタグがある曲は、アルバムアーティストでまとめ方が変わるので触らない
        if meta.album?.nilIfBlank == nil, meta.albumArtist?.nilIfBlank == nil, let circle {
            meta.albumArtist = circle
            changed = true
        }
        if meta.year?.nilIfBlank == nil, let year {
            meta.year = year
            changed = true
        }
        return changed
    }

    /// この曲は、作品の情報で埋められる欄が残っているか (問い合わせる意味があるか)
    static func wants(_ meta: TrackMeta) -> Bool {
        meta.artist?.nilIfBlank == nil || (meta.album?.nilIfBlank == nil && meta.albumArtist?.nilIfBlank == nil)
    }
}

/// 作品番号から DLsite の作品情報を取得して覚えておく (設定で有効にしたときだけ使う)。
/// 取得した情報は Application Support/Kanade/dlsite.json に保存し、同じ作品を何度も問い合わせない
actor DLsiteCatalog {
    static let shared = DLsiteCatalog()
    /// 見つからなかった作品を、次に問い合わせ直すまでの日数
    private static let retryDays = 30.0
    /// 設定が有効か (タグの読み込みから見る)
    nonisolated(unsafe) static var enabled = false

    /// 保存先のフォルダ (アプリの起動時に決める。決めていなければ保存しない)
    nonisolated(unsafe) static var directory: URL?
    private var works: [String: DLsiteWork]?
    private var inflight: [String: Task<DLsiteWork?, Never>] = [:]
    private var lastRequest = Date.distantPast

    private var file: URL? { Self.directory?.appendingPathComponent("dlsite.json") }

    private func loaded() -> [String: DLsiteWork] {
        if let works { return works }
        var result: [String: DLsiteWork] = [:]
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([String: DLsiteWork].self, from: data) {
            result = saved
        }
        works = result
        return result
    }

    private func store(_ work: DLsiteWork, code: String) {
        var all = loaded()
        all[code] = work
        works = all
        guard let file, let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: file, options: .atomic)
    }

    /// 覚えている件数
    func count() -> Int { loaded().values.filter { !$0.missing }.count }

    func clear() {
        works = [:]
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// 作品の情報。覚えていればそれを、なければ問い合わせる (見つからない・通信できないときは nil)
    func work(code: String) async -> DLsiteWork? {
        if let known = loaded()[code] {
            if !known.missing { return known }
            if Date().timeIntervalSince(known.fetched) < Self.retryDays * 86400 { return nil }
        }
        if let running = inflight[code] { return await running.value }
        let task = Task { await self.fetch(code: code) }
        inflight[code] = task
        let result = await task.value
        inflight[code] = nil
        return result
    }

    private func fetch(code: String) async -> DLsiteWork? {
        // 続けて問い合わせるときは、少し間をあける
        let wait = 0.3 - Date().timeIntervalSince(lastRequest)
        lastRequest = Date().addingTimeInterval(max(0, wait))
        if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
        guard let url = DLsiteWork.infoURL(code: code) else { return nil }
        let session = URLSession(configuration: .ephemeral)
        guard let (data, response) = try? await session.data(for: URLRequest(url: url, timeoutInterval: 15)),
              (response as? HTTPURLResponse)?.statusCode == 200, let work = DLsiteWork.parse(data) else { return nil }
        store(work, code: code)
        return work.missing ? nil : work
    }

    /// タグの空いている欄を、作品の情報で埋める (設定が無効、作品番号がない、埋める欄がないときは、そのまま返す)
    func filled(_ meta: TrackMeta, for url: URL) async -> TrackMeta {
        guard Self.enabled, DLsiteWork.wants(meta), let code = ArtworkFinder.workCode(for: url),
              let work = await work(code: code) else { return meta }
        var result = meta
        _ = work.fill(&result)
        return result
    }
}
