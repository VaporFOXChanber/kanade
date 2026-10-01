import SwiftUI
import UniformTypeIdentifiers

struct LyricsView: View {
    @Environment(PlayerModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        Group {
            if let lyrics = model.lyrics, !lyrics.lines.isEmpty {
                if lyrics.synced {
                    let index = lyrics.index(at: model.clock.position)
                    SyncedLyrics(lyrics: lyrics, index: index,
                                 active: index.map { lyrics.isActive($0, at: model.clock.position) } ?? false,
                                 accent: model.palette.accent) { t in
                        model.seek(to: t)
                    }
                    .equatable()
                } else {
                    ScrollView(showsIndicators: false) {
                        Text(lyrics.lines.map(\.text).joined(separator: "\n"))
                            .font(.system(size: 19, weight: .semibold))
                            .lineSpacing(9)
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 40)
                            .textSelection(.enabled)
                    }
                    .fadingEdges()
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "quote.bubble").font(.system(size: 38, weight: .light))
                    Text("歌詞がありません").font(.title3.weight(.semibold))
                    Text("同じ名前の .lrc / .srt / .vtt ファイルを置くか、\nここに歌詞・字幕のファイルをドロップしてください。")
                        .multilineTextAlignment(.center)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.55))
                }
                .foregroundStyle(.white.opacity(0.8))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 20).strokeBorder(model.palette.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { ["lrc", "srt", "vtt", "txt"].contains($0.pathExtension.lowercased()) }) else { return false }
            model.attachLyrics(u)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

struct SyncedLyrics: View, Equatable {
    let lyrics: Lyrics
    let index: Int?
    /// index の行を今も表示しているか (字幕は終わりの時刻を過ぎると、次の字幕まで強調を消す)
    var active = true
    let accent: Color
    let seek: (Double) -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.lyrics == b.lyrics && a.index == b.index && a.active == b.active && a.accent == b.accent
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear.frame(height: 90)
                    ForEach(lyrics.lines) { line in
                        let isCurrent = active && line.id == index
                        let distance = Double(index.map { abs($0 - line.id) } ?? 2)
                        let past = line.id < (index ?? 0) || (!active && line.id == index)
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(isCurrent ? .white : .white.opacity(past ? 0.28 : 0.38))
                            .shadow(color: isCurrent ? accent.opacity(0.6) : .clear, radius: 14)
                            .blur(radius: line.id == index ? 0 : min(2.4, distance * 0.6))
                            .scaleEffect(isCurrent ? 1 : 0.94, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { if let t = line.time { seek(t) } }
                            .id(line.id)
                            .animation(.spring(duration: 0.55), value: index)
                            .animation(.easeOut(duration: 0.4), value: active)
                    }
                    Color.clear.frame(height: 220)
                }
            }
            .fadingEdges()
            .onChange(of: index, initial: true) { _, new in
                guard let new else { return }
                withAnimation(.spring(duration: 0.7)) { proxy.scrollTo(new, anchor: UnitPoint(x: 0, y: 0.35)) }
            }
        }
    }
}

extension View {
    func fadingEdges() -> some View {
        mask(LinearGradient(stops: [
            .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
            .init(color: .black, location: 0.82), .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}
