import SwiftUI
import UniformTypeIdentifiers

struct QueueView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var m = model
        let tracks = model.filteredQueue
        let searching = !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty

        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("再生キュー").font(.system(size: 17, weight: .bold))
                    Text(model.queue.isEmpty ? "空です" : "\(model.queue.count) 曲 · \(formatLongDuration(model.totalDuration))")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
                        .numericTransition()
                }
                Spacer()
                Menu {
                    Menu("並べ替え") {
                        Button("タイトル") { model.sort(by: .title) }
                        Button("アーティスト") { model.sort(by: .artist) }
                        Button("アルバム") { model.sort(by: .album) }
                        Button("アルバムのトラック順") { model.sort(by: .albumTrack) }
                        Button("ファイル名") { model.sort(by: .fileName) }
                        Button("長さ") { model.sort(by: .duration) }
                        Divider()
                        Button("ランダムに並べ替え") { model.sort(by: .random) }
                    }
                    Button("重複を削除") { model.removeDuplicates() }
                    Button("プレイリストとして保存") { model.saveQueueAsPlaylist() }
                    Button("プレイリストを書き出す…") { exportPlaylist() }
                    Divider()
                    Button("キューを消去", role: .destructive) { model.clearQueue() }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .buttonStyle(.glass)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("キュー内を検索", text: $m.searchText).textFieldStyle(.plain)
                if searching {
                    Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.5))
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.white.opacity(0.07), in: Capsule())

            if model.queue.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.system(size: 28, weight: .light))
                    Text("ファイルやフォルダを\nここにドロップ").multilineTextAlignment(.center).font(.callout)
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in model.add(urls, play: true); return true }
            } else {
                ScrollViewReader { proxy in
                    List(selection: $m.selection) {
                        ForEach(tracks) { track in
                            QueueRow(track: track,
                                     isCurrent: track.id == model.currentID,
                                     playing: model.isPlaying && !model.powerSaving,
                                     failed: model.failed.contains(track.id),
                                     accent: model.palette.accent)
                                .tag(track.id)
                                .id(track.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
                        }
                        .onMove(perform: searching ? nil : { model.move(from: $0, to: $1) })
                        .onInsert(of: [.fileURL]) { index, providers in
                            Task {
                                let urls = await loadURLs(providers)
                                model.add(urls, at: index)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if !ids.isEmpty {
                            Button("再生") { if let t = model.track(ids.first) { model.start(t) } }
                            Button("次に再生") { model.playNext(ids) }
                            Button("お気に入りに追加 / 外す") { ids.compactMap(model.track).forEach { model.toggleFavorite($0) } }
                            Menu("プレイリストに追加") {
                                let tracks = model.queue.filter { ids.contains($0.id) }
                                ForEach(LibraryStore.shared.playlists) { p in
                                    Button(p.name) { LibraryStore.shared.append(tracks, to: p.id) }
                                }
                                if !LibraryStore.shared.playlists.isEmpty { Divider() }
                                Button("新しいプレイリスト…") {
                                    LibraryStore.shared.createPlaylist(name: tracks.first?.displayTitle ?? "新しいプレイリスト", tracks: tracks)
                                }
                            }
                            let outside = model.queue.filter { ids.contains($0.id) && LibraryStore.shared.track(forKey: $0.bookmarkKey) == nil }
                            if !outside.isEmpty {
                                Button("ライブラリに追加") {
                                    let files = outside.map(Importer.librarySource)
                                    if LibraryStore.shared.addSources(files) {
                                        model.showToast(outside.count == 1 ? "「\(outside[0].displayTitle)」をライブラリに追加しました" : "\(outside.count) 曲をライブラリに追加しました",
                                                        symbol: "books.vertical")
                                    } else {
                                        model.showToast("この形式のファイルは、ライブラリに追加できません", symbol: "exclamationmark.triangle")
                                    }
                                }
                            }
                            Button("Finder で表示") {
                                NSWorkspace.shared.activateFileViewerSelecting(ids.compactMap { model.track($0)?.url })
                            }
                            Divider()
                            Button("キューから削除", role: .destructive) { model.remove(ids) }
                        }
                    } primaryAction: { ids in
                        if let id = ids.first, let t = model.track(id) { model.start(t) }
                    }
                    .onDeleteCommand { model.remove(model.selection) }
                    .onChange(of: model.currentID) { _, id in
                        guard let id, !searching else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = model.currentID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func exportPlaylist() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m3u8") ?? .plainText]
        panel.nameFieldStringValue = "Kanade プレイリスト.m3u8"
        let text = PlaylistFile.export(model.queue)
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

struct QueueRow: View {
    let track: Track
    let isCurrent: Bool
    let playing: Bool
    let failed: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(track: track, size: 38)
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.45))
                        PlayingIndicator(playing: playing, color: .white)
                    }
                }
            VStack(alignment: .leading, spacing: 2) {
                titleText
                    .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? accent : failed ? .red.opacity(0.8) : .white.opacity(0.92))
                    .lineLimit(1)
                Text(track.displayArtist)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if failed {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.red.opacity(0.8))
            }
            Text(formatTime(track.duration))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .help(track.url.path)
    }

    private var titleText: Text { shortTitleText(track) }
}

func loadURLs(_ providers: [NSItemProvider]) async -> [URL] {
    var urls: [URL] = []
    for p in providers {
        let url: URL? = await withCheckedContinuation { cont in
            _ = p.loadObject(ofClass: URL.self) { u, _ in cont.resume(returning: u) }
        }
        if let url { urls.append(url) }
    }
    return urls
}
