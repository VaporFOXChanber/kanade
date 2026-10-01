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

    /// 作品番号 (RJ…) の分かる曲で、アーティストなどのタグが空のとき、DLsite から声優名とサークル名を取得して埋める
    var dlsiteInfo = Defaults.bool("dlsiteInfo", false) {
        didSet {
            Defaults.set("dlsiteInfo", dlsiteInfo)
            DLsiteCatalog.enabled = dlsiteInfo
            if dlsiteInfo {
                fillFromDLsite()
                LibraryStore.shared.fillFromDLsite()
            }
        }
    }

    // MARK: 再生設定
    var shuffle = Defaults.bool("shuffle", false) {
        didSet { Defaults.set("shuffle", shuffle); rebuildShuffle(); engine.invalidateUpcoming() }
    }
    var repeatMode = RepeatMode(rawValue: Defaults.string("repeat") ?? "") ?? .off {
        didSet { Defaults.set("repeat", repeatMode.rawValue); engine.invalidateUpcoming() }
    }
    /// アプリの中で掛ける音量 (0〜1)
    private var appVolume = Defaults.double("volume", 0.8) { didSet { Defaults.set("volume", appVolume); applyVolume() } }
    /// 音量スライダーの値。ふだんはアプリの音量、ビットパーフェクト再生中は出力デバイス側の音量
    /// (アプリの中で音量を下げると、元のデータのままではなくなるため)
    var volume: Double {
        get { bitPerfect ? deviceVolume ?? 1 : appVolume }
        set {
            guard bitPerfect else {
                appVolume = newValue
                return
            }
            guard !volumeLocked, let device = engine.outputDeviceID else { return }
            let value = min(1, max(0, newValue))
            OutputDevice.setVolume(device, Float(value))
            deviceVolume = value
        }
    }
    var muted = false { didSet { applyVolume() } }
    var rate = Defaults.double("rate", 1) { didSet { Defaults.set("rate", rate); applyRate() } }
    var pitch = Defaults.double("pitch", 0) { didSet { Defaults.set("pitch", pitch); applyRate() } }
    var preservePitch = Defaults.bool("preservePitch", true) {
        didSet { Defaults.set("preservePitch", preservePitch); engine.preservePitch = preservePitch }
    }
    var balance = Defaults.double("balance", 0) { didSet { Defaults.set("balance", balance); applyBalance() } }
    var crossfade = Defaults.double("crossfade", 0) {
        didSet { Defaults.set("crossfade", crossfade); engine.crossfadeDuration = bitPerfect ? 0 : crossfade; engine.invalidateUpcoming() }
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

    // MARK: 高音質のための設定
    /// ヘッドホン用のクロスフィード
    var crossfeed = CrossfeedLevel(rawValue: Defaults.string("crossfeed") ?? "") ?? .off {
        didSet { Defaults.set("crossfeed", crossfeed.rawValue); applyASMR() }
    }
    /// EQ などで音が大きくなったときに、0 dBFS を超えて歪まないようにする (加工していないときは働かない)
    var clipGuard = Defaults.bool("clipGuard", true) { didSet { Defaults.set("clipGuard", clipGuard); applyASMR() } }
    /// パラメトリック EQ (ヘッドホンの補正など) の設定の一覧と、使っているもの
    private(set) var eqProfiles: [EQProfile] = Defaults.codable("eqProfiles") ?? [] {
        didSet { Defaults.setCodable("eqProfiles", eqProfiles); applyASMR() }
    }
    var activeProfileID: UUID? = Defaults.string("activeProfile").flatMap(UUID.init) {
        didSet {
            Defaults.set("activeProfile", activeProfileID?.uuidString)
            // 出力デバイスごとに、選んだ設定を覚える
            var map = deviceProfiles
            map[currentOutputUID] = activeProfileID?.uuidString ?? ""
            deviceProfiles = map
            applyASMR()
        }
    }
    private var deviceProfiles: [String: String] = Defaults.codable("deviceProfiles") ?? [:] {
        didSet { Defaults.setCodable("deviceProfiles", deviceProfiles) }
    }
    /// 出力デバイスのサンプルレートとビット深度を曲に合わせて切り替える (ビットパーフェクト再生中は常に合わせる)
    var matchSampleRate = Defaults.bool("matchSampleRate", false) {
        didSet {
            Defaults.set("matchSampleRate", matchSampleRate)
            applyOutputPolicy()
            reloadForOutputChange()
        }
    }
    /// アップサンプリング: 曲の整数倍のサンプルレートにデバイスを切り替え、変換してから送る (ビットパーフェクト再生中は使わない)
    var upsampling = Upsampling(rawValue: Defaults.string("upsampling") ?? "") ?? .off {
        didSet {
            Defaults.set("upsampling", upsampling.rawValue)
            applyOutputPolicy()
            reloadForOutputChange()
        }
    }
    /// DSD の曲を、対応を確かめた DAC へそのまま (DoP で) 送る
    var dopEnabled = Defaults.bool("dopEnabled", false) {
        didSet {
            Defaults.set("dopEnabled", dopEnabled)
            dopRefused.removeAll()
            engine.invalidateUpcoming()
            reloadForOutputChange()
        }
    }
    /// 出力デバイスごとの、DoP に対応しているかの確認結果 (デバイスの UID → 結果)
    private(set) var dopDevices: [String: DoP.Support] = Defaults.codable("dopDevices") ?? [:] {
        didSet { Defaults.setCodable("dopDevices", dopDevices) }
    }
    /// DoP の対応を確かめている途中の状態 (確かめていなければ nil)
    private(set) var dopCheck: DoPCheck?
    @ObservationIgnored private var dopCheckResume: (id: UUID, position: Double)?
    @ObservationIgnored private let dopCheckID = UUID()
    @ObservationIgnored private var dopFiles: [URL: URL] = [:]
    @ObservationIgnored private var dopConversions: [URL: Task<URL, Error>] = [:]
    /// DoP で送ろうとして送れなかった曲 (PCM に変換して再生する)
    @ObservationIgnored private var dopRefused: Set<URL> = []
    @ObservationIgnored private var dsdInfoCache: [URL: DSDFile.Info?] = [:]
    /// ビットパーフェクト再生: 音を変える処理をすべて外し、デバイスの形式を曲に合わせ、アプリの音量を最大にして、
    /// 元のデータのまま出力する。EQ などの設定は残したまま使わないだけなので、オフにすれば元に戻る。
    /// 切り替えは setBitPerfect で行う
    private(set) var bitPerfect = Defaults.bool("bitPerfect", false) { didSet { Defaults.set("bitPerfect", bitPerfect) } }
    /// ビットパーフェクト再生に入るときに ASMR モードを止めたか (出るときに戻す)
    private var bitPerfectSuspendedASMR = Defaults.bool("bitPerfectSuspendedASMR", false) {
        didSet { Defaults.set("bitPerfectSuspendedASMR", bitPerfectSuspendedASMR) }
    }
    /// ビットパーフェクト再生の間、アプリの音量の代わりにデバイス側で下げている量。出るときに戻す
    private var bitPerfectOffsets: DeviceVolumeOffsets = Defaults.codable("bitPerfectOffsets") ?? DeviceVolumeOffsets() {
        didSet { Defaults.setCodable("bitPerfectOffsets", bitPerfectOffsets) }
    }
    /// 出力デバイス側の音量 (0〜1)。Mac から変えられないデバイスなら nil
    private(set) var deviceVolume: Double?
    @ObservationIgnored private let deviceVolumeObserver = DeviceVolumeObserver()
    /// 出力デバイスを排他的に使う
    var exclusiveMode = Defaults.bool("exclusiveMode", false) {
        didSet {
            Defaults.set("exclusiveMode", exclusiveMode)
            if exclusiveMode != oldValue { applyExclusiveMode() }
        }
    }
    /// 排他モードを切り替えている途中か (設定のスイッチを押せなくする)
    private(set) var switchingExclusive = false
    /// 音量をそろえるためのタグ (ReplayGain) がない曲は、大きさを測ってそろえる
    var loudnessScan = Defaults.bool("loudnessScan", false) {
        didSet { Defaults.set("loudnessScan", loudnessScan); if loudnessScan { prepareNext() } }
    }
    private var loudness = LoudnessStore()
    private var loudnessInFlight: [String: Task<LoudnessResult?, Never>] = [:]
    /// 表示を作り直すための番号 (出力デバイスの状態が変わったときに進める)
    private(set) var outputRevision = 0 { didSet { refreshDeviceVolume() } }

    // MARK: 再生回数・お気に入り
    private(set) var stats = PlayStats()
    /// 今の曲を聴いた時間 (秒) と、1 回の再生として数えたか
    private var listened = 0.0
    private var counted = false
    private var lastListenTick: CFTimeInterval = 0

    // MARK: ASMR モード
    /// 小さい音を持ち上げ大きい音を抑え、急な大音量を止める。EQ・バランス・速度・キーは無効にしてステレオのまま再生する
    var asmrMode = Defaults.bool("asmrMode", false) {
        didSet {
            Defaults.set("asmrMode", asmrMode)
            // ASMR モードは音を加工するので、ビットパーフェクト再生とは両立しない (あとから選んだほうを使う)
            if asmrMode, bitPerfect {
                bitPerfectSuspendedASMR = false
                setBitPerfect(false, quietly: true)
            }
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
    /// 「カスタム」の強さの値
    var asmrCustom: ASMRCustomCurve = Defaults.codable("asmrCustom") ?? ASMRCustomCurve() {
        didSet { Defaults.setCodable("asmrCustom", asmrCustom); applyASMR() }
    }
    /// 低い雑音を切る周波数 (Hz、0 ならオフ)
    var asmrLowCut = Defaults.double("asmrLowCut", 0) { didSet { Defaults.set("asmrLowCut", asmrLowCut); applyASMR() } }
    /// 処理前の音と聴き比べている間 (ボタンを押している間だけ true)
    var asmrCompare = false { didSet { if asmrCompare != oldValue { applyASMR() } } }
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
    /// EQ・ヘッドホンの補正・速度・キー・バランスを使わない再生か (ASMR モードとビットパーフェクト再生)
    var effectsOff: Bool { asmrMode || bitPerfect }
    /// 実際に再生している速さ (ASMR モードとビットパーフェクト再生では常に等速)
    var effectiveRate: Double { effectsOff ? 1 : rate }
    var sleepFadeDuration: Double { asmrMode ? asmrSleepFade : 12 }

    /// 小音量時のラウドネス補正量 (低域 dB, 高域 dB)。音量を下げるほど聞こえにくくなる低音・高音を補う
    var loudnessBoost: (low: Float, high: Float) {
        guard asmrMode, asmrLoudness else { return (0, 0) }
        let attenuation = Float(40 * log10(max(appVolume, 0.01)))   // 出力は volume² なので 40log
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
        applyVolume()
        engine.preservePitch = preservePitch
        engine.crossfadeDuration = bitPerfect ? 0 : crossfade
        applyRate()
        applyBalance()
        applyEQ()
        applyASMR()
        applyPowerSaving()
        bookmarks = BookmarkStore.load(from: Self.supportDirectory)
        resumeStore = ResumeStore.load(from: Self.supportDirectory)
        loudness = LoudnessStore.load(from: Self.supportDirectory)
        stats = PlayStats.load(from: Self.supportDirectory)
        applyOutputPolicy()
        deviceVolumeObserver.onChange = { [weak self] in MainActor.assumeIsolated { self?.readDeviceVolume() } }

        engine.provideNext = { [weak self] in MainActor.assumeIsolated { self?.readyNextItem() } }
        engine.onAdvance = { [weak self] id in MainActor.assumeIsolated { self?.didAdvance(to: id) } }
        engine.onFinished = { [weak self] in MainActor.assumeIsolated { self?.didFinish() } }
        engine.onTick = { [weak self] pos, dur in MainActor.assumeIsolated { self?.tick(pos, dur) } }
        engine.onConfigurationChange = { [weak self] in MainActor.assumeIsolated { self?.reloadAfterDeviceChange() } }
        engine.onStartFailure = { [weak self] in MainActor.assumeIsolated { self?.engineFailedToStart() } }

        refreshOutputDevices()
        if let uid = outputDeviceUID, let d = outputDevices.first(where: { $0.uid == uid }) {
            engine.setOutputDevice(d.id)
        }
        applyDeviceProfile()
        // 前回とは違うデバイスで始まったときのために (ビットパーフェクト再生のまま終了していた場合)
        moveBitPerfectVolume(to: engine.outputDeviceID, uid: currentOutputUID)
        refreshDeviceVolume()
        if exclusiveMode { applyExclusiveMode() }
        setupRemoteCommands()
        DLsiteCatalog.directory = Self.supportDirectory
        DLsiteCatalog.enabled = dlsiteInfo
        restore()
        fillFromDLsite()
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

    // MARK: - ライブラリ・プレイリストからの再生

    /// 再生キューに入れるための写し (キューの中で見分けるための ID を新しくする)
    private func fresh(_ tracks: [Track]) -> [Track] {
        tracks.map { var t = $0; t.id = UUID(); return t }
    }

    /// 再生キューを置き換えて、index 番目から再生する
    func playNow(_ tracks: [Track], startAt index: Int = 0) {
        guard !tracks.isEmpty else { return }
        let list = fresh(tracks)
        rememberPosition()
        engine.stop()
        queue = list
        selection.removeAll()
        let first = list[min(max(0, index), list.count - 1)]
        currentID = nil
        shuffleOrder = []
        if shuffle {
            currentID = first.id
            rebuildShuffle()
        }
        loadMetadata(list)
        play(first)
        scheduleSave()
    }

    /// 再生キューに足す。next なら今の曲のすぐあと、そうでなければ末尾
    func enqueue(_ tracks: [Track], next: Bool = false) {
        guard !tracks.isEmpty else { return }
        let list = fresh(tracks)
        let at: Int? = next ? (currentID.flatMap { id in queue.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0) : nil
        let wasEmpty = queue.isEmpty
        insert(list, at: at, play: wasEmpty)
        if next, shuffle {
            // シャッフル中も、次に再生されるようにする
            shuffleOrder.removeAll { id in list.contains { $0.id == id } }
            let s = (currentID.flatMap { shuffleOrder.firstIndex(of: $0) } ?? -1) + 1
            shuffleOrder.insert(contentsOf: list.map(\.id), at: s)
            engine.invalidateUpcoming()
        }
        showToast(next ? "\(list.count) 曲を次に再生します" : "\(list.count) 曲を再生キューに追加しました", symbol: "text.badge.plus")
    }

    /// 今の再生キューを、名前を付けたプレイリストとして保存する (名前は最初の曲のアルバム名か日付)
    func saveQueueAsPlaylist() {
        guard !queue.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d H:mm"
        let name = queue.first?.meta.album?.nilIfBlank ?? "キュー \(formatter.string(from: Date()))"
        let playlist = LibraryStore.shared.createPlaylist(name: name, tracks: fresh(queue))
        showToast("プレイリスト「\(playlist.name)」に \(queue.count) 曲を保存しました", symbol: "music.note.list")
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
        // DoP の確認の途中でほかの曲を選んだら、確認はやめる (音量を元に戻す)
        if dopCheck != nil { endDoPCheck(resume: false) }
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
                let needsConversion = wantsDoP(track) ? dopFiles[track.url] == nil : playable[track.url] == nil
                if needsConversion { isPreparing = true }
                if needsLoudness(track) { isPreparing = true }
                await ensureLoudness(for: track)
                var item = try await makeItem(track)
                guard loadToken == token else { return }
                await engine.prepareOutput(for: item)
                guard loadToken == token else { return }
                if item.isDoP, !engine.dopReady(for: item) {
                    // デバイスを DoP 用の形式に切り替えられなかった: そのまま送ると雑音になるので、PCM に変換して再生する
                    dopRefused.insert(track.url)
                    item = try await makeItem(track)
                    guard loadToken == token else { return }
                    await engine.prepareOutput(for: item)
                    guard loadToken == token else { return }
                }
                isPreparing = false
                conversionProgress = nil
                engine.load(item, at: seconds, play: autoplay)
                isPlaying = autoplay
                if changed { resetListening() }
                applyASMR()
                outputRevision += 1
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
        guard dopCheck == nil else { return }
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

    /// 再生速度を少し変える (0.5〜2 倍)。ASMR モードとビットパーフェクト再生では等速のまま
    func changeRate(by delta: Double) {
        guard !effectsOff else {
            showToast(asmrMode ? "ASMR モード中は速度を変えられません" : "ビットパーフェクト再生中は速度を変えられません",
                      symbol: asmrMode ? "ear" : "checkmark.seal")
            return
        }
        rate = min(2, max(0.5, ((rate + delta) * 100).rounded() / 100))
        showToast("速度 \(rateLabel(rate))", symbol: "gauge.with.dots.needle.67percent")
    }

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
        // 音を出し始める前に、新しいデバイス側の音量を合わせておく (ビットパーフェクト再生中)
        let target = device?.id ?? AudioOutputs.defaultDeviceID()
        dopRefused.removeAll()
        moveBitPerfectVolume(to: target, uid: device?.uid ?? outputDevices.first { $0.id == target }?.uid ?? "default")
        outputDeviceUID = device?.uid
        Defaults.set("outputDevice", device?.uid)
        let pos = clock.position, wasPlaying = isPlaying
        engine.setOutputDevice(device?.id)
        applyDeviceProfile()
        outputRevision += 1
        if exclusiveMode {
            // 排他モードは、新しいデバイスで取り直す (終わったら読み込み直す)
            applyExclusiveMode()
        } else if let t = currentTrack, engine.current != nil {
            play(t, at: pos, autoplay: wasPlaying)
        }
    }

    // MARK: - エンジン連携

    private func makeItem(_ track: Track) async throws -> PlaybackItem {
        if wantsDoP(track) {
            do {
                let file = try AVAudioFile(forReading: try await dopURL(for: track.url))
                return PlaybackItem(trackID: track.id, file: file, source: track.url, start: track.start ?? 0, end: track.end,
                                    gain: 1, isDoP: true)
            } catch {
                // DoP に包めなかった曲は、PCM に変換して再生する
                dopRefused.insert(track.url)
            }
        }
        let url = try await playableURL(for: track.url)
        let file = try AVAudioFile(forReading: url)
        return PlaybackItem(trackID: track.id, file: file, source: track.url, start: track.start ?? 0, end: track.end, gain: gain(for: track))
    }

    private func gain(for t: Track) -> Float {
        // ビットパーフェクト再生では、音量をそろえるためのゲインも掛けない
        if bitPerfect { return 1 }
        let m = t.meta
        var (g, p): (Double?, Double?) = switch replayGain {
        case .off: (nil, nil)
        case .track: (m.rgTrackGain ?? m.rgAlbumGain, m.rgTrackPeak ?? m.rgAlbumPeak)
        case .album: (m.rgAlbumGain ?? m.rgTrackGain, m.rgAlbumPeak ?? m.rgTrackPeak)
        }
        // タグがない曲は、測ってあればその値でそろえる (ASMR モードでは、音量のならしに任せる)
        if g == nil, usesLoudnessScan, let measured = measuredLoudness(for: t), let gain = measured.gainDB {
            (g, p) = (gain, measured.peak)
        }
        guard let g else { return 1 }
        var linear = pow(10, g / 20)
        if let p, p > 0 { linear = min(linear, 1 / p) }
        return Float(linear)
    }

    // MARK: - ラウドネスの解析

    private var usesLoudnessScan: Bool { loudnessScan && replayGain != .off && !effectsOff }

    /// 今の曲の、音量をそろえるためのゲイン (dB) と、その出どころ
    var currentGainInfo: (db: Double, source: String)? {
        guard let item = engine.current, abs(item.gain - 1) > 0.0005, let t = currentTrack else { return nil }
        let tagged = t.meta.rgTrackGain != nil || t.meta.rgAlbumGain != nil
        return (20 * log10(Double(item.gain)), tagged ? "ReplayGain" : "解析した大きさ")
    }

    /// 測ってある大きさ (まだ測っていなければ nil)
    func measuredLoudness(for t: Track) -> LoudnessResult? {
        guard let source = playable[t.url] ?? (Importer.mediaExtensions.contains(t.url.pathExtension.lowercased()) ? t.url : nil),
              let key = LoudnessScanner.key(for: source, start: t.start) else { return nil }
        return loudness[key]
    }

    /// 曲の大きさを測る (曲の情報のパネルから呼ぶ)
    func measureLoudness(_ t: Track) async {
        if await scanLoudness(t) == nil {
            showToast("大きさを測れませんでした: \(t.fileName)", symbol: "exclamationmark.triangle")
        }
    }

    private func needsLoudness(_ t: Track) -> Bool {
        usesLoudnessScan && t.meta.rgTrackGain == nil && t.meta.rgAlbumGain == nil
    }

    /// 曲の大きさを測る (測ってあれば何もしない)。結果は保存する
    @discardableResult
    private func scanLoudness(_ t: Track) async -> LoudnessResult? {
        guard let source = try? await playableURL(for: t.url),
              let key = LoudnessScanner.key(for: source, start: t.start) else { return nil }
        if let known = loudness[key] { return known }
        if let running = loudnessInFlight[key] { return await running.value }
        let (start, end) = (t.start, t.end)
        let task = Task.detached(priority: .utility) { LoudnessScanner.measure(source, start: start, end: end) }
        loudnessInFlight[key] = task
        let result = await task.value
        loudnessInFlight[key] = nil
        if let result {
            loudness.set(result, for: key)
            let store = loudness, dir = Self.supportDirectory
            Task.detached(priority: .utility) { store.save(to: dir) }
        }
        return result
    }

    /// 再生の前に、必要なら大きさを測っておく。長い曲は待たずに裏で測り、次に再生するときから使う
    private func ensureLoudness(for t: Track) async {
        guard needsLoudness(t) else { return }
        if (t.duration ?? 0) <= 20 * 60 {
            await scanLoudness(t)
        } else {
            Task { await scanLoudness(t) }
        }
    }

    // MARK: - 再生回数・お気に入り

    private func resetListening() {
        listened = 0
        counted = false
        lastListenTick = 0
    }

    /// 聴いた時間を足し、曲の半分 (または 4 分) を聴いたら 1 回の再生として数える
    private func trackListening() {
        let now = CACurrentMediaTime()
        defer { lastListenTick = now }
        guard isPlaying, lastListenTick > 0, now - lastListenTick < 1, !counted, let t = currentTrack else { return }
        listened += (now - lastListenTick) * effectiveRate
        if PlayStats.counts(listened: listened, duration: clock.duration) {
            counted = true
            stats.recordPlay(t.bookmarkKey)
            saveStats()
        }
    }

    var isCurrentFavorite: Bool { currentTrack.map { stats[$0.bookmarkKey].favorite } ?? false }

    func isFavorite(_ track: Track) -> Bool { stats[track.bookmarkKey].favorite }

    func toggleFavorite(_ track: Track? = nil) {
        guard let t = track ?? currentTrack else { return }
        let on = !stats[t.bookmarkKey].favorite
        stats.setFavorite(t.bookmarkKey, on)
        saveStats()
        if track == nil { showToast(on ? "お気に入りに追加しました" : "お気に入りから外しました", symbol: on ? "heart.fill" : "heart") }
    }

    private func saveStats() {
        let all = stats, dir = Self.supportDirectory
        Task.detached(priority: .utility) { all.save(to: dir) }
    }

    // MARK: - パラメトリック EQ

    /// 今の出力デバイスを表す ID (システムの設定に従うときは、そのときの既定のデバイス)
    var currentOutputUID: String {
        if let uid = outputDeviceUID { return uid }
        let id = engine.outputDeviceID
        return outputDevices.first { $0.id == id }?.uid ?? "default"
    }

    var activeProfile: EQProfile? { eqProfiles.first { $0.id == activeProfileID } }

    /// 設定を追加して、使うものにする
    func addProfile(_ profile: EQProfile) {
        eqProfiles.append(profile)
        activeProfileID = profile.id
    }

    func updateProfile(_ profile: EQProfile) {
        guard let i = eqProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
        eqProfiles[i] = profile
    }

    func removeProfile(_ id: UUID) {
        eqProfiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = nil }
    }

    /// AutoEQ (Equalizer APO 形式) の設定ファイルを読み込む
    func importAutoEQ(from url: URL) {
        guard let text = TextDecoding.readText(at: url), let parsed = EQDesign.parseAutoEQ(text) else {
            showToast("EQ の設定として読み込めませんでした: \(url.lastPathComponent)", symbol: "exclamationmark.triangle")
            return
        }
        var name = url.deletingPathExtension().lastPathComponent
        for suffix in [" ParametricEQ", " parametric", "_ParametricEQ"] where name.hasSuffix(suffix) { name.removeLast(suffix.count) }
        addProfile(EQProfile(name: name, preamp: parsed.preamp, bands: Array(parsed.bands.prefix(ASMRShared.eqBands - 1))))
        showToast("「\(name)」を読み込みました（\(parsed.bands.count) バンド）", symbol: "headphones")
    }

    /// 出力デバイスが変わったとき: そのデバイス用に覚えている設定へ切り替える
    private func applyDeviceProfile() {
        guard let stored = deviceProfiles[currentOutputUID] else { return }
        let id = UUID(uuidString: stored)
        if id != activeProfileID, id == nil || eqProfiles.contains(where: { $0.id == id }) { activeProfileID = id }
    }

    // MARK: - 出力までの道筋

    /// 排他モードを取る / 手放す (少し時間がかかる)。終わったら、今の曲を同じ位置から読み込み直す
    private func applyExclusiveMode() {
        let wasPlaying = isPlaying
        let position = clock.position
        switchingExclusive = true
        Task {
            let ok = await engine.setExclusiveMode(exclusiveMode)
            switchingExclusive = false
            dopRefused.removeAll()
            outputRevision += 1
            if exclusiveMode, !ok {
                showToast("排他モードにできませんでした（ほかのアプリが使っているか、このデバイスは対応していません）", symbol: "exclamationmark.triangle")
            }
            if let t = currentTrack, engine.current != nil { play(t, at: position, autoplay: wasPlaying) }
        }
    }

    // MARK: - ビットパーフェクト再生

    /// ビットパーフェクト再生を切り替える。
    /// 入るときは、アプリの音量を最大にする代わりに、同じ分だけ出力デバイス側の音量を下げて、聞こえる大きさを保つ。
    /// デバイス側で下げきれず音が大きくなるときは、切り替える前に確かめる
    func setBitPerfect(_ on: Bool, quietly: Bool = false) {
        guard on != bitPerfect else { return }
        let device = engine.outputDeviceID
        if on {
            // 消音中でも同じように扱う (消音を解いたときに、急に大きな音が出ないように)
            let attenuation = DeviceVolumeOffsets.attenuation(ofAppVolume: appVolume)
            let room = device.map { Double(OutputDevice.volumeRoomBelow($0)) } ?? 0
            let expected = OutputDevice.loudnessJump(attenuation: attenuation, room: room)
            if expected > 1, !confirmLouder(by: expected, deviceHasVolume: room > 0) { return }
            // 先にデバイス側を下げてから、アプリの音量を最大にする (逆の順だと、一瞬大きな音が出る)
            var lowered = 0.0
            if attenuation > 0.05, let device { lowered = Double(-OutputDevice.adjustVolume(device, byDB: Float(-attenuation))) }
            // 見込みどおりに下げられなかったときも、切り替える前に確かめる (やめるなら、下げた分を戻す)
            if expected <= 1, attenuation - lowered > 1.5, !confirmLouder(by: attenuation - lowered, deviceHasVolume: room > 0) {
                if lowered > 0.05, let device { OutputDevice.adjustVolume(device, byDB: Float(lowered)) }
                return
            }
            if asmrMode {
                asmrMode = false
                bitPerfectSuspendedASMR = true
            } else {
                bitPerfectSuspendedASMR = false
            }
            bitPerfectOffsets.record(currentOutputUID, db: lowered)
            bitPerfect = true
            applyBitPerfect()
            if !quietly {
                showToast(deviceVolume == nil
                          ? "ビットパーフェクト再生: 音を変える処理をすべて外しました（音量はアンプなどデバイス側で調整してください）"
                          : "ビットパーフェクト再生: 音を変える処理をすべて外しました（音量はデバイス側の音量を動かします）",
                          symbol: "checkmark.seal")
            }
        } else {
            bitPerfect = false
            applyBitPerfect()
            // デバイス側で下げていた音量を元に戻す。今のデバイスは、アプリの音量が下がりきってから (逆の順だと、一瞬大きな音が出る)
            let current = currentOutputUID
            for (uid, db) in bitPerfectOffsets.takeAll() where db > 0.05 {
                guard let id = outputDevices.first(where: { $0.uid == uid })?.id ?? (uid == current ? device : nil) else { continue }
                if uid == current {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                        guard let self, !self.bitPerfect, self.engine.outputDeviceID == id else { return }
                        OutputDevice.adjustVolume(id, byDB: Float(db))
                        self.readDeviceVolume()
                    }
                } else {
                    OutputDevice.adjustVolume(id, byDB: Float(db))
                }
            }
            if bitPerfectSuspendedASMR {
                bitPerfectSuspendedASMR = false
                if !asmrMode { asmrMode = true }
            }
            if !quietly { showToast("ビットパーフェクト再生を終了しました（EQ などの設定は元のまま使われます）", symbol: "checkmark.seal") }
        }
    }

    /// ビットパーフェクト再生中に出力デバイスが変わる: アプリの音量で下げていた分を、新しいデバイス側で下げ直す
    /// (デバイス側の音量は、デバイスごとに別々なので)。使わなくなったデバイスの音量は元に戻す。
    /// 新しいデバイスで下げきれないなら、急に大きな音が出ないよう、ビットパーフェクト再生を解除する
    private func moveBitPerfectVolume(to device: AudioDeviceID?, uid: String) {
        guard bitPerfect, let device else { return }
        for other in bitPerfectOffsets.devices where other != uid {
            // 外されているデバイスは、戻せないので覚えたままにする (またつないだときに、二重に下げないため)
            guard let id = outputDevices.first(where: { $0.uid == other })?.id, let db = bitPerfectOffsets.take(other) else { continue }
            if db > 0.05 { OutputDevice.adjustVolume(id, byDB: Float(db)) }
        }
        guard !bitPerfectOffsets.isLowered(uid) else { return }
        let attenuation = DeviceVolumeOffsets.attenuation(ofAppVolume: appVolume)
        let room = Double(OutputDevice.volumeRoomBelow(device))
        guard OutputDevice.loudnessJump(attenuation: attenuation, room: room) <= 1 else {
            setBitPerfect(false, quietly: true)
            showToast("出力デバイスが変わったので、ビットパーフェクト再生を解除しました（このデバイスでは音量を下げきれず、大きな音が出てしまうため）",
                      symbol: "exclamationmark.triangle")
            return
        }
        let lowered = attenuation > 0.05 ? Double(-OutputDevice.adjustVolume(device, byDB: Float(-attenuation))) : 0
        bitPerfectOffsets.record(uid, db: lowered)
    }

    /// ビットパーフェクト再生かどうかで変わる設定を、すべてエンジンへ渡し直す。今の曲は同じ位置から読み込み直す
    private func applyBitPerfect() {
        applyVolume()
        applyEQ()
        applyRate()
        applyBalance()
        engine.crossfadeDuration = bitPerfect ? 0 : crossfade
        applyOutputPolicy()
        dopRefused.removeAll()
        engine.invalidateUpcoming()
        reloadForOutputChange()
    }

    /// デバイスの形式をどう切り替えるかを、エンジンへ渡す。どれも使わなくなったら、デバイスを元の形式に戻す
    private func applyOutputPolicy() {
        engine.matchSampleRate = matchSampleRate || bitPerfect
        // 変換が入るので、ビットパーフェクト再生中はアップサンプリングしない
        engine.upsampling = bitPerfect ? .off : upsampling
        if !engine.matchSampleRate, engine.upsampling == .off { engine.restoreOutputDevice() }
    }

    /// アプリの音量を最大にすると音が大きくなるときに、切り替えてよいかを確かめる
    private func confirmLouder(by db: Double, deviceHasVolume: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "音が大きくなります"
        let name = engine.outputInfo.name
        let reason = deviceHasVolume
            ? "アプリの音量で下げていた分を、「\(name)」の音量だけでは下げきれません。"
            : "「\(name)」の音量は、Mac からは変えられません。"
        alert.informativeText = "ビットパーフェクト再生では、アプリの音量を最大にします。\(reason)切り替えると、今より約 \(Int(db.rounded())) dB 大きな音で再生されます。\n\nアンプやヘッドホンの音量を下げてから切り替えてください。"
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "切り替える")
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - DSD のネイティブ再生 (DoP)

    /// 今、DoP で送っているか
    var dopActive: Bool {
        _ = outputRevision
        return engine.current?.isDoP == true
    }

    private func dsdInfo(_ url: URL) -> DSDFile.Info? {
        guard DSDFile.extensions.contains(url.pathExtension.lowercased()) else { return nil }
        if let cached = dsdInfoCache[url] { return cached }
        let info = DSDFile.info(url)
        dsdInfoCache[url] = info
        return info
    }

    /// 今の出力デバイスが、DoP のサンプルレート (rate) で受け付ける整数の形式のうち、ビット数のいちばん多いもの
    private func integerBits(at rate: Double) -> Int? {
        guard let device = engine.outputDeviceID, let current = OutputDevice.physicalFormat(device) else { return nil }
        return OutputDevice.availablePhysicalFormats(device, rate: rate)
            .filter { !$0.isFloat && $0.channels == current.channels && $0.mixable == current.mixable }.map(\.bits).max()
    }

    private func dopConditions(rate: Double) -> DoP.Conditions {
        let device = engine.outputDeviceID
        return DoP.Conditions(enabled: dopEnabled, bitPerfect: bitPerfect, exclusive: engine.isExclusive && !switchingExclusive,
                              support: dopDevices[currentOutputUID],
                              deviceRates: device.map(OutputDevice.availableSampleRates) ?? [],
                              integerBits: integerBits(at: rate), deviceVolume: deviceVolume)
    }

    /// この曲を DoP で送るか、PCM に変換して再生するか (送らない理由つき)
    func dopPlan(for track: Track) -> DoP.Plan {
        guard let info = dsdInfo(track.url) else { return .convert(reason: nil) }
        return DoP.plan(for: info, dopConditions(rate: DoP.pcmRate(forDSD: info.sampleRate)))
    }

    private func wantsDoP(_ track: Track) -> Bool {
        if case .send = dopPlan(for: track) { return !dopRefused.contains(track.url) }
        return false
    }

    /// DSD のファイルを DoP に包んだファイル (なければ作る)
    private func dopURL(for source: URL) async throws -> URL {
        if let url = dopFiles[source], FileManager.default.fileExists(atPath: url.path) { return url }
        if let running = dopConversions[source] { return try await running.value }
        let task = Task.detached(priority: .userInitiated) { try DoP.convert(source) }
        dopConversions[source] = task
        defer { dopConversions[source] = nil }
        let url = try await task.value
        dopFiles[source] = url
        return url
    }

    /// 今の出力デバイスで DoP を確かめられない理由 (確かめられるなら nil)
    var dopCheckBlocker: String? {
        _ = outputRevision
        guard engine.outputDeviceID != nil else { return "出力デバイスがありません" }
        let conditions = dopConditions(rate: 176_400)
        if !conditions.deviceRates.contains(where: { abs($0 - 176_400) < 0.5 }) || (conditions.integerBits ?? 0) < 24 {
            return "このデバイスは 176.4kHz / 24bit の出力に対応していないので、DoP は使えません"
        }
        if !bitPerfect { return "ビットパーフェクト再生をオンにすると、確かめられます" }
        if !conditions.exclusive { return "排他モードをオンにすると、確かめられます" }
        return nil
    }

    /// 今の出力デバイスの確認結果
    var dopSupport: DoP.Support? {
        _ = outputRevision
        return dopDevices[currentOutputUID]
    }

    /// DoP の対応の確認を始める: 再生を止め、デバイス側の音量を小さくしておく (30 dB 下げる)。
    /// 対応していない DAC では雑音として鳴るので、最初は小さい音量で鳴らし、聞こえなければ少しずつ上げてもらう
    func beginDoPCheck() {
        guard dopCheck == nil, dopCheckBlocker == nil, let device = engine.outputDeviceID else { return }
        if let id = currentID { dopCheckResume = (id, clock.position) }
        engine.pause(immediately: true)
        isPlaying = false
        updateNowPlayingInfo()
        let original = deviceVolume
        if original != nil { OutputDevice.adjustVolume(device, byDB: -30) }
        dopCheck = DoPCheck(device: currentOutputUID, originalVolume: original)
        readDeviceVolume()
    }

    /// 確認用の音を鳴らす (440Hz の「ポー」という音が 4 回)
    func playDoPCheckTone() {
        guard var check = dopCheck, !check.playing else { return }
        check.message = nil
        check.playing = true
        dopCheck = check
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) { try DoP.testToneURL() }.value
                let item = PlaybackItem(trackID: dopCheckID, file: try AVAudioFile(forReading: url), source: url, start: 0, end: nil,
                                        gain: 1, isDoP: true)
                await engine.prepareOutput(for: item)
                guard dopCheck != nil else { return }
                guard engine.dopReady(for: item) else {
                    dopCheck?.playing = false
                    dopCheck?.message = "デバイスを 176.4kHz / 24bit に切り替えられませんでした"
                    return
                }
                engine.load(item, play: true)
                outputRevision += 1
            } catch {
                dopCheck?.playing = false
                dopCheck?.message = "確認用の音を用意できませんでした: \(error.localizedDescription)"
            }
        }
    }

    /// 確認中の音量を少し上げる (6 dB ずつ。確認を始める前の音量までしか上げない)
    func raiseDoPCheckVolume() {
        guard let check = dopCheck, let original = check.originalVolume, let device = engine.outputDeviceID else { return }
        OutputDevice.adjustVolume(device, byDB: 6)
        if let now = OutputDevice.volume(device), Double(now) > original { OutputDevice.setVolume(device, Float(original)) }
        readDeviceVolume()
    }

    /// 確認中に、これ以上音量を上げられるか
    var canRaiseDoPCheckVolume: Bool {
        guard let check = dopCheck, check.step == .quiet, let original = check.originalVolume, let now = deviceVolume else { return false }
        return now < original - 0.001
    }

    /// 聞こえ方の答えを受け取って、次の段階へ進む
    func answerDoPCheck(_ answer: DoPCheck.Answer) {
        guard var check = dopCheck else { return }
        stopDoPCheckTone()
        check.playing = false
        check.message = nil
        switch (check.step, answer) {
        case (.quiet, .clean):
            check.step = .done(.verified)
        case (.full, .clean):
            check.step = .done(.verifiedAtFullVolume)
        case (.quiet, .nothing) where canRaiseDoPCheckVolume || check.originalVolume == nil:
            check.message = check.originalVolume == nil
                ? "アンプやヘッドホンの音量を少し上げて、もう一度鳴らしてください"
                : "「少し大きく」を押してから、もう一度鳴らしてください"
        case (.quiet, _) where check.originalVolume != nil:
            // 音量を下げると DoP が通らない DAC かもしれない: 音量を最大にして試すかを尋ねる
            check.step = .askFull
        default:
            check.step = .done(.unsupported)
        }
        if case .done(let result) = check.step {
            dopDevices[check.device] = result
            restoreDoPCheckVolume(check)
        }
        dopCheck = check
        outputRevision += 1
    }

    /// DAC の音量を最大にして、もう一度確かめる (アンプ側の音量を絞ってから使ってもらう)
    func retryDoPCheckAtFullVolume() {
        guard var check = dopCheck, check.step == .askFull, let device = engine.outputDeviceID else { return }
        OutputDevice.setVolume(device, 1)
        readDeviceVolume()
        check.step = .full
        dopCheck = check
    }

    /// 最大にして試すのをやめて、「対応していない」として終える
    func giveUpDoPCheck() {
        guard var check = dopCheck else { return }
        stopDoPCheckTone()
        check.step = .done(.unsupported)
        check.playing = false
        dopDevices[check.device] = .unsupported
        restoreDoPCheckVolume(check)
        dopCheck = check
        outputRevision += 1
    }

    /// 確認を終える (途中でやめるときも): デバイス側の音量を元に戻し、止めていた曲を同じ位置に読み込み直す
    func endDoPCheck(resume: Bool = true) {
        guard let check = dopCheck else { return }
        stopDoPCheckTone()
        restoreDoPCheckVolume(check)
        dopCheck = nil
        dopRefused.removeAll()
        outputRevision += 1
        let point = dopCheckResume
        dopCheckResume = nil
        if resume, let point, let track = track(point.id) { play(track, at: point.position, autoplay: false) }
    }

    /// 開発用の画面の書き出しで、確認の途中の画面を出すためのもの (実際の確認は始めない)
    func previewDoPCheck(_ check: DoPCheck?) { dopCheck = check }

    /// 確認結果を消して、「未確認」に戻す
    func forgetDoPSupport() {
        dopDevices[currentOutputUID] = nil
        dopRefused.removeAll()
        engine.invalidateUpcoming()
        reloadForOutputChange()
    }

    private func stopDoPCheckTone() {
        if engine.current?.trackID == dopCheckID { engine.stop() }
    }

    private func restoreDoPCheckVolume(_ check: DoPCheck) {
        guard let original = check.originalVolume, let device = engine.outputDeviceID, currentOutputUID == check.device else { return }
        OutputDevice.setVolume(device, Float(original))
        readDeviceVolume()
    }

    /// 出力デバイス側の音量を読み直す (デバイスが変わっていれば、見張る先も切り替える)
    private func refreshDeviceVolume() {
        deviceVolumeObserver.observe(engine.outputDeviceID)
        readDeviceVolume()
    }

    private func readDeviceVolume() {
        let value = engine.outputDeviceID.flatMap(OutputDevice.volume).map(Double.init)
        if value != deviceVolume { deviceVolume = value }
        // 音量を下げると DoP が通らない DAC で、DoP の途中に音量が下げられた: 雑音になるので、PCM に変換した再生へ切り替える
        if dopCheck == nil, dopActive, let t = currentTrack, !wantsDoP(t) { reloadForOutputChange() }
    }

    /// ビットパーフェクト再生中で、音量スライダーを動かせない状態か。
    /// 音量を Mac から変えられないデバイスを使っているときと、音量を下げると DoP が通らない DAC へ DoP を送っているとき
    var volumeLocked: Bool {
        bitPerfect && (deviceVolume == nil || (dopActive && dopDevices[currentOutputUID] == .verifiedAtFullVolume))
    }

    /// ビットパーフェクト再生にしているのに、元のデータのままでは出力できていないときの理由
    var bitPerfectShortfall: String? {
        guard bitPerfect, let path = signalPath else { return nil }
        switch path.quality {
        case .bitPerfect, .dsdNative, .volumeOnly: return nil   // 音量だけ = 消音中
        case .resampled: return "出力デバイスを曲のサンプルレートに合わせられないため、サンプルレートを変換しています"
        case .reduced: return "出力デバイスを曲のビット深度に合わせられないため、ビット数を減らして出力しています"
        case .processed:
            guard let track = currentTrack, case .convert(let reason) = dopPlan(for: track), dsdInfo(track.url) != nil else {
                return "この音源は PCM に変換してから再生するため、元のデータのままにはなりません"
            }
            return "DSD を PCM に変換して再生しています" + (reason.map { "（\($0)）" } ?? "（「DSD・変換」タブで、そのまま送る設定にできます）")
        }
    }

    /// エンジンを始められなかった: 再生中の表示のまま固まらないよう、止めて知らせる
    private func engineFailedToStart() {
        isPlaying = false
        updateNowPlayingInfo()
        showToast("出力デバイスで再生を始められませんでした。出力デバイスの設定を確かめてください", symbol: "exclamationmark.triangle")
    }

    /// 出力デバイスまわりの設定を変えたあと、今の曲を読み込み直す
    private func reloadForOutputChange() {
        outputRevision += 1
        guard let t = currentTrack, engine.current != nil else { return }
        play(t, at: clock.position, autoplay: isPlaying)
    }

    /// 加工で音が大きくなりうるか (クリップ防止を働かせるかどうかの判断に使う)
    private var mayExceedFullScale: Bool {
        if eqEnabled, eqPreamp > 0 || eqBands.contains(where: { $0 > 0 }) { return true }
        if let profile = activeProfile, !profile.isFlat { return true }
        if crossfeed != .off || effectiveRate != 1 || pitch != 0 { return true }
        return (engine.current?.gain ?? 1) > 1.0005
    }

    var signalPath: SignalPath? {
        _ = outputRevision
        guard let t = currentTrack else { return nil }
        let m = t.meta
        let playing = engine.current?.trackID == t.id ? engine.current : nil
        let dsd = dsdInfo(t.url)
        let dop = playing?.isDoP == true
        var parts: [String] = []
        let fileRate = playing?.sampleRate ?? m.sampleRate ?? 0
        if let dsd, dop || m.codec == nil {
            parts = ["DSD", dsd.label, String(format: "%.1fMHz", dsd.sampleRate / 1_000_000)]
        } else {
            if let codec = m.codec { parts.append(codec) }
            if let bits = m.bitDepth, bits > 1 { parts.append("\(bits)bit") }
            if m.bitDepth == 1, let dsd { parts.append(dsd.label) } else if fileRate > 0 { parts.append(Self.sampleRateLabel(fileRate)) }
            if let br = m.bitrate, m.lossless != true, br > 0 { parts.append("\(br / 1000)kbps") }
        }

        var stages: [SignalPath.Stage] = []
        if dop {
            stages.append(.init(name: "DoP", detail: "DSD のまま 24bit の PCM に包んで送る（加工なし）", symbol: "shippingbox"))
        } else if m.bitDepth == 1 || dsd != nil {
            var detail = "DSD → PCM"
            if case .convert(let reason?) = dopPlan(for: t) { detail += "（\(reason)）" }
            stages.append(.init(name: "PCM への変換", detail: detail, symbol: "waveform.path"))
        }
        if let gain = currentGainInfo {
            stages.append(.init(name: "音量の均一化", detail: String(format: "%@ %+.1f dB", gain.source, gain.db), symbol: "speaker.wave.2"))
        }
        if bitPerfect {
            // 音を変える処理は、どれも通さない
        } else if !asmrMode {
            if eqEnabled, eqPreamp != 0 || eqBands.contains(where: { $0 != 0 }) {
                stages.append(.init(name: "イコライザー", detail: eqPresetName, symbol: "slider.vertical.3"))
            }
            if let profile = activeProfile, !profile.isFlat {
                stages.append(.init(name: "パラメトリック EQ", detail: profile.name, symbol: "headphones"))
            }
            if effectiveRate != 1 || pitch != 0 {
                stages.append(.init(name: "速度・キー", detail: rateLabel(effectiveRate) + (pitch != 0 ? String(format: " / %+.0f", pitch) : ""), symbol: "gauge.with.dots.needle.67percent"))
            }
            if balance != 0 { stages.append(.init(name: "バランス", detail: balance < 0 ? "左寄り" : "右寄り", symbol: "slider.horizontal.below.rectangle")) }
            if crossfeed != .off { stages.append(.init(name: "クロスフィード", detail: crossfeed.label, symbol: "ear")) }
            if clipGuard, mayExceedFullScale { stages.append(.init(name: "クリップ防止", detail: "-0.1 dBFS", symbol: "waveform.badge.exclamationmark")) }
        } else {
            stages.append(.init(name: "ASMR モード", detail: "音量のならし（\(asmrStrength.label)）・リミッター", symbol: "ear"))
        }
        let chainRate = engine.chainSampleRate
        let resampled = fileRate > 0 && abs(fileRate - chainRate) > 0.5
        if resampled {
            // 設定で整数倍に上げているときは「アップサンプリング」、デバイスが合わせられなかったときは「サンプルレート変換」
            let ratio = chainRate / fileRate
            let upsampled = engine.upsampling != .off && ratio > 1.5 && abs(ratio - ratio.rounded()) < 1e-6
            stages.append(.init(name: upsampled ? "アップサンプリング" : "サンプルレート変換",
                                detail: "\(Self.sampleRateLabel(fileRate)) → \(Self.sampleRateLabel(chainRate))（マスタリング品質）",
                                symbol: upsampled ? "arrow.up.right.circle" : "arrow.triangle.2.circlepath"))
        }
        let softVolume = muted || (!bitPerfect && appVolume < 0.9995)
        if softVolume {
            stages.append(.init(name: "音量", detail: muted ? "消音" : String(format: "%.1f dB", 40 * log10(max(appVolume, 0.0001))), symbol: "speaker.wave.1"))
        }
        let info = engine.outputInfo
        // 曲のビット数を、出力までそのまま運べているか (変換したあとの音は、もとのビット数では表せないので見ない)
        let reduction = resampled || dop ? nil : SignalPath.depthReduction(source: playing?.sourceBits, output: info.format?.precision)
        if let reduction {
            stages.append(.init(name: "ビット深度の変換", detail: reduction, symbol: "arrow.down.right.and.arrow.up.left"))
        }
        var output = info.name + " · " + Self.sampleRateLabel(info.rate)
        if let format = info.format, format.bits > 0 { output += " / \(format.bits)bit" + (format.isFloat ? " 浮動小数点" : "") }
        if let transport = info.transport { output += "（\(transport)）" }
        if engine.isExclusive { output += " · 排他" }

        let passive = ["サンプルレート変換", "アップサンプリング", "音量", "ビット深度の変換", "DoP"]
        let processed = stages.contains { !passive.contains($0.name) }
        let quality: SignalPath.Quality = processed ? .processed : resampled ? .resampled
            : reduction != nil ? .reduced : softVolume ? .volumeOnly : dop ? .dsdNative : .bitPerfect
        return SignalPath(source: parts.joined(separator: " · "), stages: stages, output: output, quality: quality)
    }

    static func sampleRateLabel(_ rate: Double) -> String {
        let k = rate / 1000
        return k == k.rounded() ? "\(Int(k))kHz" : String(format: "%.1fkHz", k)
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
        if wantsDoP(next) {
            guard let url = dopFiles[next.url], let file = try? AVAudioFile(forReading: url) else {
                prepareNext()
                return nil
            }
            return PlaybackItem(trackID: next.id, file: file, source: next.url, start: next.start ?? 0, end: next.end, gain: 1, isDoP: true)
        }
        guard let url = playable[next.url] else {
            prepareNext()
            return nil
        }
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return PlaybackItem(trackID: next.id, file: file, source: next.url, start: next.start ?? 0, end: next.end, gain: gain(for: next))
    }

    private func prepareNext() {
        guard let n = nextTrack(after: currentID, auto: true) else { return }
        // 次の曲の大きさも先に測っておく (そのまま続けて再生するときに間に合うように)
        if needsLoudness(n) { Task { await scanLoudness(n) } }
        if wantsDoP(n) {
            if dopFiles[n.url] == nil, dopConversions[n.url] == nil { Task { _ = try? await dopURL(for: n.url) } }
            return
        }
        guard playable[n.url] == nil, conversions[n.url] == nil else { return }
        Task { _ = try? await playableURL(for: n.url) }
    }

    private func didAdvance(to id: UUID) {
        guard id != dopCheckID else { return }
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
        if changed { resetListening() }
        applyASMR()
        outputRevision += 1
        updateNowPlayingInfo()
        prepareNext()
        scheduleSave()
    }

    private func didFinish() {
        if dopCheck != nil {
            // 確認用の音が鳴り終わった
            dopCheck?.playing = false
            return
        }
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
        guard dopCheck == nil else { return }
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
        trackListening()
        // 外部 (コントロールセンター) の位置表示がずれないよう時々同期
        if abs(position - lastNowPlayingSync) > 5 { updateNowPlayingInfo() }
    }

    private func reloadAfterDeviceChange() {
        refreshOutputDevices()
        dopRefused.removeAll()
        // 確認の途中でデバイスが変わったら、確認はやめる
        if let check = dopCheck, check.device != currentOutputUID { endDoPCheck(resume: false) }
        moveBitPerfectVolume(to: engine.outputDeviceID, uid: currentOutputUID)
        applyDeviceProfile()
        outputRevision += 1
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
        engine.volume = muted ? 0 : bitPerfect ? 1 : Float(appVolume)
        if asmrMode, asmrLoudness { applyASMR() }
    }

    private func applyEQ() {
        engine.setEQ(bands: eqBands, preamp: eqPreamp, enabled: eqEnabled && !effectsOff)
        applyASMR()
    }

    private func applyRate() {
        engine.rate = Float(effectiveRate)
        engine.pitch = effectsOff ? 0 : Float(pitch)
        applyASMR()
        updateNowPlayingInfo()
    }

    private func applyBalance() { engine.balance = effectsOff ? 0 : Float(balance) }

    /// 最後段の処理ユニットの設定を組み立てる (ASMR モードの処理と、通常の再生でのクロスフィード・クリップ防止・パラメトリック EQ)
    private func applyASMR() {
        if bitPerfect {
            // 何も加工しない (処理ユニットは、音を 1 ビットも変えずに通す)
            engine.asmrSettings = ASMRSettings()
            engine.softTransitions = false
            engine.eqProfile = nil
            return
        }
        var s = ASMRSettings()
        // 「処理前の音と比べる」の間は、音量のならしなどを外す (左右の入れ替えとリミッターは残す)
        let processing = asmrMode && !asmrCompare
        s.dynamics = processing
        s.swap = asmrMode && swapChannels
        asmrStrength.apply(to: &s, custom: asmrCustom)
        (processing ? asmrSoftening : .off).apply(to: &s)
        if processing {
            (s.loudnessLow, s.loudnessHigh) = loudnessBoost
            s.lowCut = Float(asmrLowCut)
        }
        if asmrMode {
            s.limiter = true
        } else {
            if let feed = crossfeed.parameters { (s.crossfeedCut, s.crossfeedLevel) = feed }
            // 加工していないときはリミッターも入れず、元の音を 1 ビットも変えない
            s.limiter = clipGuard && mayExceedFullScale
            s.ceiling = 0.9886   // -0.1 dBFS
        }
        engine.asmrSettings = s
        engine.softTransitions = asmrMode
        engine.eqProfile = asmrMode ? nil : activeProfile
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
                let meta = await DLsiteCatalog.shared.filled(await MetadataReader.read(url), for: url)
                metaInFlight.remove(url)
                metaBuffer[url] = meta
                scheduleMetaFlush()
                pumpMetadata()
            }
        }
    }

    /// 読み込み済みの曲のうち、アーティストなどが空のものを、DLsite の作品情報で埋める (設定が有効なときだけ)
    func fillFromDLsite() {
        guard dlsiteInfo else { return }
        let targets = queue.filter { $0.meta.loaded && DLsiteWork.wants($0.meta) && ArtworkFinder.workCode(for: $0.url) != nil }
        guard !targets.isEmpty else { return }
        Task {
            var updates: [UUID: TrackMeta] = [:]
            for t in targets {
                let filled = await DLsiteCatalog.shared.filled(t.meta, for: t.url)
                if filled != t.meta { updates[t.id] = filled }
            }
            guard !updates.isEmpty else { return }
            var q = queue
            for i in q.indices { if let filled = updates[q[i].id] { q[i].meta = filled } }
            preservingNext { queue = q }
            updateNowPlayingInfo()
            scheduleSave()
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
            q[i].meta = q[i].merging(m)
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
    static func codable<T: Decodable>(_ k: String) -> T? { data(k).flatMap { try? JSONDecoder().decode(T.self, from: $0) } }
    static func setCodable<T: Encodable>(_ k: String, _ v: T) { set(k, try? JSONEncoder().encode(v)) }
    static func set(_ k: String, _ v: Any?) { UserDefaults.standard.set(v, forKey: k) }
}
