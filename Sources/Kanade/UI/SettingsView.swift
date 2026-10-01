import SwiftUI

struct SettingsView: View {
    @Environment(PlayerModel.self) private var model
    @State private var ffmpegDir = FFmpeg.customDirectory ?? ""
    @State private var cacheSize: Int64 = 0
    @State private var downloadedArtwork = 0

    var body: some View {
        @Bindable var m = model
        Form {
            Section("再生") {
                Picker("プレイヤーの見た目", selection: $m.skin) {
                    ForEach(PlayerSkin.allCases) { Text($0.label).tag($0) }
                }
                Picker("ビジュアライザー", selection: $m.visualizer) {
                    ForEach(VisualizerStyle.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("クロスフェード") {
                    HStack {
                        Slider(value: $m.crossfade, in: 0...12, step: 0.5).frame(width: 180)
                        Text(model.crossfade == 0 ? "オフ（ギャップレス）" : String(format: "%.1f 秒", model.crossfade))
                            .monospacedDigit().frame(width: 120, alignment: .leading)
                    }
                }
                Picker("音量の均一化 (ReplayGain)", selection: $m.replayGain) {
                    ForEach(ReplayGainMode.allCases) { Text($0.label).tag($0) }
                }
                Picker("出力デバイス", selection: Binding(
                    get: { model.outputDeviceUID ?? "" },
                    set: { uid in model.selectOutputDevice(model.outputDevices.first { $0.uid == uid }) }
                )) {
                    Text("システム設定に従う").tag("")
                    ForEach(model.outputDevices) { Text($0.name).tag($0.uid) }
                }
            }

            Section {
                Toggle("DLsite から作品画像を取得する", isOn: $m.dlsiteArtwork)
                Toggle("DLsite から声優名とサークル名を取得する", isOn: $m.dlsiteInfo)
                LabeledContent("取得した画像") {
                    HStack {
                        Text("\(downloadedArtwork) 件").monospacedDigit()
                        Button("消去") {
                            ArtworkStore.shared.clearDownloads()
                            downloadedArtwork = 0
                        }
                        .disabled(downloadedArtwork == 0)
                    }
                }
            } header: {
                Text("DLsite の作品")
            } footer: {
                Text("フォルダ名やファイル名に作品番号（RJ01234567 など）がある曲で、DLsite に問い合わせます。オンにすると、その作品番号が DLsite のサーバーに送られます。\n・作品画像: 音源に画像がなく、作品のフォルダにも見つからないときに、保存して使います。再生画面に画像をドロップすると、アートワークを自分で指定できます（こちらは通信しません）。\n・声優名とサークル名: タグが空のときだけ、アーティストに声優名、アルバムアーティストにサークル名を入れます（タグに書いてある名前は変えません）。ライブラリの「アーティスト」は、サークルごとに並びます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("ffmpeg") {
                    if let path = FFmpeg.ffmpeg {
                        Label(path, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("見つかりません", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                TextField("ffmpeg のあるフォルダ (空欄で自動検出)", text: $ffmpegDir)
                    .onSubmit { FFmpeg.customDirectory = ffmpegDir }
                LabeledContent("変換キャッシュ") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)).monospacedDigit()
                        Button("消去") {
                            FFmpeg.clearCache()
                            cacheSize = 0
                        }
                    }
                }
            } header: {
                Text("形式の変換")
            } footer: {
                Text("macOS が直接扱えない WMA・APE・DSD・WavPack・TTA・TAK・MKA・WebM などは、ffmpeg で FLAC にロスレス変換して再生します。ffmpeg がない場合は、ターミナルで brew install ffmpeg を実行してください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding(.vertical, 8)
        .task { cacheSize = await Task.detached { FFmpeg.cacheSize() }.value }
        .task(id: ArtworkStore.shared.revision) { downloadedArtwork = ArtworkStore.shared.downloadedCount() }
        .onDisappear { FFmpeg.customDirectory = ffmpegDir }
    }
}
