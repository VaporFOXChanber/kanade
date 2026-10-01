import AppKit
import AVFoundation
import MediaPlayer
import Observation
import SwiftUI

@Observable
final class PlaybackClock {
    var position: Double = 0 { didSet { updateCoarse() } }
    var duration: Double = 0 { didSet { updateCoarse() } }
    /// 0〜1 の再生位置を 1/500 刻みにしたもの。テープの巻き量のように、ゆっくりとしか変わらない表示に使う
    /// (position を直接見ると 10Hz で描き直しになる)
    private(set) var coarseProgress: Double = 0

    private func updateCoarse() {
        let p = duration > 0 ? min(1, max(0, position / duration)) : 0
        let q = (p * 500).rounded() / 500
        if q != coarseProgress { coarseProgress = q }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String
}

struct EQPreset: Identifiable, Hashable {
    let name: String
    let gains: [Float]
    var id: String { name }

    static let all: [EQPreset] = [
        .init(name: "フラット", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init(name: "低音ブースト", gains: [6, 5.5, 4, 2, 0.5, 0, 0, 0, 0, 0]),
        .init(name: "高音ブースト", gains: [0, 0, 0, 0, 0, 1, 2.5, 4, 5, 6]),
        .init(name: "ボーカル", gains: [-2, -2, -1, 1, 3, 4, 3.5, 1.5, 0, -1]),
        .init(name: "ロック", gains: [5, 4, 2.5, -1, -2, -1, 2, 3, 4, 4.5]),
        .init(name: "ポップ", gains: [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2]),
        .init(name: "ジャズ", gains: [3, 2, 1, 2, -1.5, -1.5, 0, 1, 2, 3]),
        .init(name: "クラシック", gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        .init(name: "エレクトロニック", gains: [5, 4.5, 1, 0, -2, 2, 1, 1.5, 4, 5]),
        .init(name: "アコースティック", gains: [4, 4, 3, 1, 1.5, 1, 2.5, 3, 2.5, 1.5]),
        .init(name: "ラウドネス", gains: [6, 4.5, 0, 0, -2, 0, -1, -3, 4.5, 5.5]),
        .init(name: "深夜 (小音量)", gains: [5, 4, 2, 1, 0, 0, 0.5, 1.5, 3, 3.5]),
    ]
}

/// アプリ全体の再生状態。キュー、シャッフル・リピート、エンジン制御、永続化を担う。
@MainActor
@Observable
final class PlayerModel {
    static let shared = PlayerModel()

    // MARK: キュー
    private(set) var queue: [Track] = []
    var selection: Set<UUID> = []
    private(set) var currentID: UUID?
    var searchText = ""

    // MARK: 状態
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    private(set) var conversionProgress: Double?
    private(set) var failed: Set<UUID> = []
    var toast: Toast?

    // MARK: 表示
    private(set) var artwork: NSImage?
    private(set) var palette = Palette.default
    private(set) var lyrics: Lyrics?
    private(set) var waveform: [Float]?
    var showQueue = Defaults.bool("showQueue", true) { didSet { Defaults.set("showQueue", showQueue) } }
    var showLyrics = false
    var visualizer = VisualizerStyle(rawValue: Defaults.string("visualizer") ?? "") ?? .bars {
        didSet { Defaults.set("visualizer", visualizer.rawValue) }
    }
    var skin = PlayerSkin(rawValue: Defaults.string("skin") ?? "") ?? .standard { didSet { Defaults.set("skin", skin.rawValue) } }
    /// 作品番号 (RJ…) の分かる曲にアートワークがないとき、DLsite から作品画像を取得する
    var dlsiteArtwork = Defaults.bool("dlsiteArtwork", false) {
        didSet {
            Defaults.set("dlsiteArtwork", dlsiteArtwork)
            ArtworkStore.shared.downloadsEnabled = dlsiteArtwork
            ArtworkStore.shared.invalidate()
            reloadArtwork()
        }
    }

    // MARK: 再生設定
    var shuffle = Defaults.bool("shuffle", false) {
        didSet { Defaults.set("shuffle", shuffle); rebuildShuffle(); engine.invalidateUpcoming() }
    }
    var repeatMode = RepeatMode(rawValue: Defaults.string("repeat") ?? "") ?? .off {
        didSet { Defaults.set("repeat", repeatMode.rawValue); engine.invalidateUpcoming() }
    }
    var volume = Defaults.double("volume", 0.8) { didSet { Defaults.set("volume", volume); applyVolume() } }
    var muted = false { didSet { applyVolume() } }
    var rate = Defaults.double("rate", 1) { didSet { Defaults.set("rate", rate); applyRate() } }
    var pitch = Defaults.double("pitch", 0) { didSet { Defaults.set("pitch", pitch); applyRate() } }
    var preservePitch = Defaults.bool("preservePitch", true) {
        didSet { Defaults.set("preservePitch", preservePitch); engine.preservePitch = preservePitch }
    }
    var balance = Defaults.double("balance", 0) { didSet { Defaults.set("balance", balance); applyBalance() } }
    var crossfade = Defaults.double("crossfade", 0) {
        didSet { Defaults.set("crossfade", crossfade); engine.crossfadeDuration = crossfade; engine.invalidateUpcoming() }
    }
    var replayGain = ReplayGainMode(rawValue: Defaults.string("replayGain") ?? "") ?? .track {
        didSet { Defaults.set("replayGain", replayGain.rawValue) }
    }
    var eqEnabled = Defaults.bool("eqEnabled", true) { didSet { Defaults.set("eqEnabled", eqEnabled); applyEQ() } }
    var eqBands: [Float] = (Defaults.array("eqBands") as? [Double])?.map(Float.init) ?? Array(repeating: 0, count: 10) {
        didSet { Defaults.set("eqBands", eqBands.map(Double.init)); applyEQ() }
    }
    var eqPreamp = Float(Defaults.double("eqPreamp", 0)) { didSet { Defaults.set("eqPreamp", Double(eqPreamp)); applyEQ() } }
    var eqPresetName = Defaults.string("eqPreset") ?? "フラット" { didSet { Defaults.set("eqPreset", eqPresetName) } }

    // MARK: ASMR モード
    /// 小さい音を持ち上げ大きい音を抑え、急な大音量を止める。EQ・バランス・速度・キーは無効にしてステレオのまま再生する
    var asmrMode = Defaults.bool("asmrMode", false) {
        didSet {
            Defaults.set("asmrMode", asmrMode)
            applyEQ()
            applyRate()
            applyBalance()
            applyASMR()
            applyPowerSaving()
            showToast(asmrMode ? "ASMR モード: EQ・バランス・速度はオフ、ステレオのまま再生します" : "ASMR モードを終了しました",
                      symbol: asmrMode ? "ear" : "ear.badge.checkmark")
        }
    }
    var asmrStrength = ASMRStrength(rawValue: Defaults.string("asmrStrength") ?? "") ?? .standard {
        didSet { Defaults.set("asmrStrength", asmrStrength.rawValue); applyASMR() }
    }
    /// 高音の刺さりをやわらげる
    var asmrSoftening = ASMRSoftening(rawValue: Defaults.string("asmrSoftening") ?? "") ?? .off {
        didSet { Defaults.set("asmrSoftening", asmrSoftening.rawValue); applyASMR() }
    }
    /// 小音量時のラウドネス補正
    var asmrLoudness = Defaults.bool("asmrLoudness", true) { didSet { Defaults.set("asmrLoudness", asmrLoudness); applyASMR() } }
    /// 左右の入れ替え (ASMR モード中だけ効く)
    var swapChannels = Defaults.bool("swapChannels", false) { didSet { Defaults.set("swapChannels", swapChannels); applyASMR() } }
    /// 省電力表示 (ASMR モード中だけ効く): アニメーションと解析を止め、表示の更新を 1 秒ごとにする
    var lowPowerDisplay = Defaults.bool("lowPowerDisplay", true) {
        didSet { Defaults.set("lowPowerDisplay", lowPowerDisplay); applyPowerSaving() }
    }
    /// ASMR モードのスリープタイマーのフェードアウトの長さ (秒)
    var asmrSleepFade = Defaults.double("asmrSleepFade", 180) { didSet { Defaults.set("asmrSleepFade", asmrSleepFade) } }
    /// 長い音源を途中まで聴いていたら、次は続きから再生する (ASMR モード中だけ効く)
    var asmrResume = Defaults.bool("asmrResume", true) { didSet { Defaults.set("asmrResume", asmrResume) } }

    var powerSaving: Bool { asmrMode && lowPowerDisplay }
    /// 実際に再生している速さ (ASMR モード中は常に等速)
    var effectiveRate: Double { asmrMode ? 1 : rate }
    var sleepFadeDuration: Double { asmrMode ? asmrSleepFade : 12 }

    /// 小音量時のラウドネス補正量 (低域 dB, 高域 dB)。音量を下げるほど聞こえにくくなる低音・高音を補う
    var loudnessBoost: (low: Float, high: Float) {
        guard asmrMode, asmrLoudness else { return (0, 0) }
        let attenuation = Float(40 * log10(max(volume, 0.01)))   // 出力は volume² なので 40log
        return (min(9, max(0, -attenuation * 0.3)), min(3.5, max(0, -attenuation * 0.1)))
    }

    // しおり
    private(set) var bookmarks: [String: [Bookmark]] = [:]

    // A-B リピート (区間ループ)
    private(set) var loopA: Double?
    private(set) var loopB: Double?
    // スリープタイマー
    private(set) var sleepDeadline: Date?
    private(set) var sleepAtTrackEnd = false
    /// 前回、スリープタイマーで止まったときにタイマーをセットしていた位置 (最後に起きていた位置)
    private(set) var lastSleepPoint: SleepPoint? = Defaults.data("lastSleepPoint").flatMap { try? JSONDecoder().decode(SleepPoint.self, from: $0) } {
        didSet { Defaults.set("lastSleepPoint", lastSleepPoint.flatMap { try? JSONEncoder().encode($0) }) }
    }
    /// 動いているタイマーをセットした位置 (タイマーで止まったら lastSleepPoint になる)
    private var pendingSleepPoint: SleepPoint?
    /// 続きから再生するための位置の記録
    private var resumeStore = ResumeStore()
    // 出力デバイス
    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var outputDeviceUID = Defaults.string("outputDevice")

    let clock = PlaybackClock()
    let engine = AudioEngine()

    // MARK: 内部
    private var shuffleOrder: [UUID] = []
    private var playable: [URL: URL] = [:]
    private var conversions: [URL: Task<URL, Error>] = [:]
    private var peaksCache: [URL: [Float]] = [:]
    private var loadToken = UUID()
    private var resumePosition: Double?
    private var consecutiveFailures = 0
    private var pendingMeta: [UUID] = []
    private var metaInFlight: Set<URL> = []
    private var metaBuffer: [URL: TrackMeta] = [:]
    private var metaFlushScheduled = false
    private var saveTask: Task<Void, Never>?
    private var waveformTask: Task<Void, Never>?
    private var presentToken = UUID()
    private var lastNowPlayingSync: Double = 0
    private var lastClockPublish: CFTimeInterval = 0

    private init() {
        engine.volume = Float(volume)
        engine.preservePitch = preservePitch
        engine.crossfadeDuration = crossfade
        applyRate()
        applyBalance()
        applyEQ()
        applyASMR()
        applyPowerSaving()
        bookmarks = BookmarkStore.load(from: Self.supportDirectory)
        resumeStore = ResumeStore.load(from: Self.supportDirectory)

        engine.provideNext = { [weak self] in MainActor.assumeIsolated { self?.readyNextItem() } }
        engine.onAdvance = { [weak self] id in MainActor.assumeIsolated { self?.didAdvance(to: id) } }
        engine.onFinished = { [weak self] in MainActor.assumeIsolated { self?.didFinish() } }
        engine.onTick = { [weak self] pos, dur in MainActor.assumeIsolated { self?.tick(pos, dur) } }
        engine.onConfigurationChange = { [weak self] in MainActor.assumeIsolated { self?.reloadAfterDeviceChange() } }

        refreshOutputDevices()
        if let uid = outputDeviceUID, let d = outputDevices.first(where: { $0.uid == uid }) {
            engine.setOutputDevice(d.id)
        }
        setupRemoteCommands()
        restore()
    }

    // MARK: - 参照

    var currentTrack: Track? { currentID.flatMap(track) }
    func track(_ id: UUID?) -> Track? { id.flatMap { id in queue.first { $0.id == id } } }
    var totalDuration: Double { queue.reduce(0) { $0 + ($1.duration ?? 0) } }

    var filteredQueue: [Track] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return queue }
        return queue.filter {
            [$0.displayTitle, $0.displayArtist, $0.meta.album ?? "", $0.fileName].contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }

    private var playOrder: [UUID] { shuffle ? shuffleOrder : queue.map(\.id) }

    func nextTrack(after id: UUID?, auto: Bool) -> Track? {
        guard !queue.isEmpty else { return nil }
        guard let id else { return track(playOrder.first) }
        if auto, repeatMode == .one { return track(id) }
        let order = playOrder
        guard let i = order.firstIndex(of: id) else { return queue.first }
        if i + 1 < order.count { return track(order[i + 1]) }
        return repeatMode == .off ? nil : track(order.first)
    }

    func previousTrack(before id: UUID?) -> Track? {
        let order = playOrder
        guard let id, let i = order.firstIndex(of: id) else { return nil }
        if i > 0 { return track(order[i - 1]) }
        return repeatMode == .off ? nil : track(order.last)
    }

    // MARK: - キュー操作

    func open(_ urls: [URL], playFirst: Bool = true) {
        add(urls, at: nil, play: playFirst)
    }

    func add(_ urls: [URL], at index: Int? = nil, play: Bool = false) {
        // 画像だけを渡されたら、曲の追加ではなく、今の作品のアートワークの指定として扱う
        if !urls.isEmpty, urls.allSatisfy({ Importer.imageExtensions.contains($0.pathExtension.lowercased()) }) {
            setCustomArtwork(from: urls[0])
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { Importer.expand(urls) }.value
            if result.tracks.isEmpty {
                showToast(result.skipped > 0 ? "再生できるファイルが見つかりませんでした" : "追加する曲がありません", symbol: "exclamationmark.triangle")
                return
            }
            insert(result.tracks, at: index, play: play || (currentID == nil && !isPlaying))
            let n = result.tracks.count
            showToast(result.skipped > 0 ? "\(n) 曲を追加（\(result.skipped) 件は対象外）" : "\(n) 曲を追加しました", symbol: "plus.circle")
        }
    }

    func insert(_ tracks: [Track], at index: Int?, play: Bool) {
        preservingNext {
            let i = min(index ?? queue.count, queue.count)
            queue.insert(contentsOf: tracks, at: i)
            if shuffle {
                let from = (currentID.flatMap { shuffleOrder.firstIndex(of: $0) } ?? -1) + 1
                for t in tracks { shuffleOrder.insert(t.id, at: Int.random(in: from...shuffleOrder.count)) }
            }
        }
        loadMetadata(tracks)
        if play, let first = tracks.first { self.play(first) }
        scheduleSave()
    }

    func playNext(_ ids: Set<UUID>) {
        let moving = queue.filter { ids.contains($0.id) && $0.id != currentID }
        guard !moving.isEmpty else { return }
        preservingNext(force: true) {
            queue.removeAll { ids.contains($0.id) && $0.id != currentID }
            let at = (currentID.flatMap { id in queue.firstIndex { $0.id == id } } ?? -1) + 1
            queue.insert(contentsOf: moving, at: at)
            if shuffle {
                shuffleOrder.removeAll { ids.contains($0) && $0 != currentID }
                let s = (currentID.flatMap { shuffleOrder.firstIndex(of: $0) } ?? -1) + 1
                shuffleOrder.insert(contentsOf: moving.map(\.id), at: s)
            }
        }
        scheduleSave()
    }

    func move(from source: IndexSet, to destination: Int) {
        preservingNext { queue.move(fromOffsets: source, toOffset: destination) }
        scheduleSave()
    }

    func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let removingCurrent = currentID.map(ids.contains) ?? false
        var replacement: Track?
        if removingCurrent {
            var probe = currentID
            while let n = nextTrack(after: probe, auto: false), n.id != currentID {
                if !ids.contains(n.id) { replacement = n; break }
                probe = n.id
            }
        }
        preservingNext {
            queue.removeAll { ids.contains($0.id) }
            shuffleOrder.removeAll { ids.contains($0) }
        }
        selection.subtract(ids)
        if removingCurrent {
            if let r = replacement, isPlaying { play(r) } else { stopAndClear(keep: replacement) }
        }
        scheduleSave()
    }

    func clearQueue() {
        rememberPosition()
        engine.stop()
        queue.removeAll()
        shuffleOrder.removeAll()
        selection.removeAll()
        stopAndClear(keep: nil)
        scheduleSave()
    }

    func removeDuplicates() {
        var seen = Set<String>()
        let dupes = queue.filter { !seen.insert("\($0.url.path)|\($0.start ?? -1)").inserted }.map(\.id)
        remove(Set(dupes))
        showToast(dupes.isEmpty ? "重複はありません" : "\(dupes.count) 曲の重複を削除しました", symbol: "sparkles")
    }

    enum SortKey { case title, artist, album, albumTrack, fileName, duration, random }

    func sort(by key: SortKey) {
        preservingNext {
            switch key {
            case .title: queue.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
            case .artist: queue.sort { ($0.displayArtist, $0.meta.album ?? "", $0.meta.discNumber ?? 0, $0.meta.trackNumber ?? 0) < ($1.displayArtist, $1.meta.album ?? "", $1.meta.discNumber ?? 0, $1.meta.trackNumber ?? 0) }
            case .album: queue.sort { ($0.meta.album ?? "", $0.meta.discNumber ?? 0, $0.meta.trackNumber ?? 0) < ($1.meta.album ?? "", $1.meta.discNumber ?? 0, $1.meta.trackNumber ?? 0) }
            case .albumTrack: queue = queue.inAlbumTrackOrder()
            case .fileName: queue.sort { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
            case .duration: queue.sort { ($0.duration ?? 0) < ($1.duration ?? 0) }
            case .random: queue.shuffle()
            }
        }
        scheduleSave()
    }

    /// キューの変更で「次の曲」が変わった場合だけ、予約済みの次の曲を取り消す
    private func preservingNext(force: Bool = false, _ change: () -> Void) {
        let before = nextTrack(after: currentID, auto: true)?.id
        change()
        if force || nextTrack(after: currentID, auto: true)?.id != before { engine.invalidateUpcoming() }
    }

    private func rebuildShuffle() {
        var ids = queue.map(\.id).shuffled()
        if let c = currentID, let i = ids.firstIndex(of: c) { ids.swapAt(0, i) }
        shuffleOrder = ids
    }

    func attachLyrics(_ url: URL) {
        guard let id = currentID, let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].lyricsURL = url
        if let text = TextDecoding.readText(at: url) { lyrics = Lyrics.parse(text) }
        showLyrics = true
        scheduleSave()
    }

    // MARK: - 再生

    func play(_ track: Track, at seconds: Double = 0, autoplay: Bool = true) {
        let token = UUID()
        loadToken = token
        let changed = currentID != track.id
        if changed { rememberPosition() }
        if autoplay { dropExpiredSleepTimer() }
        currentID = track.id
        resumePosition = nil
        loopA = nil
        loopB = nil
        engine.loop = nil
        clock.position = seconds
        clock.duration = track.duration ?? 0
        if changed || artwork == nil { present(track) }

        Task {
            do {
                let needsConversion = playable[track.url] == nil
                if needsConversion { isPreparing = true }
                let item = try await makeItem(track)
                guard loadToken == token else { return }
                isPreparing = false
                conversionProgress = nil
                engine.load(item, at: seconds, play: autoplay)
                isPlaying = autoplay
                consecutiveFailures = 0
                failed.remove(track.id)
                if waveform == nil { loadWaveform(for: track) }
                updateNowPlayingInfo()
                prepareNext()
                scheduleSave()
            } catch {
                guard loadToken == token else { return }
                isPreparing = false
                conversionProgress = nil
                failed.insert(track.id)
                showToast(error.localizedDescription, symbol: "exclamationmark.triangle")
                consecutiveFailures += 1
                if autoplay, consecutiveFailures < 5, let n = nextTrack(after: track.id, auto: false), n.id != track.id {
                    play(n)
                } else {
                    isPlaying = false
                    engine.stop()
                }
            }
        }
    }

    func togglePlay() {
        if isPlaying {
            engine.pause()
            isPlaying = false
        } else if engine.current != nil, !isPreparing {
            dropExpiredSleepTimer()
            engine.play()
            isPlaying = true
        } else if let t = currentTrack {
            play(t, at: resumePosition ?? clock.position)
        } else if let first = nextTrack(after: nil, auto: false) {
            play(first)
        }
        updateNowPlayingInfo()
    }

    func pause() {
        guard isPlaying else { return }
        togglePlay()
    }

    func next() {
        guard let n = nextTrack(after: currentID, auto: false) else { return }
        start(n)
    }

    func previous() {
        if clock.position > 3 || previousTrack(before: currentID) == nil {
            seek(to: 0)
        } else if let p = previousTrack(before: currentID) {
            start(p)
        }
    }

    // MARK: - 続きから再生

    /// 利用者の操作で曲を再生し始める。ASMR モードで長い音源を途中まで聴いていたら、続きから再生する
    /// (曲が終わって自動で次へ進むときは、いつも頭から)
    func start(_ track: Track) {
        guard track.id != currentID, asmrMode, asmrResume,
              let position = resumeStore.take(track.bookmarkKey, duration: track.duration) else {
            play(track)
            return
        }
        saveResumeStore()
        play(track, at: position)
        showToast("続きから再生します（\(formatTime(position))）。「前の曲」ボタンで最初に戻れます", symbol: "arrow.uturn.forward")
    }

    /// 今の曲を離れる前に、聴いていた位置を覚える
    private func rememberPosition() {
        guard asmrMode, asmrResume, let t = currentTrack else { return }
        let before = resumeStore
        resumeStore.leave(t.bookmarkKey, at: clock.position, duration: t.duration)
        if resumeStore != before { saveResumeStore() }
    }

    private func saveResumeStore() {
        let store = resumeStore
        let dir = Self.supportDirectory
        Task.detached(priority: .utility) { store.save(to: dir) }
    }

    func seek(to seconds: Double) {
        let s = max(0, min(seconds, max(0, clock.duration - 0.1)))
        if engine.current != nil {
            engine.seek(to: s)
        } else {
            resumePosition = s
        }
        clock.position = s
        updateNowPlayingInfo()
    }

    func skip(by delta: Double) { seek(to: clock.position + delta) }

    func toggleABLoop() {
        let pos = clock.position
        if loopA == nil {
            loopA = pos
            showToast("A 地点を設定しました", symbol: "a.circle")
        } else if loopB == nil {
            guard let a = loopA, pos > a + 0.5 else { return }
            setLoop(a, pos)
            showToast("A-B リピート中", symbol: "repeat")
        } else {
            clearLoop()
        }
    }

    // MARK: - 区間ループ

    /// 区間を指定してループする (B が A より 0.5 秒以上後ろのときだけ有効)
    func setLoop(_ a: Double?, _ b: Double?) {
        let limit = max(0, clock.duration - 0.05)
        loopA = a.map { min(max(0, $0), limit) }
        loopB = b.map { min(max(0, $0), limit) }
        if let a = loopA, let b = loopB, b > a + 0.5 {
            engine.loop = a...b
            if clock.position < a || clock.position > b { seek(to: a) }
        } else {
            if let a = loopA, let b = loopB, b <= a + 0.5 { loopB = nil }
            engine.loop = nil
        }
    }

    func setLoopStartHere() { setLoop(clock.position, loopB) }
    func setLoopEndHere() { setLoop(loopA ?? 0, clock.position) }
    func nudgeLoop(start: Bool, by delta: Double) {
        if start { setLoop((loopA ?? 0) + delta, loopB) } else if let b = loopB { setLoop(loopA ?? 0, b + delta) }
    }

    func clearLoop() {
        loopA = nil
        loopB = nil
        engine.loop = nil
    }

    // MARK: - しおり

    var currentBookmarks: [Bookmark] { currentTrack.map { bookmarks[$0.bookmarkKey] ?? [] } ?? [] }

    func addBookmark() {
        guard let t = currentTrack else { return }
        let pos = clock.position
        var list = bookmarks[t.bookmarkKey] ?? []
        guard !list.contains(where: { abs($0.time - pos) < 1 }) else {
            showToast("この位置にはしおりがあります", symbol: "bookmark")
            return
        }
        list.append(Bookmark(time: pos, name: "しおり \(list.count + 1)"))
        list.sort { $0.time < $1.time }
        bookmarks[t.bookmarkKey] = list
        saveBookmarks()
        showToast("\(formatTime(pos)) にしおりをはさみました", symbol: "bookmark.fill")
    }

    func renameBookmark(_ id: UUID, to name: String) {
        editBookmarks { list in
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].name = name }
        }
    }

    func removeBookmark(_ id: UUID) {
        editBookmarks { $0.removeAll { $0.id == id } }
    }

    func jump(to b: Bookmark) {
        if let a = loopA, let e = loopB, b.time < a || b.time > e { clearLoop() }
        seek(to: b.time)
        if !isPlaying { togglePlay() }
    }

    /// しおりから次のしおり (最後なら曲の終わり) までをループする
    func loop(from b: Bookmark) {
        let next = currentBookmarks.first { $0.time > b.time + 0.5 }?.time ?? clock.duration
        setLoop(b.time, next)
        seek(to: b.time)
        showToast("\(b.name) から\(next < clock.duration ? "次のしおり" : "曲の終わり")までループします", symbol: "repeat")
    }

    func nextBookmark() {
        guard let b = currentBookmarks.first(where: { $0.time > clock.position + 0.5 }) else { return }
        jump(to: b)
    }

    func previousBookmark() {
        guard let b = currentBookmarks.last(where: { $0.time < clock.position - 2 }) else {
            if let first = currentBookmarks.first { jump(to: first) }
            return
        }
        jump(to: b)
    }

    private func editBookmarks(_ change: (inout [Bookmark]) -> Void) {
        guard let t = currentTrack else { return }
        var list = bookmarks[t.bookmarkKey] ?? []
        change(&list)
        bookmarks[t.bookmarkKey] = list
        saveBookmarks()
    }

    private func saveBookmarks() {
        let all = bookmarks
        let dir = Self.supportDirectory
        Task.detached(priority: .utility) { BookmarkStore.save(all, to: dir) }
    }

    // MARK: - スリープタイマー

    func setSleepTimer(minutes: Int?) {
        sleepAtTrackEnd = false
        sleepDeadline = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        pendingSleepPoint = minutes == nil ? nil : currentSleepPoint()
        if let m = minutes {
            let fade = min(sleepFadeDuration, Double(m) * 60)
            showToast(asmrMode ? "\(m) 分後に停止します（最後の \(fadeLabel(fade)) で少しずつ小さくします）" : "\(m) 分後に停止します",
                      symbol: "moon.zzz")
        }
        resetSleepFade()
    }

    /// 動いているタイマーを延ばす。フェードアウトが始まっていたら、音量もゆっくり戻る
    func extendSleep(minutes: Int = 15) {
        guard let deadline = sleepDeadline else { return }
        let extended = max(deadline, Date()).addingTimeInterval(Double(minutes) * 60)
        sleepDeadline = extended
        pendingSleepPoint = currentSleepPoint()   // 延ばした = まだ起きている
        showToast("スリープタイマーを \(minutes) 分延ばしました（あと \(Int((extended.timeIntervalSinceNow / 60).rounded())) 分）", symbol: "moon.zzz")
    }

    func fadeLabel(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) 秒" : "\(Int(seconds / 60)) 分"
    }

    func setSleepAtTrackEnd() {
        sleepDeadline = nil
        sleepAtTrackEnd = true
        pendingSleepPoint = currentSleepPoint()
        engine.invalidateUpcoming()
        resetSleepFade()
        showToast("この曲の終わりで停止します", symbol: "moon.zzz")
    }

    func cancelSleep() {
        sleepDeadline = nil
        sleepAtTrackEnd = false
        pendingSleepPoint = nil
        resetSleepFade()
    }

    /// 止めている間に時間を過ぎたタイマーは、再生し直すときに解除する (再生した途端に止まらないように)
    private func dropExpiredSleepTimer() {
        if let deadline = sleepDeadline, deadline <= Date() { cancelSleep() }
    }

    /// 再生中は tick が少しずつ音量を戻す (いきなり大きくしない)。止まっているときはその場で戻す
    private func resetSleepFade() {
        if !isPlaying { engine.fadeMultiplier = 1 }
    }

    private func currentSleepPoint() -> SleepPoint? {
        currentTrack.map { SleepPoint(key: $0.bookmarkKey, title: $0.shortTitle, time: clock.position, date: Date()) }
    }

    /// タイマーの時間になった: 止めて、タイマーをセットしたときの位置を残す
    private func finishSleep() {
        sleepDeadline = nil
        sleepAtTrackEnd = false
        engine.pause(immediately: true)
        isPlaying = false
        engine.fadeMultiplier = 1
        if let point = pendingSleepPoint { lastSleepPoint = point }
        pendingSleepPoint = nil
        updateNowPlayingInfo()
        saveNow()
    }

    /// 前回のスリープタイマーの「おやすみ前の位置」がある曲 (再生キューにあるときだけ)
    var sleepPointTrack: Track? {
        guard let point = lastSleepPoint else { return nil }
        return queue.first { $0.bookmarkKey == point.key }
    }

    /// 今の曲の中にある、おやすみ前の位置 (シークバーの印に使う)
    var sleepPointInCurrentTrack: Double? {
        guard let point = lastSleepPoint, currentTrack?.bookmarkKey == point.key else { return nil }
        return point.time
    }

    /// 前回スリープタイマーをセットした位置へ戻って再生する
    func returnToSleepPoint() {
        guard let point = lastSleepPoint else { return }
        guard let track = sleepPointTrack else {
            showToast("おやすみ前に聴いていた「\(point.title)」は再生キューにありません", symbol: "moon.zzz")
            return
        }
        if track.id == currentID, engine.current != nil {
            if let a = loopA, let b = loopB, point.time < a || point.time > b { clearLoop() }
            seek(to: point.time)
            if !isPlaying { togglePlay() }
        } else {
            play(track, at: point.time)
        }
        showToast("おやすみ前の位置（\(formatTime(point.time))）に戻りました", symbol: "moon.zzz")
    }

    // MARK: - 左右の確認

    /// イヤホンの左右を確かめる音を鳴らす (左で 1 回、右で 2 回)
    func playChannelCheck() {
        if muted || volume < 0.02 {
            showToast("音量が 0 のため、確認音は聞こえません", symbol: "speaker.slash")
            return
        }
        engine.playChannelCheck()
    }

    func applyPreset(_ p: EQPreset) {
        eqBands = p.gains
        eqPresetName = p.name
        eqEnabled = true
    }

    func refreshOutputDevices() { outputDevices = AudioOutputs.list() }

    func selectOutputDevice(_ device: AudioOutputDevice?) {
        outputDeviceUID = device?.uid
        Defaults.set("outputDevice", device?.uid)
        let pos = clock.position, wasPlaying = isPlaying
        engine.setOutputDevice(device?.id)
        if let t = currentTrack, engine.current != nil { play(t, at: pos, autoplay: wasPlaying) }
    }

    // MARK: - エンジン連携

    private func makeItem(_ track: Track) async throws -> PlaybackItem {
        let url = try await playableURL(for: track.url)
        let file = try AVAudioFile(forReading: url)
        return PlaybackItem(trackID: track.id, file: file, source: track.url, start: track.start ?? 0, end: track.end, gain: gain(for: track))
    }

    private func gain(for t: Track) -> Float {
        let m = t.meta
        let (g, p): (Double?, Double?) = switch replayGain {
        case .off: (nil, nil)
        case .track: (m.rgTrackGain ?? m.rgAlbumGain, m.rgTrackPeak ?? m.rgAlbumPeak)
        case .album: (m.rgAlbumGain ?? m.rgTrackGain, m.rgAlbumPeak ?? m.rgTrackPeak)
        }
        guard let g else { return 1 }
        var linear = pow(10, g / 20)
        if let p, p > 0 { linear = min(linear, 1 / p) }
        return Float(linear)
    }

    /// 再生可能な URL (ネイティブ非対応形式は ffmpeg で FLAC に変換)
    func playableURL(for source: URL) async throws -> URL {
        if let u = playable[source] { return u }
        if let running = conversions[source] { return try await running.value }
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw NSError(domain: "Kanade", code: 1, userInfo: [NSLocalizedDescriptionKey: "ファイルが見つかりません: \(source.lastPathComponent)"])
        }
        let native = await Task.detached(priority: .userInitiated) { (try? AVAudioFile(forReading: source)) != nil }.value
        if native {
            playable[source] = source
            return source
        }
        let task = Task<URL, Error> {
            try await FFmpeg.convertToFLAC(source) { p in
                Task { @MainActor in
                    let model = PlayerModel.shared
                    if model.currentTrack?.url == source { model.conversionProgress = p }
                }
            }
        }
        conversions[source] = task
        defer { conversions[source] = nil }
        let url = try await task.value
        playable[source] = url
        return url
    }

    private func readyNextItem() -> PlaybackItem? {
        guard !sleepAtTrackEnd, let next = nextTrack(after: currentID, auto: true) else { return nil }
        guard let url = playable[next.url] else {
            prepareNext()
            return nil
        }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return PlaybackItem(trackID: next.id, file: file, source: next.url, start: next.start ?? 0, end: next.end, gain: gain(for: next))
    }

    private func prepareNext() {
        guard let n = nextTrack(after: currentID, auto: true), playable[n.url] == nil, conversions[n.url] == nil else { return }
        Task { _ = try? await playableURL(for: n.url) }
    }

    private func didAdvance(to id: UUID) {
        let changed = currentID != id
        if changed, let finished = currentTrack {
            // 最後まで聴いた曲は、次も頭から
            resumeStore.forget(finished.bookmarkKey)
        }
        currentID = id
        loopA = nil
        loopB = nil
        engine.loop = nil
        if let t = currentTrack {
            clock.duration = t.duration ?? clock.duration
            if changed { present(t) }
        }
        updateNowPlayingInfo()
        prepareNext()
        scheduleSave()
    }

    private func didFinish() {
        if sleepAtTrackEnd {
            finishSleep()
            if let t = currentTrack { play(t, at: 0, autoplay: false) }
            return
        }
        if let n = nextTrack(after: currentID, auto: true) {
            play(n)
        } else {
            isPlaying = false
            if let t = currentTrack { play(t, at: 0, autoplay: false) }
            updateNowPlayingInfo()
        }
    }

    private func tick(_ position: Double, _ duration: Double) {
        // 画面への反映は 10Hz で十分 (SwiftUI の再レイアウトを減らして省電力に)
        let now = CACurrentMediaTime()
        // 省電力表示でも、同期歌詞・字幕を出している間は行の切り替えが遅れないよう、少し細かく更新する
        let interval = powerSaving ? (showLyrics && lyrics?.synced == true ? 0.25 : 1.0) : 0.1
        if now - lastClockPublish >= interval || abs(position - clock.position) > 1.5 || !isPlaying {
            clock.position = position
            lastClockPublish = now
        }
        if duration > 0, clock.duration != duration { clock.duration = duration }
        if isPlaying {
            // スリープタイマー: 残り時間に合わせて音量を下げる。延長や解除で戻すときは少しずつ
            var target: Float = 1
            if let d = sleepDeadline {
                let remaining = d.timeIntervalSinceNow
                if remaining <= 0 {
                    finishSleep()
                    return
                }
                target = SleepFade.target(remaining: remaining, fade: sleepFadeDuration)
            }
            let fade = SleepFade.step(from: engine.fadeMultiplier, to: target)
            if fade != engine.fadeMultiplier { engine.fadeMultiplier = fade }
        }
        // 外部 (コントロールセンター) の位置表示がずれないよう時々同期
        if abs(position - lastNowPlayingSync) > 5 { updateNowPlayingInfo() }
    }

    private func reloadAfterDeviceChange() {
        refreshOutputDevices()
        guard let t = currentTrack, engine.current != nil else { return }
        play(t, at: clock.position, autoplay: isPlaying)
    }

    private func stopAndClear(keep: Track?) {
        engine.stop()
        isPlaying = false
        currentID = keep?.id
        clock.position = 0
        clock.duration = keep?.duration ?? 0
        if let keep { present(keep) } else {
            artwork = nil
            palette = .default
            lyrics = nil
            waveform = nil
        }
        updateNowPlayingInfo()
    }

    private func applyVolume() {
        engine.volume = muted ? 0 : Float(volume)
        if asmrMode, asmrLoudness { applyASMR() }
    }

    private func applyEQ() { engine.setEQ(bands: eqBands, preamp: eqPreamp, enabled: eqEnabled && !asmrMode) }

    private func applyRate() {
        engine.rate = Float(effectiveRate)
        engine.pitch = asmrMode ? 0 : Float(pitch)
        updateNowPlayingInfo()
    }

    private func applyBalance() { engine.balance = asmrMode ? 0 : Float(balance) }

    private func applyASMR() {
        var s = ASMRSettings()
        s.dynamics = asmrMode
        s.limiter = asmrMode
        s.swap = asmrMode && swapChannels
        asmrStrength.apply(to: &s)
        (asmrMode ? asmrSoftening : .off).apply(to: &s)
        (s.loudnessLow, s.loudnessHigh) = loudnessBoost
        engine.asmrSettings = s
        engine.softTransitions = asmrMode
    }

    private func applyPowerSaving() {
        engine.spectrum.enabled = !powerSaving
        if !powerSaving { lastClockPublish = 0 }
    }

    // MARK: - アートワークの指定

    /// 今の曲の作品に、手動で指定したアートワークがあるか
    var hasCustomArtwork: Bool { currentTrack.map(ArtworkStore.shared.hasCustom) ?? false }

    /// 画像ファイルを、今の曲の作品のアートワークにする (同じ作品のほかの曲にも使われる)
    func setCustomArtwork(from url: URL) {
        guard let track = currentTrack else {
            showToast("アートワークは、曲を選んでいるときに指定できます", symbol: "photo")
            return
        }
        guard ArtworkStore.shared.setCustom(imageAt: url, for: track) else {
            showToast("画像を読み込めませんでした: \(url.lastPathComponent)", symbol: "exclamationmark.triangle")
            return
        }
        reloadArtwork()
        showToast("この作品のアートワークを指定しました", symbol: "photo")
    }

    func chooseArtwork() {
        guard currentTrack != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "この作品のアートワークにする画像を選んでください"
        panel.prompt = "指定"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in PlayerModel.shared.setCustomArtwork(from: url) }
        }
    }

    func clearCustomArtwork() {
        guard let track = currentTrack, ArtworkStore.shared.hasCustom(for: track) else { return }
        ArtworkStore.shared.removeCustom(for: track)
        reloadArtwork()
        showToast("アートワークを元に戻しました", symbol: "photo")
    }

    /// 今の曲のアートワークを読み直す
    private func reloadArtwork() {
        guard let track = currentTrack else { return }
        loadArtwork(for: track, token: presentToken)
    }

    // MARK: - 表示 (アートワーク・歌詞・波形)

    private func loadArtwork(for track: Track, token: UUID) {
        Task {
            let img = await ArtworkStore.shared.image(for: track)
            guard presentToken == token else { return }
            if img !== artwork {
                let p = await Task.detached(priority: .userInitiated) { Palette.from(img) }.value
                guard presentToken == token else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    artwork = img
                    palette = p
                }
            }
            updateNowPlayingInfo()
        }
    }

    private func present(_ track: Track) {
        let token = UUID()
        presentToken = token
        lyrics = nil
        waveform = nil
        loadWaveform(for: track)
        loadArtwork(for: track, token: token)
        Task {
            let l = await loadLyrics(track)
            guard presentToken == token else { return }
            lyrics = l
        }
    }

    private func loadLyrics(_ t: Track) async -> Lyrics? {
        if let u = t.lyricsURL, let text = TextDecoding.readText(at: u) { return Lyrics.parse(text) }
        if t.isCueTrack { return nil }
        // あとから置かれた歌詞・字幕ファイル (取り込んだ時点ではなかったもの) も拾う
        let url = t.url
        if let u = await Task.detached(priority: .utility, operation: { Importer.sidecarLyrics(for: url) }).value,
           let text = TextDecoding.readText(at: u) {
            return Lyrics.parse(text)
        }
        if t.meta.loaded, !t.meta.hasEmbeddedLyrics { return nil }
        guard let text = await MetadataReader.embeddedLyrics(t.url) else { return nil }
        let l = Lyrics.parse(text)
        return l.lines.isEmpty ? nil : l
    }

    private func loadWaveform(for track: Track) {
        waveformTask?.cancel()
        waveformTask = Task {
            var resolved = playable[track.url]
            if resolved == nil { resolved = try? await playableURL(for: track.url) }
            guard let src = resolved, !Task.isCancelled else { return }
            let peaks: [Float]
            if let cached = peaksCache[src] {
                peaks = cached
            } else {
                guard let p = await Task.detached(priority: .utility, operation: { WaveformBuilder.peaks(of: src) }).value,
                      !Task.isCancelled else { return }
                if peaksCache.count > 40 { peaksCache.removeAll() }
                peaksCache[src] = p
                peaks = p
            }
            guard currentID == track.id, let file = try? AVAudioFile(forReading: src) else { return }
            let total = Double(file.length) / file.processingFormat.sampleRate
            guard total > 0 else { return }
            let from = (track.start ?? 0) / total
            let to = (track.end ?? total) / total
            withAnimation(.easeOut(duration: 0.35)) { waveform = WaveformBuilder.slice(peaks, from: from, to: to) }
        }
    }

    // MARK: - メタデータ

    private func loadMetadata(_ tracks: [Track]) {
        pendingMeta += tracks.filter { !$0.meta.loaded }.map(\.id)
        pumpMetadata()
    }

    private func pumpMetadata() {
        while metaInFlight.count < 4, let index = pendingMeta.firstIndex(where: { id in
            guard let t = track(id) else { return true }
            return !metaInFlight.contains(t.url)
        }) {
            let id = pendingMeta.remove(at: index)
            guard let t = track(id), !t.meta.loaded else { continue }
            let url = t.url
            metaInFlight.insert(url)
            Task {
                let meta = await MetadataReader.read(url)
                metaInFlight.remove(url)
                metaBuffer[url] = meta
                scheduleMetaFlush()
                pumpMetadata()
            }
        }
    }

    private func scheduleMetaFlush() {
        guard !metaFlushScheduled else { return }
        metaFlushScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            flushMetadata()
        }
    }

    private func flushMetadata() {
        metaFlushScheduled = false
        guard !metaBuffer.isEmpty else { return }
        let buffer = metaBuffer
        metaBuffer.removeAll()
        var q = queue
        var splits: [(Int, [Track])] = []
        for i in q.indices {
            guard !q[i].meta.loaded, let m = buffer[q[i].url] else { continue }
            q[i].meta = merged(q[i], m)
            if let parts = Importer.splitEmbeddedCue(q[i]) { splits.append((i, parts)) }
        }
        for (i, parts) in splits.reversed() {
            let old = q[i].id
            q.replaceSubrange(i...i, with: parts)
            if shuffle, let s = shuffleOrder.firstIndex(of: old) { shuffleOrder.replaceSubrange(s...s, with: parts.map(\.id)) }
        }
        preservingNext { queue = q }
        if let t = currentTrack, buffer[t.url] != nil {
            clock.duration = t.duration ?? clock.duration
            updateNowPlayingInfo()
            if lyrics == nil, t.meta.hasEmbeddedLyrics { present(t) }
        }
        scheduleSave()
    }

    private func merged(_ t: Track, _ m: TrackMeta) -> TrackMeta {
        var out = m
        let old = t.meta
        if t.isCueTrack {
            out.title = old.title ?? m.title
            out.artist = old.artist ?? m.artist
            out.album = old.album ?? m.album
            out.albumArtist = old.albumArtist ?? m.albumArtist
            out.trackNumber = old.trackNumber
            out.year = old.year ?? m.year
            out.genre = old.genre ?? m.genre
            out.rgTrackGain = nil
            out.rgTrackPeak = nil
            out.hasEmbeddedLyrics = false
            out.embeddedCueSheet = nil
        } else {
            out.title = m.title ?? old.title
            out.artist = m.artist ?? old.artist
        }
        return out
    }

    // MARK: - Now Playing (コントロールセンター・メディアキー)

    private func setupRemoteCommands() {
        let rc = MPRemoteCommandCenter.shared()
        rc.togglePlayPauseCommand.addTarget { _ in Task { @MainActor in PlayerModel.shared.togglePlay() }; return .success }
        rc.playCommand.addTarget { _ in
            Task { @MainActor in let m = PlayerModel.shared; if !m.isPlaying { m.togglePlay() } }
            return .success
        }
        rc.pauseCommand.addTarget { _ in Task { @MainActor in PlayerModel.shared.pause() }; return .success }
        rc.nextTrackCommand.addTarget { _ in Task { @MainActor in PlayerModel.shared.next() }; return .success }
        rc.previousTrackCommand.addTarget { _ in Task { @MainActor in PlayerModel.shared.previous() }; return .success }
        rc.changePlaybackPositionCommand.addTarget { e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in PlayerModel.shared.seek(to: t) }
            return .success
        }
    }

    func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        lastNowPlayingSync = clock.position
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.shortTitle,
            MPMediaItemPropertyArtist: t.displayArtist,
            MPMediaItemPropertyAlbumTitle: t.meta.album ?? "",
            MPMediaItemPropertyPlaybackDuration: clock.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: clock.position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? effectiveRate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let art = artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: art.size) { _ in art }
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    // MARK: - トースト

    func showToast(_ message: String, symbol: String = "info.circle") {
        let t = Toast(message: message, symbol: symbol)
        withAnimation(.spring(duration: 0.35)) { toast = t }
        Task {
            try? await Task.sleep(for: .seconds(3.2))
            if toast?.id == t.id { withAnimation(.easeOut(duration: 0.3)) { toast = nil } }
        }
    }

    // MARK: - 永続化

    private struct SavedState: Codable {
        var queue: [Track]
        var currentID: UUID?
        var position: Double
        var shuffleOrder: [UUID]
    }

    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "Kanade-Dev" : "Kanade", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var stateURL: URL { supportDirectory.appendingPathComponent("state.json") }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        rememberPosition()
        let state = SavedState(queue: queue, currentID: currentID, position: clock.position, shuffleOrder: shuffleOrder)
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(SavedState.self, from: data) else { return }
        queue = state.queue
        let ids = Set(queue.map(\.id))
        shuffleOrder = state.shuffleOrder.filter(ids.contains)
        if shuffle, shuffleOrder.count != queue.count { rebuildShuffle() }
        if let id = state.currentID, let t = track(id) {
            currentID = id
            resumePosition = state.position
            clock.position = state.position
            clock.duration = t.duration ?? 0
            present(t)
        }
        loadMetadata(queue)
    }
}

// MARK: - UserDefaults

enum Defaults {
    static func bool(_ k: String, _ d: Bool) -> Bool { UserDefaults.standard.object(forKey: k) as? Bool ?? d }
    static func double(_ k: String, _ d: Double) -> Double { UserDefaults.standard.object(forKey: k) as? Double ?? d }
    static func string(_ k: String) -> String? { UserDefaults.standard.string(forKey: k) }
    static func array(_ k: String) -> [Any]? { UserDefaults.standard.array(forKey: k) }
    static func data(_ k: String) -> Data? { UserDefaults.standard.data(forKey: k) }
    static func set(_ k: String, _ v: Any?) { UserDefaults.standard.set(v, forKey: k) }
}
