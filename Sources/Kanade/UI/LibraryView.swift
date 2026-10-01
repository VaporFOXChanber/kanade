import SwiftUI

/// ライブラリのウィンドウ: 登録したフォルダの曲を、アルバム・アーティスト・曲の一覧やプレイリストで見る
struct LibraryView: View {
    @Environment(PlayerModel.self) private var model
    @State private var library = LibraryStore.shared
    @State private var section: LibrarySection = .albums
    @State private var query = ""
    @State private var openAlbum: String?
    @State private var openArtist: String?
    @State private var renaming: UUID?
    @State private var newName = ""

    init(initial: LibrarySection = .albums, openAlbum: String? = nil) {
        _section = State(initialValue: initial)
        _openAlbum = State(initialValue: openAlbum)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .background(.black.opacity(0.22))
            VStack(spacing: 0) {
                header
                content
            }
        }
        .background(Backdrop(palette: model.palette))
        .preferredColorScheme(.dark)
        .tint(model.palette.accent)
        .foregroundStyle(.white)
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            library.addFolders(folders)
            return true
        }
    }

    // MARK: サイドバー

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("ライブラリ").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
            ForEach(LibrarySection.fixed) { item in sidebarRow(item) }

            HStack {
                Text("プレイリスト").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45))
                Spacer()
                Button {
                    let p = library.createPlaylist(name: "新しいプレイリスト", tracks: [])
                    section = .playlist(p.id)
                    newName = p.name
                    renaming = p.id
                } label: { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
                    .help("空のプレイリストを作る").accessibilityLabel("プレイリストを作る")
            }
            .padding(.horizontal, 12).padding(.top, 14).padding(.bottom, 4)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(library.playlists) { p in sidebarRow(.playlist(p.id), title: p.name) }
                    if library.playlists.isEmpty {
                        Text("再生キューの「…」から、今のキューをプレイリストとして保存できます。")
                            .font(.caption).foregroundStyle(.white.opacity(0.4)).padding(.horizontal, 12).padding(.top, 2)
                    }
                }
            }

            Spacer(minLength: 8)
            if library.scanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(library.progress.map { "タグを読み込み中 \($0.done) / \($0.total)" } ?? "フォルダを調べています…")
                        .font(.caption).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                }
                .padding(.horizontal, 12)
            }
            HStack(spacing: 6) {
                Button { chooseFolders() } label: { Label("フォルダを追加…", systemImage: "folder.badge.plus") }
                    .controlSize(.small)
                Menu {
                    Button("調べ直す") { library.rescan() }.disabled(library.folders.isEmpty)
                    if !library.folders.isEmpty {
                        Divider()
                        ForEach(library.folders, id: \.self) { folder in
                            Button("「\(folder.lastPathComponent)」を外す") { library.removeFolder(folder) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("ライブラリのフォルダ")
            }
            .padding(12)
        }
    }

    private func sidebarRow(_ item: LibrarySection, title: String? = nil) -> some View {
        let selected = section == item
        return Button {
            section = item
            openAlbum = nil
            openArtist = nil
        } label: {
            HStack(spacing: 8) {
                Image(systemName: item.symbol).frame(width: 18).foregroundStyle(selected ? model.palette.accent : .white.opacity(0.6))
                Text(title ?? item.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(selected ? 0.12 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .contextMenu {
            if case .playlist(let id) = item {
                Button("名前を変える") { section = item; newName = title ?? ""; renaming = id }
                Button("削除", role: .destructive) {
                    library.deletePlaylist(id)
                    if section == item { section = .albums }
                }
            }
        }
    }

    // MARK: 見出し

    private var header: some View {
        HStack(spacing: 10) {
            if openAlbum != nil || openArtist != nil {
                Button {
                    if openAlbum != nil { openAlbum = nil } else { openArtist = nil }
                } label: { Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)) }
                    .buttonStyle(.plain).help("戻る").accessibilityLabel("戻る")
            }
            if case .playlist(let id) = section, renaming == id {
                TextField("名前", text: $newName)
                    .textFieldStyle(.roundedBorder).frame(width: 240)
                    .onSubmit {
                        library.renamePlaylist(id, to: newName)
                        renaming = nil
                    }
            } else {
                Text(headerTitle).font(.system(size: 19, weight: .bold)).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("検索", text: $query).textFieldStyle(.plain).frame(width: 180)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5)).accessibilityLabel("検索を消す")
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }

    private var headerTitle: String {
        if let id = openAlbum, let album = library.albums.first(where: { $0.id == id }) { return album.title }
        if let artist = openArtist { return artist }
        if case .playlist(let id) = section { return library.playlists.first { $0.id == id }?.name ?? "プレイリスト" }
        return section.title
    }

    // MARK: 中身

    @ViewBuilder
    private var content: some View {
        if library.folders.isEmpty, !section.isPlaylist {
            emptyState
        } else if let id = openAlbum, let album = library.albums.first(where: { $0.id == id }) {
            AlbumDetail(album: album)
        } else {
            switch section {
            case .albums:
                AlbumGrid(albums: LibraryIndex.search(openArtist.map { a in library.albums.filter { $0.artist == a } } ?? library.albums, query)) { openAlbum = $0 }
            case .artists:
                if let artist = openArtist {
                    AlbumGrid(albums: LibraryIndex.search(library.albums.filter { $0.artist == artist }, query)) { openAlbum = $0 }
                } else {
                    ArtistList(artists: LibraryIndex.artists(from: LibraryIndex.search(library.albums, query))) { openArtist = $0 }
                }
            case .tracks:
                TrackList(tracks: LibraryIndex.search(library.tracks, query)
                    .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending })
            case .favorites:
                TrackList(tracks: LibraryIndex.search(library.tracks.filter { model.isFavorite($0) }, query),
                          empty: "ハートのボタンでお気に入りにした曲が、ここに並びます。")
            case .recentlyAdded:
                TrackList(tracks: LibraryIndex.search(Array(library.tracks
                    .sorted { (library.dateAdded($0) ?? .distantPast) > (library.dateAdded($1) ?? .distantPast) }.prefix(300)), query))
            case .recentlyPlayed:
                TrackList(tracks: LibraryIndex.search(played(by: { $0.lastPlayed?.timeIntervalSince1970 ?? 0 }), query), showPlays: true,
                          empty: "曲の半分（長い音源は 4 分）を聴くと、ここに並びます。")
            case .mostPlayed:
                TrackList(tracks: LibraryIndex.search(played(by: { Double($0.plays) }), query), showPlays: true,
                          empty: "曲の半分（長い音源は 4 分）を聴くと、再生回数を数えます。")
            case .playlist(let id):
                if let playlist = library.playlists.first(where: { $0.id == id }) {
                    TrackList(tracks: LibraryIndex.search(playlist.tracks, query), playlist: id,
                              empty: "曲の一覧で右クリックして「プレイリストに追加」を選ぶと、ここに入ります。")
                }
            }
        }
    }

    /// 再生したことのある曲を、値の大きい順に (ライブラリにない曲は出さない)
    private func played(by value: (PlayStats.Entry) -> Double) -> [Track] {
        model.stats.entries.filter { $0.value.plays > 0 }
            .sorted { value($0.value) > value($1.value) }
            .prefix(300)
            .compactMap { library.track(forKey: $0.key) }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "books.vertical").font(.system(size: 44, weight: .light))
            Text("ライブラリは空です").font(.title2.bold())
            Text("音源の入ったフォルダを追加すると、中の曲をアルバムやアーティストごとに見られます。\nフォルダをこのウィンドウにドロップしても追加できます。ファイルは動かしません。")
                .multilineTextAlignment(.center).font(.callout).foregroundStyle(.white.opacity(0.6)).lineSpacing(3)
            Button { chooseFolders() } label: { Label("フォルダを追加…", systemImage: "folder.badge.plus").padding(.horizontal, 6) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "ライブラリに入れるフォルダを選んでください"
        panel.prompt = "追加"
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in LibraryStore.shared.addFolders(urls) }
        }
    }
}

enum LibrarySection: Hashable, Identifiable {
    case albums, artists, tracks, favorites, recentlyAdded, recentlyPlayed, mostPlayed
    case playlist(UUID)

    static let fixed: [LibrarySection] = [.albums, .artists, .tracks, .favorites, .recentlyAdded, .recentlyPlayed, .mostPlayed]

    var id: String {
        if case .playlist(let id) = self { return id.uuidString }
        return title
    }

    var isPlaylist: Bool { if case .playlist = self { true } else { false } }

    var title: String {
        switch self {
        case .albums: "アルバム"
        case .artists: "アーティスト"
        case .tracks: "曲"
        case .favorites: "お気に入り"
        case .recentlyAdded: "最近追加した曲"
        case .recentlyPlayed: "最近再生した曲"
        case .mostPlayed: "よく聴く曲"
        case .playlist: "プレイリスト"
        }
    }

    var symbol: String {
        switch self {
        case .albums: "square.grid.2x2"
        case .artists: "music.microphone"
        case .tracks: "music.note"
        case .favorites: "heart"
        case .recentlyAdded: "clock.badge.checkmark"
        case .recentlyPlayed: "clock"
        case .mostPlayed: "chart.bar"
        case .playlist: "music.note.list"
        }
    }
}

// MARK: - アルバムの一覧

/// アルバムのジャケット (読み込みは裏で行い、一度読んだものは使い回す)
struct CoverView: View {
    let track: Track?
    var cornerRadius: CGFloat = 10
    @State private var image: NSImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.medium).scaledToFill()
                } else {
                    ZStack {
                        Rectangle().fill(.white.opacity(0.08))
                        Image(systemName: "music.note").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .task(id: "\(track?.artworkKey ?? "")#\(ArtworkStore.shared.revision)") {
                guard let track else { image = nil; return }
                image = ArtworkStore.shared.cachedCover(for: track)
                if image == nil { image = await ArtworkStore.shared.cover(for: track) }
            }
    }
}

private struct AlbumGrid: View {
    @Environment(PlayerModel.self) private var model
    let albums: [LibraryAlbum]
    let open: (String) -> Void

    var body: some View {
        if albums.isEmpty {
            Text("見つかりません").foregroundStyle(.white.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 148, maximum: 200), spacing: 18)], alignment: .leading, spacing: 20) {
                    ForEach(albums) { album in
                        Button { open(album.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                CoverView(track: album.tracks.first)
                                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                                Text(album.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(album.artist).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { model.playNow(album.tracks) })
                        .contextMenu { TrackActions(tracks: album.tracks) }
                        .help("\(album.title) — \(album.tracks.count) 曲（ダブルクリックで再生）")
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 4)
            }
        }
    }
}

private struct ArtistList: View {
    let artists: [(name: String, albums: [LibraryAlbum])]
    let open: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(artists, id: \.name) { artist in
                    Button { open(artist.name) } label: {
                        HStack(spacing: 12) {
                            CoverView(track: artist.albums.first?.tracks.first, cornerRadius: 21).frame(width: 42, height: 42)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                                Text("\(artist.albums.count) 枚 · \(artist.albums.reduce(0) { $0 + $1.tracks.count }) 曲")
                                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.white.opacity(0.35))
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { TrackActions(tracks: artist.albums.flatMap(\.tracks)) }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 16)
        }
    }
}

// MARK: - アルバムの中身

private struct AlbumDetail: View {
    @Environment(PlayerModel.self) private var model
    let album: LibraryAlbum

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .bottom, spacing: 18) {
                    CoverView(track: album.tracks.first, cornerRadius: 12).frame(width: 170, height: 170)
                        .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(album.title).font(.system(size: 22, weight: .bold)).lineLimit(3)
                        Text(album.artist).font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        Text([album.year, "\(album.tracks.count) 曲", formatLongDuration(album.duration)].compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        HStack(spacing: 8) {
                            Button { model.playNow(album.tracks) } label: { Label("再生", systemImage: "play.fill") }
                                .buttonStyle(.borderedProminent)
                            Button { model.playNow(album.tracks.shuffled()) } label: { Label("シャッフル", systemImage: "shuffle") }
                            Button { model.enqueue(album.tracks) } label: { Label("キューに追加", systemImage: "text.badge.plus") }
                        }
                        .padding(.top, 6)
                    }
                }
                TrackRows(tracks: album.tracks, numbered: true, source: album.tracks)
            }
            .padding(.horizontal, 20).padding(.bottom, 20).padding(.top, 4)
        }
    }
}

// MARK: - 曲の一覧

private struct TrackList: View {
    let tracks: [Track]
    var playlist: UUID?
    var showPlays = false
    var empty = "見つかりません"

    var body: some View {
        if tracks.isEmpty {
            Text(empty).font(.callout).foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center).padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                TrackRows(tracks: tracks, numbered: false, source: tracks, playlist: playlist, showPlays: showPlays)
                    .padding(.horizontal, 12).padding(.bottom, 16)
            }
        }
    }
}

private struct TrackRows: View {
    @Environment(PlayerModel.self) private var model
    let tracks: [Track]
    let numbered: Bool
    /// ダブルクリックしたとき、再生キューに入れる並び
    let source: [Track]
    var playlist: UUID?
    var showPlays = false
    @State private var hovered: UUID?

    var body: some View {
        LazyVStack(spacing: 1) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                let playing = model.currentTrack?.bookmarkKey == track.bookmarkKey
                HStack(spacing: 10) {
                    if numbered {
                        Text(track.albumPosition.track.map { "\($0)" } ?? "\(index + 1)")
                            .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                            .frame(width: 26, alignment: .trailing)
                    } else {
                        ThumbnailView(track: track, size: 32)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        (numbered ? Text(track.titleWithoutAlbum?.title ?? track.displayTitle) : Text(track.displayTitle))
                            .font(.system(size: 13, weight: playing ? .semibold : .regular))
                            .foregroundStyle(playing ? model.palette.accent : .white.opacity(0.92)).lineLimit(1)
                        if !numbered {
                            Text([track.displayArtist, track.meta.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 6)
                    if showPlays {
                        Text("\(model.stats[track.bookmarkKey].plays) 回").font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.5))
                    }
                    if model.isFavorite(track) || hovered == track.id {
                        Button { model.toggleFavorite(track) } label: {
                            Image(systemName: model.isFavorite(track) ? "heart.fill" : "heart").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(model.isFavorite(track) ? model.palette.accent : .white.opacity(0.5))
                        .accessibilityLabel(model.isFavorite(track) ? "お気に入りから外す" : "お気に入りに追加")
                    }
                    Text(formatTime(track.duration)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.white.opacity(0.45))
                        .frame(width: 46, alignment: .trailing)
                }
                .padding(.horizontal, 8).padding(.vertical, numbered ? 7 : 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hovered == track.id ? 0.07 : 0)))
                .contentShape(Rectangle())
                .onHover { hovered = $0 ? track.id : (hovered == track.id ? nil : hovered) }
                .onTapGesture(count: 2) { model.playNow(source, startAt: index) }
                .contextMenu {
                    Button("ここから再生") { model.playNow(source, startAt: index) }
                    TrackActions(tracks: [track])
                    if let playlist {
                        Divider()
                        Button("プレイリストから外す", role: .destructive) { LibraryStore.shared.remove(track.id, from: playlist) }
                    }
                }
                .help(track.url.path)
            }
        }
    }
}

/// 曲 (またはアルバム全体) に対する操作のメニュー
struct TrackActions: View {
    @Environment(PlayerModel.self) private var model
    let tracks: [Track]

    var body: some View {
        if tracks.count > 1 { Button("再生") { model.playNow(tracks) } }
        Button("次に再生") { model.enqueue(tracks, next: true) }
        Button("再生キューに追加") { model.enqueue(tracks) }
        Menu("プレイリストに追加") {
            ForEach(LibraryStore.shared.playlists) { p in
                Button(p.name) { LibraryStore.shared.append(tracks, to: p.id) }
            }
            if !LibraryStore.shared.playlists.isEmpty { Divider() }
            Button("新しいプレイリスト…") {
                LibraryStore.shared.createPlaylist(name: tracks.count == 1 ? tracks[0].displayTitle : "新しいプレイリスト", tracks: tracks)
            }
        }
        Divider()
        Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting(Array(Set(tracks.map(\.url))).prefix(20).map { $0 }) }
    }
}
