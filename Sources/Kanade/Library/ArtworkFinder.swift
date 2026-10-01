import Foundation
import ImageIO

/// 音源に画像が埋め込まれていないときに、作品のフォルダの中からアートワークを探す。
///
/// 同人音声の作品は、音源が「mp3」「本編」のようなフォルダに入っていて、画像は作品のフォルダの直下や
/// 「画像」「イラスト」のような別のフォルダにあることが多い。そこで、音源のフォルダから作品のフォルダまで
/// さかのぼり、その中の画像から、名前・場所・形の良いものを選ぶ。
enum ArtworkFinder {
    // MARK: 作品番号

    private static let codePattern = try! NSRegularExpression(pattern: #"(?<![A-Za-z])(RJ|VJ|BJ)(\d{8}|\d{6})(?!\d)"#, options: .caseInsensitive)

    /// 名前に含まれる DLsite の作品番号 (RJ01234567 など)
    static func workCode(inName name: String) -> String? {
        let ns = name as NSString
        guard let m = codePattern.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range).uppercased()
    }

    /// 音源のファイル名か、その上 4 階層までのフォルダ名に含まれる作品番号 (近いものを優先)
    static func workCode(for audio: URL) -> String? {
        var url = audio
        for _ in 0..<5 {
            if let code = workCode(inName: url.lastPathComponent) { return code }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
        }
        return nil
    }

    // MARK: 作品のフォルダ

    /// 作品の中の一部を表す、ありふれたフォルダ名に使われる語 (長いものから順に取り除く)
    private static let partWords: [String] = [
        "バイノーラル", "キービジュアル", "ハイレゾ", "ノーマル", "トラック", "ファイル", "lossless", "binaural", "without",
        "version", "stereo", "非圧縮", "無圧縮", "高音質", "効果音", "通常版", "おまけ", "ボイス", "データ", "ループ", "hi-res", "sounds", "tracks",
        "hires", "audio", "sound", "voice", "track", "bonus", "extra", "本編", "特典", "音声", "音源", "圧縮", "可逆", "通常", "差分", "あり", "なし",
        "有り", "無し", "wave", "flac", "opus", "alac", "aiff", "main", "disc", "disk", "with", "mp3", "wav", "ogg", "m4a", "aac", "bgm",
        "khz", "bit", "ver", "版", "有", "無", "se", "cd", "hz", "no", "dl", "k",
    ].sorted { $0.count > $1.count }

    /// 「mp3」「本編」「WAV（SEなし）」「Disc 2」のように、作品そのものではなく作品の一部を表すフォルダ名か
    static func isPartFolder(_ name: String) -> Bool {
        var rest = name.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var matched = false
        for word in partWords where rest.contains(word) {
            rest = rest.replacingOccurrences(of: word, with: " ")
            matched = true
        }
        guard matched else { return false }
        return !rest.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// さかのぼってはいけない場所 (ホームや「ミュージック」などは、作品のフォルダではない)
    private static func isLibraryRoot(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if url.pathComponents.count <= 2 { return true }                       // "/" や "/Users"
        if path.hasPrefix("/Volumes/"), url.pathComponents.count <= 3 { return true }   // ボリュームの直下
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return path == home || ["Music", "Downloads", "Desktop", "Documents", "Movies"].contains { path == home + "/" + $0 }
    }

    /// 音源が属する作品のフォルダ。
    /// 名前に作品番号のあるフォルダが上にあればそこまで、なければ「mp3」「本編」のようなフォルダだけをさかのぼる
    static func workFolder(for audio: URL) -> URL {
        let start = audio.deletingLastPathComponent()
        var chain = [start]
        while chain.count < 5, let last = chain.last {
            let parent = last.deletingLastPathComponent()
            if parent.path == last.path || isLibraryRoot(parent) { break }
            chain.append(parent)
        }
        if let rooted = chain.first(where: { workCode(inName: $0.lastPathComponent) != nil }) { return rooted }
        var folder = start
        for parent in chain.dropFirst().prefix(3) {
            guard isPartFolder(folder.lastPathComponent) else { break }
            folder = parent
        }
        return folder
    }

    /// 手動で指定したアートワークを覚えるときの、作品を表すキー。
    /// 作品のフォルダが決まるときはそのフォルダ、ばらの曲が同じフォルダに並んでいるときはアルバム名でも分ける
    static func workKey(for track: Track) -> String {
        let folder = workFolder(for: track.url)
        let grouped = folder.path != track.url.deletingLastPathComponent().path || workCode(inName: folder.lastPathComponent) != nil
        if !grouped, let album = track.meta.album?.nilIfBlank { return folder.path + "|" + album }
        return folder.path
    }

    // MARK: 画像を探す

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: URL?] = [:]

    static func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    /// 作品のフォルダの中から、アートワークにふさわしい画像を探す (結果は音源のフォルダごとに覚える)
    static func find(for audio: URL) -> URL? {
        let key = audio.deletingLastPathComponent().path
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }
        let found = search(for: audio)
        lock.lock()
        cache[key] = .some(found)
        lock.unlock()
        return found
    }

    private struct Candidate {
        let url: URL
        var score: Int
    }

    private static func search(for audio: URL) -> URL? {
        let fm = FileManager.default
        let audioDir = audio.deletingLastPathComponent()
        let root = workFolder(for: audio)
        // 音源のフォルダから作品のフォルダまでの道筋
        var chain: [String: Int] = [:]
        var step = audioDir
        var distance = 0
        while true {
            chain[step.path] = distance
            if step.path == root.path || distance > 5 { break }
            step = step.deletingLastPathComponent()
            distance += 1
        }

        var candidates: [Candidate] = []
        var queue: [(url: URL, depth: Int)] = [(root, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 60, candidates.count < 400 {
            let (dir, depth) = queue.removeFirst()
            visited += 1
            guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            let onChain = chain[dir.path]
            let hasAudio = items.contains { Importer.mediaExtensions.contains($0.pathExtension.lowercased()) }
            // 道筋から外れた、音源の入ったフォルダは別のパート (や別の作品) なので、その中の画像は使わない
            if onChain == nil, hasAudio { continue }
            for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                // 一覧は実際のパス表記で返るので、フォルダは元の表記に合わせる
                let url = dir.appendingPathComponent(item.lastPathComponent)
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    if depth < 3 { queue.append((url, depth + 1)) }
                } else if Importer.imageExtensions.contains(item.pathExtension.lowercased()) {
                    var score = nameScore(url.deletingPathExtension().lastPathComponent)
                    if let onChain {
                        score += onChain == 0 ? 40 : max(10, 30 - 5 * onChain)
                    } else {
                        score += folderScore(dir.lastPathComponent) + max(0, 15 - 5 * depth)
                    }
                    candidates.append(Candidate(url: url, score: score))
                }
            }
        }
        guard !candidates.isEmpty else { return nil }

        // 名前と場所で上位に絞ってから、大きさと形を見る (画像のヘッダーだけを読む)
        var top = Array(candidates.enumerated().sorted { ($0.element.score, -$0.offset) > ($1.element.score, -$1.offset) }.prefix(12).map(\.element))
        for i in top.indices { top[i].score += shapeScore(top[i].url) }
        return top.enumerated().max { ($0.element.score, -$0.offset) < ($1.element.score, -$1.offset) }?.element.url
    }

    /// ファイル名から見た、アートワークらしさ
    static func nameScore(_ stem: String) -> Int {
        let name = stem.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        var score = 0
        if ["cover", "folder", "front", "jacket", "artwork", "albumart"].contains(where: name.hasPrefix) {
            score += 100
        } else if ["_img_main", "ジャケット", "ジャケ", "jacket", "表紙", "カバー", "cover", "パッケージ", "package", "メイン", "main",
                   "サムネ", "thumb", "キービジュアル", "タイトル", "title"].contains(where: name.contains) {
            score += 80
        }
        if workCode(inName: stem) != nil { score += 20 }
        if ["文字なし", "文字無", "ロゴなし", "ロゴ無", "差分", "ラフ", "線画", "sample", "サンプル", "おまけ", "back", "裏", "盤面", "label",
            "obi", "帯", "booklet", "ブックレット", "inlay", "tray", "台本", "script"].contains(where: name.contains) {
            score -= 30
        }
        return score
    }

    /// 画像の入っているフォルダの名前から見た、アートワークらしさ
    private static func folderScore(_ folder: String) -> Int {
        let name = folder.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        if ["ジャケ", "jacket", "cover", "表紙", "パッケージ", "artwork"].contains(where: name.contains) { return 30 }
        if ["画像", "イラスト", "image", "img", "illust", "picture", "cg"].contains(where: name.contains) { return 10 }
        return 0
    }

    /// 大きさと縦横比: 小さすぎる画像や、極端に細長い画像 (バナーなど) は避ける
    private static func shapeScore(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 else { return -100 }
        var score = 0
        if min(width, height) < 200 { score -= 60 }
        let ratio = width / height
        if (0.65...1.6).contains(ratio) { score += 15 } else if (0.4...2.5).contains(ratio) { score -= 15 } else { score -= 100 }
        return score
    }
}

// MARK: - DLsite からの取得

/// 作品番号から、DLsite の作品画像を取得して保存する (設定で有効にしたときだけ使う)
actor DLsiteArtwork {
    static let shared = DLsiteArtwork()
    /// 画像がなかった作品を、次に問い合わせ直すまでの日数
    private static let retryDays = 30.0
    private var inflight: [String: Task<URL?, Never>] = [:]

    /// 取得した画像の保存先 (Application Support/Kanade/Artwork)
    static func directory(in support: URL) -> URL {
        let dir = support.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 作品情報の問い合わせ先
    static func infoURL(code: String) -> URL? {
        URL(string: "https://www.dlsite.com/maniax/product/info/ajax?product_id=\(code)&cdn_cache_min=1")
    }

    /// 作品情報 (JSON) から画像の URL を取り出す。画像のない作品は nil
    static func imageURL(fromInfo data: Data, code: String) -> URL? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = json[code] as? [String: Any], var image = info["work_image"] as? String else { return nil }
        if image.hasPrefix("//") { image = "https:" + image }
        guard let url = URL(string: image), url.scheme == "https", url.host?.hasSuffix("dlsite.jp") == true,
              !url.lastPathComponent.hasPrefix("no_img") else { return nil }
        return url
    }

    /// 作品情報が取れなかったときに使う、番号から組み立てた画像の URL。
    /// フォルダは番号を 1000 単位に切り上げたもの (RJ299717 → RJ300000)
    static func fallbackImageURL(code: String) -> URL? {
        let prefix = String(code.prefix(2)), digits = String(code.dropFirst(2))
        guard let number = Int(digits), let site = ["RJ": "doujin", "VJ": "professional", "BJ": "books"][prefix] else { return nil }
        let folder = prefix + String(format: "%0\(digits.count)d", (number + 999) / 1000 * 1000)
        return URL(string: "https://img.dlsite.jp/modpub/images2/work/\(site)/\(folder)/\(code)_img_main.jpg")
    }

    /// 保存済みの画像 (あれば)
    static func savedImage(code: String, in dir: URL) -> URL? {
        ["jpg", "png", "webp", "gif"].lazy.map { dir.appendingPathComponent("\(code).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 作品の画像を返す。保存済みならそれを、なければ取得して保存する
    func image(code: String, in dir: URL) async -> URL? {
        if let saved = Self.savedImage(code: code, in: dir) { return saved }
        // 画像がないと分かっている作品は、しばらく問い合わせない
        let marker = dir.appendingPathComponent("\(code).none")
        if let date = (try? marker.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(date) < Self.retryDays * 86400 { return nil }
        if let running = inflight[code] { return await running.value }
        let task = Task { await Self.download(code: code, into: dir, marker: marker) }
        inflight[code] = task
        let result = await task.value
        inflight[code] = nil
        return result
    }

    private static func download(code: String, into dir: URL, marker: URL) async -> URL? {
        let session = URLSession(configuration: .ephemeral)
        func get(_ url: URL) async -> Data? {
            let request = URLRequest(url: url, timeoutInterval: 15)
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return data
        }
        var known = false   // 問い合わせには答えが返ってきた (通信の失敗ではない)
        var imageURL: URL?
        if let info = infoURL(code: code), let data = await get(info) {
            known = true
            imageURL = Self.imageURL(fromInfo: data, code: code)
        } else {
            imageURL = fallbackImageURL(code: code)
        }
        if let imageURL, let data = await get(imageURL), data.count < 30_000_000,
           let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 {
            let ext = ["jpg", "png", "webp", "gif"].first { $0 == imageURL.pathExtension.lowercased() } ?? "jpg"
            let file = dir.appendingPathComponent("\(code).\(ext)")
            if (try? data.write(to: file, options: .atomic)) != nil { return file }
        }
        if known, imageURL == nil { try? Data().write(to: marker) }
        return nil
    }
}
