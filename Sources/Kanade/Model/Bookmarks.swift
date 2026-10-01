import Foundation

/// 曲の中の位置につけるしおり
struct Bookmark: Codable, Identifiable, Hashable {
    var id = UUID()
    var time: Double
    var name: String
}

extension Track {
    /// しおりを曲ごとに覚えておくためのキー (CUE で分けた曲は開始位置で区別する)
    var bookmarkKey: String { "\(url.path)|\(start ?? 0)" }
}

/// しおりの保存先 (Application Support/Kanade/bookmarks.json)
enum BookmarkStore {
    static func load(from dir: URL) -> [String: [Bookmark]] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("bookmarks.json")),
              let all = try? JSONDecoder().decode([String: [Bookmark]].self, from: data) else { return [:] }
        return all
    }

    static func save(_ all: [String: [Bookmark]], to dir: URL) {
        let kept = all.filter { !$0.value.isEmpty }
        guard let data = try? JSONEncoder().encode(kept) else { return }
        try? data.write(to: dir.appendingPathComponent("bookmarks.json"), options: .atomic)
    }
}
