import SwiftUI

/// イコライザーと音響効果のパネル
struct SoundPanel: View {
    @Environment(PlayerModel.self) private var model

    private static let labels = ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

    var body: some View {
        @Bindable var m = model
        let tint = model.palette.accent

        VStack(alignment: .leading, spacing: 18) {
            if model.asmrMode {
                HStack(spacing: 8) {
                    Image(systemName: "ear").foregroundStyle(tint)
                    Text("ASMR モード中は、ステレオのまま再生するため EQ・速度・キー・バランスはオフになっています（設定は残っています）。")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("モードを終了") { model.asmrMode = false }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.12)))
            }
            HStack(spacing: 10) {
                Text("イコライザー").font(.headline)
                Spacer()
                Menu(model.eqPresetName) {
                    ForEach(EQPreset.all) { p in Button(p.name) { model.applyPreset(p) } }
                }
                .fixedSize()
                Toggle("", isOn: $m.eqEnabled).toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            .disabled(model.asmrMode)

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
            .opacity(model.eqEnabled && !model.asmrMode ? 1 : 0.35)
            .disabled(!model.eqEnabled || model.asmrMode)

            Divider().opacity(0.4)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                Group {
                GridRow {
                    label("速度", "gauge.with.dots.needle.67percent")
                    Slider(value: $m.rate, in: 0.5...2.0, step: 0.05)
                    valueText(rateLabel(model.rate)).onTapGesture(count: 2) { model.rate = 1 }
                }
                GridRow {
                    label("キー", "music.quarternote.3")
                    Slider(value: $m.pitch, in: -12...12, step: 1)
                    valueText(model.pitch == 0 ? "±0" : String(format: "%+.0f", model.pitch)).onTapGesture(count: 2) { model.pitch = 0 }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Toggle("速度を変えても音程を保つ", isOn: $m.preservePitch).font(.callout).gridCellColumns(2)
                }
                GridRow {
                    label("バランス", "slider.horizontal.below.rectangle")
                    Slider(value: $m.balance, in: -1...1)
                    valueText(balanceLabel).onTapGesture(count: 2) { model.balance = 0 }
                }
                }
                .disabled(model.asmrMode)
                .opacity(model.asmrMode ? 0.4 : 1)
                GridRow {
                    label("クロスフェード", "wave.3.right")
                    Slider(value: $m.crossfade, in: 0...12, step: 0.5)
                    valueText(model.crossfade == 0 ? "オフ" : String(format: "%.1f秒", model.crossfade))
                }
                GridRow {
                    label("音量の均一化", "speaker.wave.2")
                    Picker("", selection: $m.replayGain) {
                        ForEach(ReplayGainMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().gridCellColumns(2)
                }
            }
            .tint(tint)

            HStack {
                Text("ReplayGain タグを使って曲ごとの音量差をそろえます。ダブルクリックで各値をリセット。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("すべてリセット") {
                    model.applyPreset(EQPreset.all[0])
                    model.eqPreamp = 0
                    model.rate = 1
                    model.pitch = 0
                    model.balance = 0
                }
                .controlSize(.small)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var balanceLabel: String {
        let b = model.balance
        if abs(b) < 0.02 { return "中央" }
        return b < 0 ? "L \(Int(-b * 100))" : "R \(Int(b * 100))"
    }

    private func band(label: String, value: Binding<Float>, tint: Color) -> some View {
        VStack(spacing: 6) {
            Text(value.wrappedValue == 0 ? "0" : String(format: "%+.1f", value.wrappedValue))
                .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            EQSlider(value: value, tint: tint)
            Text(label).font(.system(size: 10, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
        }
        .frame(width: 36)
    }

    private func label(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.callout).frame(width: 130, alignment: .leading)
    }

    private func valueText(_ s: String) -> some View {
        Text(s).font(.callout.monospacedDigit()).frame(width: 60, alignment: .trailing).foregroundStyle(.secondary)
    }
}
