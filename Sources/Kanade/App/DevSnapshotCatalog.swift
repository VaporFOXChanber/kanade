import SwiftUI

/// 開発用の書き出しで撮る画面の一覧
@MainActor
enum DevSnapshotCatalog {
    static func shots(model: PlayerModel) -> [DevSnapshotShot] {
        func tab(_ key: String, _ value: String) -> () -> Void { { UserDefaults.standard.set(value, forKey: key) } }
        var shots: [DevSnapshotShot] = []
        // 音響パネル
        for name in ["equalizer", "headphone", "playback", "output", "advanced"] {
            shots.append(DevSnapshotShot(name: "sound-\(name)", prepare: {
                tab("soundPanelTab", name)()
                if name == "headphone", model.eqProfiles.isEmpty {
                    model.addProfile(EQProfile(name: "HD 600 (例)", preamp: -5.2, bands: [
                        ParametricBand(kind: .lowShelf, frequency: 105, gain: 5.0, q: 0.7),
                        ParametricBand(kind: .peak, frequency: 150, gain: -2.1, q: 0.5),
                        ParametricBand(kind: .peak, frequency: 3300, gain: -2.6, q: 2.2),
                        ParametricBand(kind: .highShelf, frequency: 10000, gain: -3.0, q: 0.7),
                    ]))
                }
            }, view: { AnyView(SoundPanel()) }))
        }
        // DoP の対応を確かめている途中の画面 (実際の確認は始めず、表示だけ)
        let steps: [(String, DoPCheck)] = [
            ("quiet", DoPCheck(device: "preview", originalVolume: 0.7, message: "「少し大きく」を押してから、もう一度鳴らしてください")),
            ("ask-full", DoPCheck(device: "preview", originalVolume: 0.7, step: .askFull)),
            ("done", DoPCheck(device: "preview", originalVolume: 0.7, step: .done(.verified))),
        ]
        for (name, check) in steps {
            shots.append(DevSnapshotShot(name: "dop-check-\(name)", prepare: {
                tab("soundPanelTab", "advanced")()
                model.previewDoPCheck(check)
            }, view: { AnyView(SoundPanel()) }))
        }
        shots.append(DevSnapshotShot(name: "dop-check-end", prepare: { model.previewDoPCheck(nil) }, view: { nil }))
        // ビットパーフェクト再生中の音響パネル (次の ASMR パネルで ASMR モードにすると、自動で解除される)
        for name in ["output", "playback"] {
            shots.append(DevSnapshotShot(name: "sound-\(name)-bitperfect", settle: 1500, prepare: {
                tab("soundPanelTab", name)()
                model.setBitPerfect(true)
            }, view: { AnyView(SoundPanel()) }))
        }
        // ASMR パネル
        for name in ["sound", "sleep", "position"] {
            shots.append(DevSnapshotShot(name: "asmr-\(name)", prepare: {
                tab("asmrPanelTab", name)()
                model.asmrMode = true
                if name == "sound" { model.asmrStrength = .custom }
            }, view: { AnyView(ASMRPanel()) }))
        }
        // 曲の情報
        shots.append(DevSnapshotShot(name: "inspector", view: { (model.currentTrack ?? model.queue.first).map { AnyView(TrackInspector(track: $0)) } }))
        // ライブラリ (渡されたフォルダを登録してから撮る)
        let library = LibraryStore.shared
        let size = CGSize(width: 1000, height: 660)
        // 先に 1 曲だけをファイル単体で登録して撮る (次でフォルダを登録すると、フォルダのほうにまとめられる)
        shots.append(DevSnapshotShot(name: "library-single-file", size: size, settle: 2500, prepare: {
            if let last = model.queue.last { library.addSources([Importer.librarySource(for: last)]) }
        }, view: { AnyView(LibraryView(initial: .tracks)) }))
        shots.append(DevSnapshotShot(name: "library-albums", size: size, settle: 2500, prepare: {
            let folders = Set(model.queue.map { ArtworkFinder.workFolder(for: $0.url) })
            library.addSources(Array(folders))
            if library.playlists.isEmpty, !model.queue.isEmpty { model.saveQueueAsPlaylist() }
            if let first = model.queue.first, !model.isFavorite(first) { model.toggleFavorite(first) }
        }, view: { AnyView(LibraryView()) }))
        shots.append(DevSnapshotShot(name: "library-tracks", size: size, settle: 1200, view: { AnyView(LibraryView(initial: .tracks)) }))
        shots.append(DevSnapshotShot(name: "library-album", size: size, settle: 1200, view: {
            library.albums.first.map { AnyView(LibraryView(initial: .albums, openAlbum: $0.id)) }
        }))
        // メインウィンドウはガラスの効果を使っていて、この方法では撮れない (ウィンドウの画面収録で確かめる)
        return shots
    }
}
