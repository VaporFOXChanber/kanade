import SwiftUI
import UniformTypeIdentifiers

/// イコライザー・ヘッドホン補正・再生・出力の設定パネル
struct SoundPanel: View {
    @Environment(PlayerModel.self) private var model
    @AppStorage("soundPanelTab") private var tab = Tab.equalizer

    enum Tab: String, CaseIterable, Identifiable {
        case equalizer, headphone, playback, output, advanced
        var id: String { rawValue }
        var label: String {
            ["equalizer": "イコライザー", "headphone": "ヘッドホン", "playback": "再生", "output": "出力", "advanced": "DSD・変換"][rawValue]!
        }
    }

    var body: some View {
        let tint = model.palette.accent

        VStack(alignment: .leading, spacing: 16) {
            if model.asmrMode {
                HStack(spacing: 8) {
                    Image(systemName: "ear").foregroundStyle(tint)
                    Text("ASMR モード中は、ステレオのまま再生するため EQ・ヘッドホンの補正・速度・キー・バランスはオフになっています（設定は残っています）。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("モードを終了") { model.asmrMode = false }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
            } else if model.bitPerfect {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal").foregroundStyle(tint)
                    Text("ビットパーフェクト再生中は、元のデータのまま出力するため EQ・ヘッドホンの補正・速度・キー・バランス・クロスフェード・音量の均一化はオフになっています（設定は残っています）。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("解除") { model.setBitPerfect(false) }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
            }

            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .accessibilityLabel("設定の種類")

            switch tab {
            case .equalizer: EqualizerTab(tint: tint)
            case .headphone: HeadphoneTab(tint: tint)
            case .playback: PlaybackTab(tint: tint)
            case .output: OutputTab(tint: tint)
            case .advanced: AdvancedTab(tint: tint)
            }
        }
        .padding(20)
        .frame(width: 540)
        .tint(tint)
    }
}

private func settingLabel(_ text: String, _ symbol: String) -> some View {
    Label(text, systemImage: symbol).font(.callout).frame(width: 130, alignment: .leading)
}

private func valueText(_ s: String) -> some View {
    Text(s).font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
}

private func note(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}

// MARK: - イコライザー (10 バンド)

private struct EqualizerTab: View {
    @Environment(PlayerModel.self) private var model
    let tint: Color
    private static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("イコライザー").font(.headline)
                Spacer()
                Menu(model.eqPresetName) {
                    ForEach(EQPreset.all) { p in Button(p.name) { model.applyPreset(p) } }
                }
                .fixedSize()
                Toggle("", isOn: $m.eqEnabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .accessibilityLabel("イコライザー")
            }
            .disabled(model.effectsOff)

            HStack(alignment: .bottom, spacing: 0) {
                band(label: "PRE", value: $m.eqPreamp, tint: .white.opacity(0.8))
                Rectangle().fill(.white.opacity(0.12)).frame(width: 1).padding(.vertical, 18).padding(.horizontal, 6)
                ForEach(0..<10, id: \.self) { i in
                    band(label: Self.labels[i], value: Binding(
                        get: { model.eqBands[i] },
                        set: { model.eqBands[i] = $0; model.eqPresetName = "カスタム" }
                    ), tint: tint)
                }
            }
            .frame(height: 176)
            .frame(maxWidth: .infinity)
            .opacity(model.eqEnabled && !model.effectsOff ? 1 : 0.35)
            .disabled(!model.eqEnabled || model.effectsOff)

            HStack {
                note("ダブルクリックで各バンドを 0 に戻せます。すべて 0 のときは処理を通さず、元の音のまま出力します。")
                Spacer()
                Button("フラットに戻す") {
                    model.applyPreset(EQPreset.all[0])
                    model.eqPreamp = 0
                }
                .controlSize(.small)
            }
        }
    }

    private func band(label: String, value: Binding<Float>, tint: Color) -> some View {
        VStack(spacing: 6) {
            Text(value.wrappedValue == 0 ? "0" : String(format: "%+.1f", value.wrappedValue))
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            EQSlider(value: value, tint: tint)
            Text(label).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
        }
        .frame(width: 38)
    }
}

// MARK: - ヘッドホン (パラメトリック EQ・クロスフィード)

private struct HeadphoneTab: View {
    @Environment(PlayerModel.self) private var model
    let tint: Color

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("パラメトリック EQ").font(.headline)
                Spacer()
                Menu(model.activeProfile?.name ?? "使わない") {
                    Button { model.activeProfileID = nil } label: {
                        if model.activeProfileID == nil { Label("使わない", systemImage: "checkmark") } else { Text("使わない") }
                    }
                    if !model.eqProfiles.isEmpty { Divider() }
                    ForEach(model.eqProfiles) { p in
                        Button { model.activeProfileID = p.id } label: {
                            if model.activeProfileID == p.id { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                        }
                    }
                }
                .fixedSize()
                .accessibilityLabel("パラメトリック EQ の設定")
                Button("読み込む…") { importFile() }
                    .controlSize(.small)
                    .help("AutoEQ の ParametricEQ.txt（Equalizer APO 形式）を読み込みます")
                Button("新規") {
                    model.addProfile(EQProfile(name: "新しい設定", bands: [ParametricBand()]))
                }
                .controlSize(.small)
            }

            if let profile = model.activeProfile {
                ProfileEditor(profile: profile, tint: tint)
            } else {
                note("ヘッドホンやスピーカーの特性を補正するための EQ です。周波数・ゲイン・Q を自由に決められるバンドを 15 個まで使えます。AutoEQ が公開しているヘッドホンごとの補正（ParametricEQ.txt）をそのまま読み込めます。")
            }
            note("選んだ設定は、今の出力デバイスに結び付けて覚えます。出力デバイスを切り替えると、そのデバイスで最後に使っていた設定に変わります。")

            Divider().opacity(0.4)

            HStack {
                Label("クロスフィード", systemImage: "ear").font(.callout)
                Spacer()
                Picker("", selection: $m.crossfeed) {
                    ForEach(CrossfeedLevel.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                .accessibilityLabel("クロスフィード")
            }
            note("ヘッドホンで聴くと、左の音は左耳にしか届きません。スピーカーのように、反対側の耳にも低音を中心に少しだけ音を回して、頭の中で左右に張り付く感じを和らげます。")
        }
        .disabled(model.effectsOff)
        .opacity(model.effectsOff ? 0.45 : 1)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.message = "AutoEQ の ParametricEQ.txt（Equalizer APO 形式）を選んでください"
        panel.prompt = "読み込む"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in PlayerModel.shared.importAutoEQ(from: url) }
        }
    }
}

/// パラメトリック EQ の 1 つの設定を編集する
private struct ProfileEditor: View {
    @Environment(PlayerModel.self) private var model
    let profile: EQProfile
    let tint: Color

    private var binding: Binding<EQProfile> {
        Binding(get: { model.activeProfile ?? profile }, set: { model.updateProfile($0) })
    }

    var body: some View {
        let p = binding
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("名前", text: p.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                Spacer()
                Button(role: .destructive) { model.removeProfile(profile.id) } label: { Image(systemName: "trash") }
                    .controlSize(.small)
                    .help("この設定を削除")
                    .accessibilityLabel("この設定を削除")
            }

            ResponseCurve(profile: p.wrappedValue, sampleRate: model.engine.chainSampleRate, tint: tint)
                .frame(height: 96)

            HStack(spacing: 8) {
                Text("プリアンプ").font(.callout)
                Slider(value: p.preamp, in: -20...6, step: 0.1)
                Text(String(format: "%+.1f dB", p.wrappedValue.preamp)).font(.callout.monospacedDigit()).frame(width: 64, alignment: .trailing)
                Button("自動") {
                    var edited = p.wrappedValue
                    edited.preamp = -max(0, (EQDesign.peakGain(of: edited, sampleRate: model.engine.chainSampleRate) * 10).rounded(.up) / 10)
                    model.updateProfile(edited)
                }
                .controlSize(.small)
                .help("持ち上げているバンドの分だけ全体を下げて、音が割れないようにします")
            }

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(p.bands) { band in
                        BandRow(band: band) { id in
                            var edited = p.wrappedValue
                            edited.bands.removeAll { $0.id == id }
                            model.updateProfile(edited)
                        }
                    }
                }
            }
            .frame(maxHeight: 168)
            .fixedSize(horizontal: false, vertical: p.wrappedValue.bands.count <= 5)

            Button {
                var edited = p.wrappedValue
                edited.bands.append(ParametricBand())
                model.updateProfile(edited)
            } label: {
                Label("バンドを追加", systemImage: "plus")
            }
            .controlSize(.small)
            .disabled(p.wrappedValue.bands.count >= ASMRShared.eqBands - 1)
        }
    }
}

private struct BandRow: View {
    @Binding var band: ParametricBand
    let remove: (UUID) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: $band.enabled).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel("このバンドを使う")
            Picker("", selection: $band.kind) {
                ForEach(ParametricBand.Kind.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().frame(width: 118)
            .accessibilityLabel("種類")
            field("Hz", $band.frequency, width: 64, format: "%.0f")
            field("dB", $band.gain, width: 52, format: "%+.1f").disabled(!band.kind.hasGain).opacity(band.kind.hasGain ? 1 : 0.35)
            field("Q", $band.q, width: 48, format: "%.2f")
            Spacer(minLength: 0)
            Button { remove(band.id) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("このバンドを削除")
                .accessibilityLabel("このバンドを削除")
        }
        .font(.callout)
        .opacity(band.enabled ? 1 : 0.5)
    }

    private func field(_ unit: String, _ value: Binding<Double>, width: CGFloat, format: String) -> some View {
        HStack(spacing: 3) {
            TextField(unit, value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .accessibilityLabel(unit)
            Text(unit).font(.caption).foregroundStyle(.secondary).frame(width: 18, alignment: .leading)
        }
    }
}

/// パラメトリック EQ 全体の周波数特性 (20Hz〜20kHz、±15dB)
private struct ResponseCurve: View {
    let profile: EQProfile
    let sampleRate: Double
    let tint: Color

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let range = 15.0
            func x(_ f: Double) -> CGFloat { w * CGFloat(log(f / 20) / log(1000)) }
            func y(_ db: Double) -> CGFloat { h / 2 - CGFloat(max(-range, min(range, db)) / range) * (h / 2 - 2) }
            // 目盛り
            for f in [100.0, 1000, 10000] {
                ctx.fill(Path(CGRect(x: x(f), y: 0, width: 0.5, height: h)), with: .color(.white.opacity(0.12)))
            }
            ctx.fill(Path(CGRect(x: 0, y: h / 2, width: w, height: 0.5)), with: .color(.white.opacity(0.25)))
            var curve = Path()
            let steps = 160
            for i in 0...steps {
                let f = 20 * pow(1000, Double(i) / Double(steps))
                let point = CGPoint(x: x(f), y: y(EQDesign.response(of: profile, at: min(f, sampleRate * 0.48), sampleRate: sampleRate)))
                if i == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            }
            var area = curve
            area.addLine(to: CGPoint(x: w, y: h / 2))
            area.addLine(to: CGPoint(x: 0, y: h / 2))
            area.closeSubpath()
            ctx.fill(area, with: .color(tint.opacity(0.18)))
            ctx.stroke(curve, with: .color(tint), lineWidth: 1.6)
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.05)))
        .overlay {
            // 目盛りの数字は、それぞれの線の位置に置く
            GeometryReader { g in
                ForEach([(100.0, "100Hz"), (1000, "1kHz"), (10000, "10kHz")], id: \.0) { frequency, label in
                    Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                        .position(x: g.size.width * CGFloat(log(frequency / 20) / log(1000)) + 17, y: g.size.height - 8)
                }
                Text("+15").font(.system(size: 9)).foregroundStyle(.secondary).position(x: 14, y: 8)
                Text("-15 dB").font(.system(size: 9)).foregroundStyle(.secondary).position(x: 20, y: g.size.height - 8)
            }
        }
        .accessibilityLabel("周波数特性のグラフ")
    }
}

// MARK: - 再生

private struct PlaybackTab: View {
    @Environment(PlayerModel.self) private var model
    let tint: Color

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 14) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                Group {
                    GridRow {
                        settingLabel("速度", "gauge.with.dots.needle.67percent")
                        Slider(value: $m.rate, in: 0.5...2.0, step: 0.05).frame(maxWidth: .infinity)
                        valueText(rateLabel(model.rate)).onTapGesture(count: 2) { model.rate = 1 }
                    }
                    GridRow {
                        settingLabel("キー", "music.quarternote.3")
                        Slider(value: $m.pitch, in: -12...12, step: 1)
                        valueText(model.pitch == 0 ? "±0" : String(format: "%+.0f", model.pitch)).onTapGesture(count: 2) { model.pitch = 0 }
                    }
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        Toggle("速度を変えても音程を保つ", isOn: $m.preservePitch).font(.callout).gridCellColumns(2)
                    }
                    GridRow {
                        settingLabel("バランス", "slider.horizontal.below.rectangle")
                        Slider(value: $m.balance, in: -1...1)
                        valueText(balanceLabel).onTapGesture(count: 2) { model.balance = 0 }
                    }
                }
                .disabled(model.effectsOff)
                .opacity(model.effectsOff ? 0.4 : 1)
                Group {
                    GridRow {
                        settingLabel("クロスフェード", "wave.3.right")
                        Slider(value: $m.crossfade, in: 0...12, step: 0.5)
                        valueText(model.crossfade == 0 ? "オフ" : String(format: "%.1f秒", model.crossfade))
                    }
                    GridRow {
                        settingLabel("音量の均一化", "speaker.wave.2")
                        Picker("", selection: $m.replayGain) {
                            ForEach(ReplayGainMode.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented).labelsHidden().gridCellColumns(2)
                        .accessibilityLabel("音量の均一化")
                    }
                }
                .disabled(model.bitPerfect)
                .opacity(model.bitPerfect ? 0.4 : 1)
            }

            Toggle(isOn: $m.loudnessScan) {
                Text("タグのない曲は、大きさを測ってそろえる").font(.callout)
            }
            .disabled(model.replayGain == .off || model.bitPerfect)
            note("ReplayGain タグのない曲を、放送の基準と同じ測り方（EBU R128）で測り、-18 LUFS にそろえます。測った結果は保存され、次からはすぐに使われます。ASMR モードでは、音量のならしに任せるので使いません。")

            Toggle(isOn: $m.clipGuard) {
                Text("クリップ防止").font(.callout)
            }
            .disabled(model.bitPerfect)
            note("EQ・クロスフィード・速度の変更などで音が 0 dBFS を超えそうなときだけ、先読みして歪まないように抑えます。何も加工していないときは働かず、元の音を 1 ビットも変えません。")

            HStack {
                note("速度・キー・バランスは、値をダブルクリックすると元に戻ります。")
                Spacer()
                Button("すべてリセット") {
                    model.rate = 1
                    model.pitch = 0
                    model.balance = 0
                }
                .controlSize(.small)
            }
        }
    }

    private var balanceLabel: String {
        let b = model.balance
        if abs(b) < 0.02 { return "中央" }
        return b < 0 ? "L \(Int(-b * 100))" : "R \(Int(b * 100))"
    }
}

// MARK: - 出力

private struct OutputTab: View {
    @Environment(PlayerModel.self) private var model
    let tint: Color

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("出力デバイス", systemImage: "hifispeaker.2").font(.callout)
                Spacer()
                Picker("", selection: Binding(
                    get: { model.outputDeviceUID ?? "" },
                    set: { uid in model.selectOutputDevice(model.outputDevices.first { $0.uid == uid }) }
                )) {
                    Text("システム設定に従う").tag("")
                    ForEach(model.outputDevices) { Text($0.name).tag($0.uid) }
                }
                .labelsHidden().fixedSize()
                .accessibilityLabel("出力デバイス")
            }

            HStack(spacing: 10) {
                Image(systemName: model.bitPerfect ? "checkmark.seal.fill" : "checkmark.seal")
                    .font(.system(size: 20)).foregroundStyle(model.bitPerfect ? tint : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("ビットパーフェクト再生").font(.callout.weight(.semibold))
                    note("音を変える処理をすべて外し、デバイスの形式を曲に合わせて、元のデータのまま出力します。")
                }
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { model.bitPerfect }, set: { model.setBitPerfect($0) }))
                    .toggleStyle(.switch).labelsHidden()
                    .accessibilityLabel("ビットパーフェクト再生")
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(model.bitPerfect ? tint.opacity(0.14) : .white.opacity(0.05)))
            .help("⇧⌘B でも切り替えられます")
            if let reason = model.bitPerfectShortfall {
                Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.bitPerfect {
                note(model.volumeLocked
                     ? "EQ などの設定は残っているので、オフにすれば元に戻ります。このデバイスの音量は Mac から変えられないので、アンプなどデバイス側で調整してください。"
                     : "EQ などの設定は残っているので、オフにすれば元に戻ります。音量スライダーは、アプリの音量の代わりに出力デバイス側の音量を動かします。")
            }

            SignalPathView(tint: tint)

            Divider().opacity(0.4)

            Toggle(isOn: Binding(get: { model.matchSampleRate || model.bitPerfect }, set: { model.matchSampleRate = $0 })) {
                Text("デバイスのサンプルレートとビット深度を曲に合わせる").font(.callout)
            }
            .disabled(model.bitPerfect)
            note("曲ごとに、出力デバイスを曲と同じサンプルレート（なければその整数倍）へ切り替えます。デバイスが 16bit になっていて曲が 24bit のときなどは、ビット深度も上げます。合えばサンプルレートの変換もビットの切り捨ても入らず、元のデータのまま出力できます。形式の違う曲へ移るときは、切り替えのために一瞬途切れます。終了時には元の形式に戻します。")

            HStack(spacing: 8) {
                Toggle(isOn: $m.exclusiveMode) {
                    Text("排他モード（このアプリだけがデバイスを使う）").font(.callout)
                }
                .disabled(model.switchingExclusive)
                if model.switchingExclusive { ProgressView().controlSize(.small) }
            }
            note("ほかのアプリや通知の音が混ざらなくなります。オンの間、ほかのアプリはこのデバイスで音を出せません。切り替えには 1 秒ほどかかり、その間は音が途切れます。排他モード中は、別のデバイスをつないでも音はこのデバイスから出続けます（変えるときは、上で出力デバイスを選び直してください）。")
        }
    }
}

// MARK: - DSD・変換 (アップサンプリングと、DSD のネイティブ再生)

private struct AdvancedTab: View {
    @Environment(PlayerModel.self) private var model
    let tint: Color

    var body: some View {
        @Bindable var m = model
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("アップサンプリング", systemImage: "arrow.up.right.circle").font(.callout)
                Spacer()
                Picker("", selection: $m.upsampling) {
                    ForEach(Upsampling.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 240)
                .accessibilityLabel("アップサンプリング")
            }
            .disabled(model.bitPerfect)
            .opacity(model.bitPerfect ? 0.45 : 1)
            note("出力デバイスを曲の 2 倍・4 倍…のサンプルレート（44.1kHz の曲なら 88.2 / 176.4 / 352.8kHz）に切り替え、Mac の側で変換してから送ります。変換は 21kHz まで平坦で、折り返しの成分は -170dB 以下です。「最大」は、デバイスが対応しているいちばん高い倍率まで上げます。" + (model.bitPerfect ? "ビットパーフェクト再生中は、元のデータのまま送るので使いません。" : ""))

            Divider().opacity(0.4)

            Toggle(isOn: $m.dopEnabled) {
                Label("DSD をそのまま送る（DoP）", systemImage: "shippingbox").font(.callout)
            }
            note("DSD の曲を PCM に変換せず、DSD のまま DAC へ送ります。送るのは、対応を確かめた DAC で、ビットパーフェクト再生と排他モードがどちらもオンのときだけです。送っている間は、音量・EQ・フェードなどの加工を一切通しません（1 ビットでも変わると雑音になるため）。条件がそろわないときは、これまでどおり PCM に変換して再生します。")

            DoPDeviceSection(tint: tint)
        }
    }
}

/// 今の出力デバイスが DoP に対応しているかの表示と、確かめる手順
private struct DoPDeviceSection: View {
    @Environment(PlayerModel.self) private var model
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: statusSymbol).foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.engine.outputInfo.name).font(.callout.weight(.semibold))
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if model.dopCheck == nil {
                    if model.dopSupport != nil {
                        Button("確認結果を消す") { model.forgetDoPSupport() }.controlSize(.small)
                    }
                    Button(model.dopSupport == nil ? "確かめる…" : "もう一度確かめる…") { model.beginDoPCheck() }
                        .controlSize(.small)
                        .disabled(model.dopCheckBlocker != nil)
                }
            }
            if model.dopCheck == nil, let blocker = model.dopCheckBlocker {
                note(blocker)
            }
            if let check = model.dopCheck {
                Divider().opacity(0.4)
                checkPanel(check)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
        .onDisappear { model.endDoPCheck() }
    }

    private var statusText: String {
        switch model.dopSupport {
        case nil: "DoP に対応しているか、まだ確かめていません（確かめるまでは送りません）"
        case .verified: "DoP に対応していることを確認済み"
        case .verifiedAtFullVolume: "DoP に対応（DAC の音量が最大のときだけ送ります）"
        case .unsupported: "DoP に対応していません（PCM に変換して再生します）"
        }
    }

    private var statusSymbol: String {
        switch model.dopSupport {
        case nil: "questionmark.circle"
        case .verified, .verifiedAtFullVolume: "checkmark.circle.fill"
        case .unsupported: "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch model.dopSupport {
        case .verified, .verifiedAtFullVolume: tint
        default: .secondary
        }
    }

    @ViewBuilder
    private func checkPanel(_ check: DoPCheck) -> some View {
        switch check.step {
        case .quiet, .full:
            Text(check.step == .quiet ? "小さい音量で、確認用の音を鳴らします" : "DAC の音量を最大にして、確認用の音を鳴らします")
                .font(.callout.weight(.semibold))
            note(instruction(check))
            HStack(spacing: 8) {
                Button { model.playDoPCheckTone() } label: { Label(check.playing ? "鳴らしています…" : "鳴らす", systemImage: "play.fill") }
                    .disabled(check.playing)
                if check.step == .quiet, check.originalVolume != nil {
                    Button("少し大きく") { model.raiseDoPCheckVolume() }.disabled(!model.canRaiseDoPCheckVolume)
                }
                Spacer()
                Button("やめる") { model.endDoPCheck() }
            }
            .controlSize(.small)
            if let message = check.message {
                Label(message, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("どう聞こえましたか？").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("澄んだ「ポー」という音") { model.answerDoPCheck(.clean) }
                Button("ザーという雑音") { model.answerDoPCheck(.noise) }
                Button("何も聞こえない") { model.answerDoPCheck(.nothing) }
            }
            .controlSize(.small)
        case .askFull:
            Text("小さい音量では、DSD として再生されませんでした").font(.callout.weight(.semibold))
            note("DAC が DoP に対応していないか、音量を下げると DoP が通らなくなる DAC です。後者なら、DAC の音量を最大にすると再生できます。アンプやヘッドホンの側で音量を十分に下げられる場合だけ、音量を下げてから試してください（対応していなければ、最大の音量で雑音が出ます）。")
            HStack(spacing: 8) {
                Button("DAC の音量を最大にして試す") { model.retryDoPCheckAtFullVolume() }
                Button("対応していないとして終える") { model.giveUpDoPCheck() }
            }
            .controlSize(.small)
        case .done(let result):
            Text(resultTitle(result)).font(.callout.weight(.semibold))
            note(resultDetail(result))
            Button("閉じる") { model.endDoPCheck() }.controlSize(.small)
        }
    }

    private func instruction(_ check: DoPCheck) -> String {
        let tone = "「ポー」という音が 4 回鳴ります。対応していない DAC では、ザーという雑音になります。"
        if check.step == .full {
            return "アンプやヘッドホンの音量を絞ってから、鳴らしてください。" + tone
        }
        return check.originalVolume == nil
            ? "この DAC の音量は Mac から変えられません。アンプやヘッドホンの音量をいちばん小さくしてから鳴らし、聞こえなければ少しずつ上げてください。" + tone
            : "DAC の音量を 30dB 下げてあります（終わったら元に戻します）。聞こえなければ「少し大きく」で上げてください。" + tone
    }

    private func resultTitle(_ result: DoP.Support) -> String {
        switch result {
        case .verified: "この DAC は DoP に対応しています"
        case .verifiedAtFullVolume: "この DAC は、音量が最大のときだけ DoP に対応しています"
        case .unsupported: "この DAC には DoP を送りません"
        }
    }

    private func resultDetail(_ result: DoP.Support) -> String {
        switch result {
        case .verified: "ビットパーフェクト再生と排他モードがオンのとき、DSD の曲をそのまま送ります。音量は元に戻しました。"
        case .verifiedAtFullVolume: "DAC の音量が最大のときだけ、DSD の曲をそのまま送ります。音量はアンプ側で調整してください（DSD を送っている間は、音量スライダーを動かせません）。DAC の音量は、確認前の値に戻しました。"
        case .unsupported: "DSD の曲は、これまでどおり PCM に変換して再生します。音量は元に戻しました。"
        }
    }
}

/// 音が出力までにたどる道筋
struct SignalPathView: View {
    @Environment(PlayerModel.self) private var model
    let tint: Color

    var body: some View {
        if let path = model.signalPath {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("シグナルパス").font(.callout.weight(.semibold))
                    Spacer()
                    Text(path.quality.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(path.quality.isPure ? .black.opacity(0.8) : .white.opacity(0.85))
                        .padding(.horizontal, 9).padding(.vertical, 3.5)
                        .background(Capsule().fill(path.quality.isPure ? tint : .white.opacity(0.12)))
                }
                .padding(.bottom, 8)
                step("doc.badge.gearshape", "音源", path.source, first: true)
                ForEach(path.stages) { stage in step(stage.symbol, stage.name, stage.detail) }
                step("hifispeaker", "出力", path.output, last: true)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
            .accessibilityElement(children: .combine)
        } else {
            note("曲を再生すると、音源から出力までの道筋がここに出ます。")
        }
    }

    private func step(_ symbol: String, _ name: String, _ detail: String, first: Bool = false, last: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Rectangle().fill(.white.opacity(first ? 0 : 0.2)).frame(width: 1, height: 5)
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(tint).frame(width: 18, height: 16)
                Rectangle().fill(.white.opacity(last ? 0 : 0.2)).frame(width: 1, height: 5)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.callout)
                Spacer()
                Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            .padding(.top, 4)
        }
    }
}
