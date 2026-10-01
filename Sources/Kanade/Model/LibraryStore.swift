import Foundation
import Observation

/// ライブラリ (登録したフォルダの中の曲と、単体で追加したファイル) とプレイリストの管理
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var data = LibraryData()
    private(set) var albums: [LibraryAlbum] = []
    /// フォルダを調べている、またはタグを読んでいる途中か
    private(set) var scanning = false
    /// タグを読み終えた数と、読む数
    private(set) var progress: (done: Int, total: Int)?
    @ObservationIgnored private var byKey: [String: Track] = [:]
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    private init() {
        data = LibraryData.load(from: PlayerModel.supportDirectory)
        rebuildIndex()
    }

    var tracks: [Track] { data.tracks }
    /// 登録した場所 (フォルダと、単体で追加したファイル)
    var sources: [URL] { data.sources }
    var folders: [URL] { data.sources.filter(isFolder) }
    /// 単体で追加したファイル
    var files: [URL] { data.sources.filter { !isFolder($0) } }
    var playlists: [Playlist] { data.playlists }

    private func isFolder(_ url: URL) -> Bool {
        // ドライブを外しているときなど、確かめられなければ URL の形で判断する
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? url.hasDirectoryPath
    }

    /// しおりや再生回数と同じキー (Track.bookmarkKey) から、ライブラリの曲を引く
    func track(forKey key: String) -> Track? { byKey[key] }

    func dateAdded(_ track: Track) -> Date? { data.added[track.bookmarkKey] }

    private func rebuildIndex() {
        albums = LibraryIndex.albums(from: data.tracks)
        byKey = Dictionary(data.tracks.map { ($0.bookmarkKey, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func save() {
        let snapshot = data, dir = PlayerModel.supportDirectory
        Task.detached(priority: .utility) { snapshot.save(to: dir) }
    }

    // MARK: 読み込む場所

    /// フォルダやファイルをライブラリに入れる。入れられるものが 1 つでもあったかを返す
    /// (音源でも CUE シートでもプレイリストでもないファイルは入れない)
    @discardableResult
    func addSources(_ urls: [URL]) -> Bool {
        let usable = urls.filter { Importer.isLibrarySource($0, isDirectory: isFolder($0)) }
        guard !usable.isEmpty else { return false }
        let before = data.sources
        guard data.addSources(usable) > 0 else { return true }   // すべて登録済み
        // 足した場所だけを調べる (ほかの調べものの途中なら、全体を調べ直す)
        rescan(only: scanning ? nil : data.sources.filter { !before.contains($0) })
        return true
    }

    func removeSource(_ url: URL) {
        data.removeSource(url)
        rescan()
    }

    /// 登録した場所を調べ直す。前からある曲はそのまま使い、新しい曲と書き換えられた曲のタグだけを読む。
    /// added を渡すと、その場所だけを調べて、今の曲に足す
    func rescan(only added: [URL]? = nil) {
        scanTask?.cancel()
        let sources = added ?? data.sources
        scanning = true
        progress = nil
        scanTask = Task {
            let (found, foundModified) = await Task.detached(priority: .utility) { () -> ([Track], [String: Double]) in
                let tracks = sources.isEmpty ? [] : Importer.expand(sources).tracks
                var modified: [String: Double] = [:]
                for t in tracks where modified[t.url.path] == nil {
                    let date = try? t.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                    modified[t.url.path] = date?.timeIntervalSince1970 ?? 0
                }
                return (tracks, modified)
            }.value
            guard !Task.isCancelled else { return }
            if added == nil {
                data.merge(scanned: found, modified: foundModified)
            } else {
                data.append(scanned: found, modified: foundModified)
            }
            rebuildIndex()
            await loadMetadata()
            guard !Task.isCancelled else { return }
            scanning = false
            progress = nil
            save()
        }
    }

    /// まだタグを読んでいない曲を読む (4 つずつ並行して、50 曲ごとに一覧へ反映する)
    private func loadMetadata() async {
        var pending: [URL] = []
        var seen = Set<URL>()
        for t in data.tracks where !t.meta.loaded && seen.insert(t.url).inserted { pending.append(t.url) }
        guard !pending.isEmpty else { return }
        progress = (0, pending.count)
        var done = 0
        var buffer: [URL: TrackMeta] = [:]
        var next = pending.makeIterator()
        await withTaskGroup(of: (URL, TrackMeta).self) { group in
            func addNext() {
                guard let url = next.next() else { return }
                group.addTask { (url, await DLsiteCatalog.shared.filled(await MetadataReader.read(url), for: url)) }
            }
            for _ in 0..<4 { addNext() }
            for await (url, meta) in group {
                if Task.isCancelled { break }
                buffer[url] = meta
                done += 1
                if buffer.count >= 50 {
                    apply(buffer)
                    buffer.removeAll()
                    progress = (done, pending.count)
                }
                addNext()
            }
        }
        apply(buffer)
    }

    private func apply(_ buffer: [URL: TrackMeta]) {
        guard !buffer.isEmpty else { return }
        var tracks = data.tracks
        var splits: [(Int, [Track])] = []
        for i in tracks.indices {
            guard !tracks[i].meta.loaded, let m = buffer[tracks[i].url] else { continue }
            tracks[i].meta = tracks[i].merging(m)
            if let parts = Importer.splitEmbeddedCue(tracks[i]) { splits.append((i, parts)) }
        }
        for (i, parts) in splits.reversed() {
            let date = data.added[tracks[i].bookmarkKey]
            tracks.replaceSubrange(i...i, with: parts)
            for p in parts where data.added[p.bookmarkKey] == nil { data.added[p.bookmarkKey] = date ?? Date() }
        }
        data.tracks = tracks
        rebuildIndex()
        save()
    }

    /// 読み込み済みの曲のうち、アーティストなどが空のものを、DLsite の作品情報で埋める (設定が有効なときだけ)
    func fillFromDLsite() {
        let targets = data.tracks.filter { $0.meta.loaded && DLsiteWork.wants($0.meta) && ArtworkFinder.workCode(for: $0.url) != nil }
        guard DLsiteCatalog.enabled, !targets.isEmpty else { return }
        Task {
            var updates: [UUID: TrackMeta] = [:]
            for t in targets {
                let filled = await DLsiteCatalog.shared.filled(t.meta, for: t.url)
                if filled != t.meta { updates[t.id] = filled }
            }
            guard !updates.isEmpty else { return }
            var tracks = data.tracks
            for i in tracks.indices { if let filled = updates[tracks[i].id] { tracks[i].meta = filled } }
            data.tracks = tracks
            rebuildIndex()
            save()
        }
    }

    // MARK: プレイリスト

    @discardableResult
    func createPlaylist(name: String, tracks: [Track]) -> Playlist {
        var unique = name.trimmingCharacters(in: .whitespaces)
        if unique.isEmpty { unique = "プレイリスト" }
        let base = unique
        var n = 2
        while data.playlists.contains(where: { $0.name == unique }) {
            unique = "\(base) \(n)"
            n += 1
        }
        let playlist = Playlist(name: unique, tracks: tracks)
        data.playlists.append(playlist)
        save()
        return playlist
    }

    func renamePlaylist(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[i].name = trimmed
        save()
    }

    func deletePlaylist(_ id: UUID) {
        data.playlists.removeAll { $0.id == id }
        save()
    }

    func append(_ tracks: [Track], to id: UUID) {
        guard let i = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[i].tracks += tracks.map { var t = $0; t.id = UUID(); return t }
        save()
    }

    func remove(_ trackID: UUID, from id: UUID) {
        guard let i = data.playlists.firstIndex(where: { $0.id == id }) else { return }
        data.playlists[i].tracks.removeAll { $0.id == trackID }
        save()
    }
}
