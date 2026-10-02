import SwiftUI

struct NowPlayingView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Group {
                if model.currentTrack == nil {
                    EmptyStateView()
                } else if model.showLyrics {
                    LyricsLayout()
                } else {
                    HeroLayout()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 12) {
                if model.visualizer != .off, !model.powerSaving {
                    VisualizerView().frame(height: 58).transition(.opacity)
                }
                SeekBar()
                TransportControls().padding(.top, 2)
                ControlBar().padding(.top, 6)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 32)
            .padding(.bottom, 20)
            .disabled(model.currentTrack == nil)
            .opacity(model.currentTrack == nil ? 0.45 : 1)
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            Spacer()
            if model.powerSaving {
                Label("省電力表示", systemImage: "moon.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.07), in: Capsule())
                    .help("ASMR モードの省電力表示: アニメーションを止めています")
                    .padding(.trailing, 4)
            }
            SkinMenu()
            IconButton(symbol: "books.vertical", size: 14, help: "ライブラリ (⌥⌘L)") { openWindow(id: "library") }
            IconButton(symbol: "plus", size: 14, help: "ファイル・フォルダを開く (⌘O)") { presentOpenPanel() }
            IconButton(symbol: "pip.enter", size: 14, help: "ミニプレイヤー (⌥⌘M)") { MiniPlayerPanel.shared.show() }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }
}

// MARK: - アートワーク + 曲情報

private struct HeroLayout: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            if model.skin == .standard {
                ArtworkView(image: model.artwork, palette: model.palette, cornerRadius: 18)
                    .artworkShadow(model.palette.accent)
                    .frame(minWidth: 120, maxWidth: 400, minHeight: 120, maxHeight: 400)
                    .scaleEffect(model.isPlaying ? 1 : 0.94)
                    .animation(.spring(duration: 0.6, bounce: 0.25), value: model.isPlaying)
                    .layoutPriority(-1)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            } else {
                PlayerSkinView(skin: model.skin)
                    .frame(minWidth: 160, maxWidth: 640, minHeight: 120, maxHeight: 440)
                    .layoutPriority(-1)
                    .id(model.skin)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
            TrackInfo(alignment: .center)
        }
        .contextMenu {
            Button("この作品のアートワークを選ぶ…") { model.chooseArtwork() }
            Button("アートワークを元に戻す") { model.clearCustomArtwork() }.disabled(!model.hasCustomArtwork)
        }
        .animation(.spring(duration: 0.5, bounce: 0.2), value: model.skin)
        .padding(.horizontal, 40)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }
}

private struct LyricsLayout: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > 700 {
                HStack(alignment: .center, spacing: 44) {
                    VStack(spacing: 18) {
                        ArtworkView(image: model.artwork, palette: model.palette, cornerRadius: 14)
                            .frame(maxWidth: 250, maxHeight: 250)
                            .artworkShadow(model.palette.accent, glow: 0)
                        TrackInfo(alignment: .center, compact: true)
                    }
                    .frame(width: 270)
                    LyricsView()
                }
                .padding(.horizontal, 44)
            } else {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        ArtworkView(image: model.artwork, palette: model.palette, cornerRadius: 8).frame(width: 52, height: 52)
                        TrackInfo(alignment: .leading, compact: true)
                        Spacer()
                    }
                    LyricsView()
                }
                .padding(.horizontal, 32)
            }
        }
    }
}

struct TrackInfo: View {
    @Environment(PlayerModel.self) private var model
    var alignment: HorizontalAlignment = .center
    var compact = false

    var body: some View {
        let t = model.currentTrack
        VStack(alignment: alignment, spacing: compact ? 3 : 6) {
            (t.map(shortTitleText) ?? Text(""))
                .font(.system(size: compact ? 17 : 26, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
                .contentTransition(.opacity)
            Text(t?.subtitle ?? "")
                .font(.system(size: compact ? 12.5 : 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(1)
            if !compact, let t {
                badges(for: t).padding(.top, 5)
            }
        }
        .foregroundStyle(.white)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func badges(for t: Track) -> some View {
        let m = t.meta
        let hiRes = (m.lossless ?? false) && ((m.bitDepth ?? 0) >= 24 || (m.sampleRate ?? 0) > 48000 || m.bitDepth == 1)
        HStack(spacing: 6) {
            if hiRes { Badge(text: "Hi-Res", highlight: Color(red: 1, green: 0.8, blue: 0.35)) }
            else if m.lossless == true { Badge(text: "ロスレス", highlight: model.palette.accent) }
            ForEach(m.techBadges, id: \.self) { Badge(text: $0) }
            if model.replayGain != .off, let g = model.replayGain == .album ? (m.rgAlbumGain ?? m.rgTrackGain) : (m.rgTrackGain ?? m.rgAlbumGain) {
                Badge(text: String(format: "RG %+.1fdB", g))
            }
            if t.isCueTrack { Badge(text: "CUE") }
            if model.asmrMode { Badge(text: model.swapChannels ? "ASMR · L⇄R" : "ASMR", highlight: model.palette.accent) }
            if model.signalPath?.quality == .bitPerfect {
                Badge(text: "ビットパーフェクト", highlight: model.palette.accent)
                    .help("元のデータを 1 ビットも変えずに出力しています（⌥⌘E の「出力」で道筋を確認できます）")
            } else if model.signalPath?.quality == .dsdNative {
                Badge(text: "DSD ネイティブ", highlight: model.palette.accent)
                    .help("DSD のデータを PCM に変換せず、そのまま DAC へ送っています（DoP）")
            }
        }
    }
}

// MARK: - 再生ボタン

struct TransportControls: View {
    @Environment(PlayerModel.self) private var model
    @State private var showInfo = false

    var body: some View {
        let accent = model.palette.accent
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 22) {
                IconButton(symbol: model.isCurrentFavorite ? "heart.fill" : "heart", size: 15, active: model.isCurrentFavorite, tint: accent,
                           help: model.isCurrentFavorite ? "お気に入りから外す (⌘⇧F)" : "お気に入りに追加 (⌘⇧F)") {
                    model.toggleFavorite()
                }
                IconButton(symbol: "shuffle", size: 15, active: model.shuffle, tint: accent, help: "シャッフル") {
                    model.shuffle.toggle()
                }
                IconButton(symbol: "backward.fill", size: 20, help: "前の曲 (⌘←)") { model.previous() }

                Button { model.togglePlay() } label: {
                    ZStack {
                        if model.isPreparing {
                            ProgressView().controlSize(.small).tint(.black)
                        } else {
                            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 25, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                                .offset(x: model.isPlaying ? 0 : 2)
                        }
                    }
                    .foregroundStyle(.black.opacity(0.82))
                    .frame(width: 64, height: 64)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.tint(accent.opacity(0.92)).interactive(), in: .circle)
                .help("再生 / 一時停止 (スペース)")

                IconButton(symbol: "forward.fill", size: 20, help: "次の曲 (⌘→)") { model.next() }
                IconButton(symbol: model.repeatMode == .one ? "repeat.1" : "repeat", size: 15,
                           active: model.repeatMode != .off, tint: accent,
                           help: ["off": "リピート: オフ", "all": "リピート: すべて", "one": "リピート: 1曲"][model.repeatMode.rawValue]!) {
                    model.repeatMode = model.repeatMode.next
                }
                IconButton(symbol: "info.circle", size: 15, active: showInfo, tint: accent, help: "曲の情報 (⌘I)") { showInfo.toggle() }
                    .popover(isPresented: $showInfo, arrowEdge: .top) {
                        if let t = model.currentTrack { TrackInspector(track: t).environment(model) }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: .kanadeShowInfo)) { _ in showInfo = true }
            }
        }
    }
}

// MARK: - 下部のコントロールバー

struct ControlBar: View {
    @Environment(PlayerModel.self) private var model
    @State private var showSound = false

    var body: some View {
        @Bindable var m = model
        let accent = model.palette.accent

        HStack(spacing: 4) {
            IconButton(symbol: volumeSymbol, size: 14, help: "消音 (M)") { model.muted.toggle() }
            CapsuleSlider(value: $m.volume, tint: .white.opacity(0.85))
                .frame(width: 110)
                .onChange(of: model.volume) { if model.muted { model.muted = false } }
                .disabled(model.volumeLocked)
                .opacity(model.volumeLocked ? 0.4 : 1)
                .help(!model.bitPerfect ? "音量" : model.volumeLocked
                      ? "ビットパーフェクト再生中: このデバイスの音量は、アンプなどデバイス側で調整してください"
                      : "ビットパーフェクト再生中: 出力デバイス側の音量を動かします")

            Spacer(minLength: 12)

            Menu {
                ForEach([0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                    Button { model.rate = r } label: {
                        if abs(model.rate - r) < 0.001 { Label(rateLabel(r), systemImage: "checkmark") } else { Text(rateLabel(r)) }
                    }
                }
            } label: {
                Text(rateLabel(model.effectiveRate))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(model.effectiveRate == 1 ? .white.opacity(0.7) : accent)
            .padding(.horizontal, 6)
            .disabled(model.effectsOff)
            .opacity(model.effectsOff ? 0.45 : 1)
            .help(model.asmrMode ? "ASMR モード中は等速で再生します" : model.bitPerfect ? "ビットパーフェクト再生中は等速で再生します" : "再生速度")

            ASMRButton(accent: accent)
            if model.asmrMode {
                IconButton(symbol: "arrow.left.arrow.right", size: 13, active: model.swapChannels, tint: accent,
                           help: model.swapChannels ? "左右を入れ替え中 (クリックで戻す)" : "左右を入れ替える") {
                    model.swapChannels.toggle()
                }
                IconButton(symbol: model.currentBookmarks.isEmpty ? "bookmark" : "bookmark.fill", size: 13, help: "しおりをはさむ (⌘D)") {
                    model.addBookmark()
                }
            }

            IconButton(symbol: "slider.vertical.3", size: 14, active: showSound || (!model.effectsOff && model.eqEnabled && model.eqBands.contains { $0 != 0 }),
                       tint: accent, help: "イコライザー・音響効果 (⌥⌘E)") { showSound.toggle() }
                .popover(isPresented: $showSound, arrowEdge: .top) { SoundPanel().environment(model) }
                .onReceive(NotificationCenter.default.publisher(for: .kanadeShowSound)) { _ in showSound = true }
            IconButton(symbol: model.bitPerfect ? "checkmark.seal.fill" : "checkmark.seal", size: 14, active: model.bitPerfect,
                       tint: model.bitPerfectShortfall == nil ? accent : .orange,
                       help: !model.bitPerfect ? "ビットパーフェクト再生: 音を変える処理をすべて外して、元のデータのまま出力する (⇧⌘B)"
                           : model.bitPerfectShortfall ?? "ビットパーフェクト再生中 (⇧⌘B で解除)") {
                model.setBitPerfect(!model.bitPerfect)
            }

            Button { model.toggleABLoop() } label: {
                Text(model.loopB != nil ? "A-B" : model.loopA != nil ? "A-" : "A-B")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(model.loopA != nil ? accent : .white.opacity(0.66))
                    .frame(width: 34, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("A-B リピート: 1回目で A 地点、2回目で B 地点、3回目で解除")

            SleepMenu(accent: accent)
            OutputMenu(accent: accent)

            IconButton(symbol: "quote.bubble", size: 14, active: model.showLyrics, tint: accent, help: "歌詞 (⌘L)") {
                withAnimation(.spring(duration: 0.45)) { model.showLyrics.toggle() }
            }
            IconButton(symbol: "list.bullet", size: 14, active: model.showQueue, tint: accent, help: "再生キュー (⌘U)") {
                model.showQueue.toggle()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    private var volumeSymbol: String {
        if model.muted || model.volume == 0 { return "speaker.slash.fill" }
        return model.volume < 0.34 ? "speaker.wave.1.fill" : model.volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

/// ASMR モードの切り替えと設定パネル
private struct ASMRButton: View {
    @Environment(PlayerModel.self) private var model
    let accent: Color
    @State private var show = false
    @State private var hover = false

    var body: some View {
        Button { show.toggle() } label: {
            Text("ASMR")
                .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                .foregroundStyle(model.asmrMode ? .black.opacity(0.8) : .white.opacity(hover ? 0.95 : 0.66))
                .padding(.horizontal, 7)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(model.asmrMode ? accent : .white.opacity(hover ? 0.14 : 0.08)))
                .frame(height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .popover(isPresented: $show, arrowEdge: .top) { ASMRPanel().environment(model) }
        .onReceive(NotificationCenter.default.publisher(for: .kanadeShowASMR)) { _ in show = true }
        .help(model.asmrMode ? "ASMR モード中 (クリックで設定・しおり)" : "ASMR モード (⌥⌘A)")
        .accessibilityLabel("ASMR モードの設定")
        .accessibilityValue(model.asmrMode ? "オン" : "オフ")
    }
}

private struct SleepMenu: View {
    @Environment(PlayerModel.self) private var model
    let accent: Color

    var body: some View {
        let active = model.sleepDeadline != nil || model.sleepAtTrackEnd
        Menu {
            if model.sleepDeadline != nil { Button("15 分延ばす") { model.extendSleep() } }
            if active { Button("タイマーを解除") { model.cancelSleep() }; Divider() }
            ForEach([15, 30, 45, 60, 90, 120], id: \.self) { m in
                Button("\(m) 分後に停止") { model.setSleepTimer(minutes: m) }
            }
            Divider()
            Button("この曲の終わりで停止") { model.setSleepAtTrackEnd() }
            if model.lastSleepPoint != nil {
                Divider()
                Button("おやすみ前の位置へ戻る") { model.returnToSleepPoint() }
            }
            if model.asmrMode {
                Divider()
                Menu("フェードアウト: \(model.fadeLabel(model.asmrSleepFade))") {
                    ForEach([60.0, 180, 300, 600], id: \.self) { f in
                        Button { model.asmrSleepFade = f } label: {
                            if model.asmrSleepFade == f { Label(model.fadeLabel(f), systemImage: "checkmark") } else { Text(model.fadeLabel(f)) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: active ? "moon.zzz.fill" : "moon.zzz")
                if let d = model.sleepDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(formatTime(max(0, d.timeIntervalSinceNow))).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    }
                }
            }
            .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(active ? accent : .white.opacity(0.66))
        .padding(.horizontal, 6)
        .help("スリープタイマー")
        .accessibilityLabel("スリープタイマー")
    }
}

private struct OutputMenu: View {
    @Environment(PlayerModel.self) private var model
    let accent: Color

    var body: some View {
        Menu {
            Button { model.selectOutputDevice(nil) } label: {
                if model.outputDeviceUID == nil { Label("システム設定に従う", systemImage: "checkmark") } else { Text("システム設定に従う") }
            }
            Divider()
            ForEach(model.outputDevices) { d in
                Button { model.selectOutputDevice(d) } label: {
                    if model.outputDeviceUID == d.uid { Label(d.name, systemImage: "checkmark") } else { Text(d.name) }
                }
            }
            Divider()
            Button("デバイス一覧を更新") { model.refreshOutputDevices() }
        } label: {
            Image(systemName: "hifispeaker.2").font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.outputDeviceUID != nil ? accent : .white.opacity(0.66))
        .padding(.horizontal, 6)
        .help("出力デバイス")
    }
}

// MARK: - 見た目の切り替え

private struct SkinMenu: View {
    @Environment(PlayerModel.self) private var model
    @State private var hover = false

    var body: some View {
        Menu {
            ForEach(PlayerSkin.allCases) { s in
                Button { model.skin = s } label: {
                    Label(s.label, systemImage: model.skin == s ? "checkmark" : s.symbol)
                }
            }
        } label: {
            Image(systemName: model.skin == .standard ? "paintpalette" : model.skin.symbol)
                .font(.system(size: 14, weight: .medium))
                .accessibilityLabel("プレイヤーの見た目")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(model.skin == .standard ? .white.opacity(hover ? 0.95 : 0.66) : model.palette.accent)
        .frame(width: 32, height: 32)
        .background(Circle().fill(.white.opacity(hover ? 0.1 : 0)))
        .onHover { hover = $0 }
        .help("プレイヤーの見た目 (⌥⌘P)")
        .accessibilityLabel("プレイヤーの見た目")
        .accessibilityValue(model.skin.label)
    }
}

// MARK: - 空の状態

struct EmptyStateView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
            Text("音源をここにドロップ").font(.system(size: 22, weight: .bold))
            Text("ファイルでもフォルダでも。MP3・AAC・FLAC・ハイレゾ WAV から\nWMA・APE・DSD・WavPack・動画ファイルの音声まで再生できます。")
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.6))
                .lineSpacing(3)
            Button { presentOpenPanel() } label: {
                Label("ファイルを開く…", systemImage: "folder").padding(.horizontal, 6)
            }
            .buttonStyle(.glassProminent)
            .tint(model.palette.accent.opacity(0.7))
            .controlSize(.large)
            .padding(.top, 6)
        }
        .foregroundStyle(.white)
        .padding(44)
        .background {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1.5, dash: [7, 7]))
        }
        .padding(40)
    }
}

@MainActor
func presentOpenPanel() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.message = "再生したいファイルやフォルダを選んでください"
    panel.prompt = "追加"
    panel.begin { response in
        guard response == .OK else { return }
        let urls = panel.urls
        Task { @MainActor in
            let model = PlayerModel.shared
            model.add(urls, play: !model.isPlaying)
        }
    }
}

extension Notification.Name {
    static let kanadeShowSound = Notification.Name("kanadeShowSound")
    static let kanadeShowASMR = Notification.Name("kanadeShowASMR")
    static let kanadeShowInfo = Notification.Name("kanadeShowInfo")
}
