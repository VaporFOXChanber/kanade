import SwiftUI

/// ASMR モードの設定と、区間ループ・しおりのパネル
struct ASMRPanel: View {
    @Environment(PlayerModel.self) private var model
    @AppStorage("asmrPanelTab") private var tab = Tab.sound

    enum Tab: String, CaseIterable, Identifiable {
        case sound, sleep, position
        var id: String { rawValue }
        var label: String { ["sound": "音", "sleep": "おやすみ", "position": "ループ・しおり"][rawValue]! }
    }

    var body: some View {
        @Bindable var m = model
        let accent = model.palette.accent

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "ear").font(.system(size: 18, weight: .medium)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ASMR モード").font(.headline)
                    Text("小さな音を持ち上げ、大きな音と急な大音量を抑えます。EQ・バランス・速度・キーはオフになり、ステレオのまま再生します。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $m.asmrMode).toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("ASMR モード")
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("設定の種類")

            switch tab {
            case .sound: SoundTab(accent: accent).modeOnly(model.asmrMode)
            case .sleep: SleepTab(accent: accent)
            case .position:
                VStack(alignment: .leading, spacing: 14) {
                    LoopSection(accent: accent)
                    Divider().opacity(0.4)
                    BookmarkSection(accent: accent)
                    Divider().opacity(0.4)
                    ResumeSection().modeOnly(model.asmrMode)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .tint(accent)
    }
}

private extension View {
    /// ASMR モード中だけ効く設定: オフの間は薄くして操作できないようにする
    func modeOnly(_ on: Bool) -> some View {
        disabled(!on).opacity(on ? 1 : 0.45)
    }
}

private func row<Content: View>(_ title: String, _ symbol: String, @ViewBuilder trailing: () -> Content) -> some View {
    HStack {
        Label(title, systemImage: symbol).font(.callout)
        Spacer()
        trailing()
    }
}

private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 26)
}

// MARK: - 音

private struct SoundTab: View {
    @Environment(PlayerModel.self) private var model
    let accent: Color

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 12) {
            row("音量のならし", "waveform.path") {
                Picker("", selection: $m.asmrStrength) {
                    ForEach(ASMRStrength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 290)
                .accessibilityLabel("音量のならし")
            }
            if model.asmrStrength == .custom { CustomCurveEditor() }
            DynamicsMeters(accent: accent)
            HStack {
                Text("処理前の音と聴き比べる").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.asmrCompare ? "処理前の音" : "押している間だけ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.asmrCompare ? .black.opacity(0.8) : .white.opacity(0.85))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(model.asmrCompare ? accent : .white.opacity(0.12)))
                    .contentShape(Capsule())
                    .onLongPressGesture(minimumDuration: 0, maximumDistance: 60, perform: {}, onPressingChanged: { model.asmrCompare = $0 })
                    .help("押している間、音量のならし・ラウドネス補正などを外した音になります（左右の入れ替えとリミッターは残ります）")
                    .accessibilityLabel("処理前の音と聴き比べる")
                    .accessibilityAddTraits(.isButton)
            }
            .padding(.leading, 26)

            row("低い雑音をカット", "waveform.path.badge.minus") {
                Picker("", selection: $m.asmrLowCut) {
                    Text("オフ").tag(0.0)
                    Text("40Hz").tag(40.0)
                    Text("80Hz").tag(80.0)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 180)
                .accessibilityLabel("低い雑音をカット")
            }
            caption("マイクに触れる音や空調・風のような、ごく低い雑音を切ります。小さい音を持ち上げたときに、低いうなりまで大きくなるのを防げます。")

            row("高音の刺さりをやわらげる", "waveform.badge.minus") {
                Picker("", selection: $m.asmrSoftening) {
                    ForEach(ASMRSoftening.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                .accessibilityLabel("高音の刺さりをやわらげる")
            }
            caption("サ行の音や金属音など、強い高音が来たときだけ高音を下げます。小さな音の高音はそのままです。")

            row("小音量時のラウドネス補正", "speaker.wave.1") {
                Toggle("", isOn: $m.asmrLoudness).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("小音量時のラウドネス補正")
            }
            caption(loudnessCaption)

            row("左右", "arrow.left.arrow.right") {
                Button { model.playChannelCheck() } label: { Label("左右を確認", systemImage: "headphones") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("左で 1 回、右で 2 回、小さな音を鳴らします")
                Button {
                    model.swapChannels.toggle()
                } label: {
                    Label(model.swapChannels ? "入れ替え中 (R ⇄ L)" : "L ⇄ R を入れ替える", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .tint(model.swapChannels ? accent : nil)
                .controlSize(.small)
            }
            caption("確認音は左で 1 回、右で 2 回鳴ります。逆に聞こえたらイヤホンが左右逆です。合っているのに音源が逆に聞こえるときは、入れ替えを使います。")
        }
    }

    private var loudnessCaption: String {
        let b = model.loudnessBoost
        guard model.asmrMode, model.asmrLoudness else { return "音量を下げると聞こえにくくなる低音と高音を、音量に合わせて補います。" }
        if b.low < 0.1 { return "今の音量では補正していません (音量を下げると効きます)" }
        return String(format: "今の音量で 低音 +%.1f dB・高音 +%.1f dB", b.low, b.high)
    }
}

/// 「カスタム」の強さの値を決める
private struct CustomCurveEditor: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var m = model
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            slider("持ち上げ始め", $m.asmrCustom.upThreshold, -45 ... -20, "%.0f dB", "これより小さい音を持ち上げます")
            slider("持ち上げの上限", $m.asmrCustom.maxBoost, 0...18, "+%.0f dB", "持ち上げる量の上限")
            slider("抑え始め", $m.asmrCustom.downThreshold, -30 ... -6, "%.0f dB", "これより大きい音を抑えます")
            slider("抑えの比率", $m.asmrCustom.downRatio, 1.5...8, "%.1f : 1", "超えた分をこの比率で小さくします")
        }
        .font(.caption)
        .padding(.leading, 26)
    }

    private func slider(_ title: String, _ value: Binding<Float>, _ range: ClosedRange<Float>, _ format: String, _ help: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Slider(value: value, in: range, step: range.upperBound <= 8 ? 0.5 : 1)
                .controlSize(.small)
                .accessibilityLabel(title)
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 58, alignment: .trailing)
        }
        .help(help)
    }
}

/// 今どれだけ持ち上げ・抑えているか (再生中だけ 4 回/秒で更新)
private struct DynamicsMeters: View {
    @Environment(PlayerModel.self) private var model
    let accent: Color

    var body: some View {
        if model.asmrMode, model.isPlaying {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                let m = model.engine.asmrMeters
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        meter("持ち上げ", m.boost, range: 18, color: accent)
                        meter("抑え", m.cut, range: 20, color: .orange)
                        meter("リミッター", m.limit, range: 12, color: .red)
                        if model.asmrSoftening != .off {
                            meter("高音", m.soften, range: 9, color: .teal)
                        }
                    }
                    Text(m.input < -90 ? "入力 —  →  出力 —" : String(format: "入力 %.0f dB  →  出力 %.0f dB", m.input, m.output))
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 26)
        }
    }

    private func meter(_ label: String, _ db: Float, range: Float, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text(abs(db) < 0.05 ? "0 dB" : String(format: "%+.1f dB", db)).monospacedDigit()
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(color.opacity(0.85)).frame(width: g.size.width * CGFloat(min(1, abs(db) / range)))
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - おやすみ

private struct SleepTab: View {
    @Environment(PlayerModel.self) private var model
    let accent: Color
    private static let minutes = [15, 30, 45, 60, 90, 120]
    private static let fades: [Double] = [60, 180, 300, 600]
    private static let dateFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M/d H:mm"
        return f
    }()

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("スリープタイマー", systemImage: "moon.zzz").font(.callout)
                    Spacer()
                    if model.sleepDeadline != nil {
                        Button("+15 分") { model.extendSleep() }.controlSize(.small)
                            .help("タイマーを 15 分延ばします。小さくなり始めていた音量も戻ります")
                    }
                    if model.sleepDeadline != nil || model.sleepAtTrackEnd {
                        Button("解除") { model.cancelSleep() }.controlSize(.small)
                    }
                }
                HStack(spacing: 6) {
                    ForEach(Self.minutes, id: \.self) { n in
                        Button("\(n)分") { model.setSleepTimer(minutes: n) }
                            .controlSize(.small)
                    }
                    Button("曲の終わり") { model.setSleepAtTrackEnd() }
                        .controlSize(.small)
                        .help("この曲の終わりで停止")
                }
                .padding(.leading, 26)
                HStack {
                    Text("フェードアウト").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $m.asmrSleepFade) {
                        ForEach(Self.fades, id: \.self) { Text(model.fadeLabel($0)).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                    .accessibilityLabel("フェードアウトの長さ")
                }
                .padding(.leading, 26)
                status.padding(.leading, 26)
            }
            .modeOnly(model.asmrMode)

            Divider().opacity(0.4)
            sleepPoint

            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 12) {
                row("省電力表示", "moon") {
                    Toggle("", isOn: $m.lowPowerDisplay).toggleStyle(.switch).controlSize(.small).labelsHidden()
                        .accessibilityLabel("省電力表示")
                }
                caption("回転や針のアニメーション・ビジュアライザーを止め、表示の更新を 1 秒ごとにします。")
            }
            .modeOnly(model.asmrMode)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let d = model.sleepDeadline {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let remaining = max(0, d.timeIntervalSinceNow)
                Text(remaining <= model.sleepFadeDuration
                     ? "フェードアウト中… あと \(formatTime(remaining)) で停止"
                     : "あと \(formatTime(remaining)) で停止 (最後の \(model.fadeLabel(model.sleepFadeDuration)) で少しずつ小さく)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(accent)
            }
        } else if model.sleepAtTrackEnd {
            Text("この曲の終わりで停止します").font(.caption).foregroundStyle(accent)
        }
    }

    /// 前回のスリープタイマーをセットした位置 (寝落ちする前に、確かに聴いていたところ)
    private var sleepPoint: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("おやすみ前の位置", "bed.double") {
                Button("そこへ戻る") { model.returnToSleepPoint() }
                    .controlSize(.small)
                    .disabled(model.sleepPointTrack == nil)
            }
            if let point = model.lastSleepPoint {
                caption("\(Self.dateFormat.string(from: point.date)) にタイマーをセットしたのは「\(point.title)」の \(formatTime(point.time)) でした。"
                        + (model.sleepPointTrack == nil ? "この曲は今の再生キューにありません。" : ""))
            } else {
                caption("スリープタイマーで止まると、タイマーをセットしたときの位置を覚えておきます。寝落ちしたあと、聴いた覚えのあるところから聴き直せます。")
            }
        }
    }
}

// MARK: - 続きから再生

private struct ResumeSection: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 8) {
            row("長い音源は続きから再生", "arrow.uturn.forward") {
                Toggle("", isOn: $m.asmrResume).toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel("長い音源は続きから再生")
            }
            caption("10 分以上の音源を途中で離れると位置を覚えておき、次にその曲を選んだときに続きから再生します。")
        }
    }
}

// MARK: - 区間ループ

private struct LoopSection: View {
    @Environment(PlayerModel.self) private var model
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("区間ループ", systemImage: "repeat").font(.callout)
                if model.loopA != nil, model.loopB != nil {
                    Text("ループ中").font(.caption.bold()).foregroundStyle(accent)
                }
                Spacer()
                if model.loopA != nil || model.loopB != nil {
                    Button("解除") { model.clearLoop() }.controlSize(.small)
                }
            }
            point("A", model.loopA, start: true)
            point("B", model.loopB, start: false)
        }
        .disabled(model.currentTrack == nil)
    }

    private func point(_ label: String, _ time: Double?, start: Bool) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(accent).frame(width: 18)
            Text(time.map(formatTime) ?? "--:--")
                .font(.callout.monospacedDigit())
                .foregroundStyle(time == nil ? .secondary : .primary)
                .frame(width: 64, alignment: .leading)
            Button("今の位置") { start ? model.setLoopStartHere() : model.setLoopEndHere() }
                .controlSize(.small)
            Button { model.nudgeLoop(start: start, by: -1) } label: { Text("−1秒") }
                .controlSize(.small).disabled(time == nil)
            Button { model.nudgeLoop(start: start, by: 1) } label: { Text("+1秒") }
                .controlSize(.small).disabled(time == nil)
        }
        .padding(.leading, 8)
    }
}

// MARK: - しおり

private struct BookmarkSection: View {
    @Environment(PlayerModel.self) private var model
    let accent: Color

    var body: some View {
        let list = model.currentBookmarks
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("しおり", systemImage: "bookmark").font(.callout)
                Spacer()
                Button {
                    model.addBookmark()
                } label: {
                    Label("今の位置にはさむ", systemImage: "bookmark.fill")
                }
                .controlSize(.small)
                .help("しおりをはさむ (⌘D)。⌘[ / ⌘] で前後のしおりへ移動")
            }
            if list.isEmpty {
                Text("⌘D で今の位置にしおりをはさめます。しおりからしおりまでをループすることもできます。")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(list) { b in BookmarkRow(bookmark: b, accent: accent) }
                    }
                }
                .frame(maxHeight: 176)
                .fixedSize(horizontal: false, vertical: list.count <= 5)
            }
        }
        .disabled(model.currentTrack == nil)
    }
}

private struct BookmarkRow: View {
    @Environment(PlayerModel.self) private var model
    let bookmark: Bookmark
    let accent: Color
    @State private var name = ""
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            Button { model.jump(to: bookmark) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.system(size: 9))
                    Text(formatTime(bookmark.time)).monospacedDigit()
                }
                .font(.callout)
                .foregroundStyle(accent)
                .frame(width: 72, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("ここから再生")

            TextField("名前", text: $name)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit { commit() }
                .onChange(of: name) { commit() }

            Button { model.loop(from: bookmark) } label: { Image(systemName: "repeat") }
                .buttonStyle(.borderless)
                .help("ここから次のしおりまでループ")
                .accessibilityLabel("ここから次のしおりまでループ")
            Button { model.removeBookmark(bookmark.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("このしおりを削除")
                .accessibilityLabel("このしおりを削除")
                .opacity(hover ? 1 : 0.5)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hover ? 0.07 : 0.03)))
        .onHover { hover = $0 }
        .onAppear { name = bookmark.name }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != bookmark.name else { return }
        model.renameBookmark(bookmark.id, to: trimmed)
    }
}
