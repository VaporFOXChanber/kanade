import SwiftUI

/// 曲の情報 (タグ・ファイルの形式・音量・再生回数)
struct TrackInspector: View {
    @Environment(PlayerModel.self) private var model
    let track: Track
    @State private var measuring = false

    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/M/d H:mm"
        return f
    }()

    var body: some View {
        let m = track.meta
        let stats = model.stats[track.bookmarkKey]
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ThumbnailView(track: track, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle).font(.headline).lineLimit(2)
                    Text(track.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
                Button { model.toggleFavorite(track) } label: {
                    Image(systemName: stats.favorite ? "heart.fill" : "heart").font(.system(size: 15))
                }
                .buttonStyle(.plain)
                .foregroundStyle(stats.favorite ? model.palette.accent : .secondary)
                .accessibilityLabel(stats.favorite ? "お気に入りから外す" : "お気に入りに追加")
            }

            group("タグ") {
                row("アルバムアーティスト", m.albumArtist)
                row("トラック", trackNumber)
                row("年", m.year)
                row("ジャンル", m.genre)
            }
            group("ファイル") {
                row("形式", m.techBadges.isEmpty ? nil : m.techBadges.joined(separator: " · "))
                row("チャンネル", m.channels.map { $0 == 1 ? "モノラル" : $0 == 2 ? "ステレオ" : "\($0) ch" })
                row("長さ", track.duration.map(formatTime))
                row("サイズ", m.fileSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) })
                row("歌詞・字幕", track.lyricsURL?.lastPathComponent ?? (m.hasEmbeddedLyrics ? "埋め込み" : nil))
                row("場所", track.url.path)
            }
            group("音量") {
                row("ReplayGain (トラック)", gain(m.rgTrackGain, m.rgTrackPeak))
                row("ReplayGain (アルバム)", gain(m.rgAlbumGain, m.rgAlbumPeak))
                if let measured = model.measuredLoudness(for: track) {
                    row("測った大きさ", measured.lufs.map { String(format: "%.1f LUFS（ピーク %.1f dBFS）", $0, 20 * log10(max(measured.peak, 1e-6))) } ?? "測れませんでした（無音）")
                } else {
                    GridRow {
                        Text("測った大きさ").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        HStack(spacing: 8) {
                            Button(measuring ? "測っています…" : "大きさを測る") {
                                measuring = true
                                Task {
                                    await model.measureLoudness(track)
                                    measuring = false
                                }
                            }
                            .controlSize(.small).disabled(measuring)
                            if measuring { ProgressView().controlSize(.small) }
                        }
                    }
                }
                if track.id == model.currentID, let applied = model.currentGainInfo {
                    row("今かかっているゲイン", String(format: "%+.1f dB（%@）", applied.db, applied.source))
                }
            }
            group("再生") {
                row("再生回数", "\(stats.plays) 回")
                row("最後に再生", stats.lastPlayed.map(Self.dateFormat.string))
                row("しおり", model.bookmarks[track.bookmarkKey].map { $0.isEmpty ? nil : "\($0.count) 個" } ?? nil)
            }

            HStack {
                Spacer()
                Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([track.url]) }.controlSize(.small)
            }
        }
        .padding(18)
        .frame(width: 420)
        .tint(model.palette.accent)
    }

    private var trackNumber: String? {
        let position = track.albumPosition
        guard let number = position.track else { return nil }
        return track.meta.discNumber != nil ? "ディスク \(position.disc) の \(number)" : "\(number)"
    }

    private func gain(_ gain: Double?, _ peak: Double?) -> String? {
        guard let gain else { return nil }
        return String(format: "%+.2f dB", gain) + (peak.map { String(format: "（ピーク %.3f）", $0) } ?? "")
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) { content() }
                .font(.callout)
        }
    }

    /// 値のない項目は出さない
    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
