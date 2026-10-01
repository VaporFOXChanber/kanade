import AVFoundation
import QuartzCore

/// 再生する 1 区間 (トラック全体、または CUE の範囲)
struct PlaybackItem {
    let trackID: UUID
    let file: AVAudioFile
    let source: URL
    let start: Double
    let end: Double?
    /// ReplayGain などのトラック別ゲイン (リニア)
    let gain: Float

    var sampleRate: Double { file.processingFormat.sampleRate }
    /// 元のデータのビット深度 (整数の PCM とロスレス圧縮だけ。MP3 などの圧縮音源や浮動小数点の音源は nil)
    var sourceBits: Int? {
        let d = file.fileFormat.streamDescription.pointee
        switch d.mFormatID {
        case kAudioFormatLinearPCM: return d.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? nil : Int(d.mBitsPerChannel)
        case kAudioFormatFLAC, kAudioFormatAppleLossless: return [1: 16, 2: 20, 3: 24, 4: 32][d.mFormatFlags]
        default: return nil
        }
    }
    var startFrame: AVAudioFramePosition { min(file.length, AVAudioFramePosition(start * sampleRate)) }
    var endFrame: AVAudioFramePosition {
        guard let end else { return file.length }
        return min(file.length, AVAudioFramePosition(end * sampleRate))
    }
    var duration: Double { Double(max(0, endFrame - startFrame)) / sampleRate }

    func continues(_ other: PlaybackItem) -> Bool {
        source == other.source && abs(startFrame - other.endFrame) < 16
    }
}

/// AVAudioPlayerNode 1 系統分。2 つ用意してクロスフェードと形式の異なる曲の切り替えに使う。
final class Deck {
    struct Segment {
        let item: PlaybackItem
        let startFrame: AVAudioFramePosition
        let frameCount: AVAudioFramePosition
        let offset: AVAudioFramePosition
        var end: AVAudioFramePosition { offset + frameCount }
    }

    let player = AVAudioPlayerNode()
    let bus: AVAudioNodeBus
    var format: AVAudioFormat?
    private(set) var segments: [Segment] = []
    private(set) var generation = 0
    private var lastSampleTime: AVAudioFramePosition = 0
    var onSegmentPlayed: ((Deck, Int, Segment) -> Void)?

    var fade: Float = 1 { didSet { applyVolume() } }
    var gain: Float = 1 { didSet { applyVolume() } }
    var isLoaded: Bool { !segments.isEmpty }
    var scheduledEnd: AVAudioFramePosition { segments.last?.end ?? 0 }

    init(bus: AVAudioNodeBus) { self.bus = bus }

    private func applyVolume() { player.volume = max(0, fade * gain) }

    func stop() {
        generation += 1
        player.stop()
        segments.removeAll()
        lastSampleTime = 0
    }

    func schedule(_ item: PlaybackItem, from seconds: Double = 0) {
        let sr = item.sampleRate
        let first = item.startFrame + AVAudioFramePosition(max(0, seconds) * sr)
        let startFrame = min(first, max(item.startFrame, item.endFrame - 1))
        let count = max(1, item.endFrame - startFrame)
        let seg = Segment(item: item, startFrame: startFrame, frameCount: count, offset: scheduledEnd)
        segments.append(seg)
        if segments.count == 1 { gain = item.gain }
        let gen = generation
        player.scheduleSegment(item.file, startingFrame: startFrame, frameCount: AVAudioFrameCount(count), at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.onSegmentPlayed?(self, gen, seg)
            }
        }
    }

    /// 現在の再生位置 (プレイヤー時間)
    func sampleTime() -> AVAudioFramePosition {
        if player.isPlaying, let nt = player.lastRenderTime, nt.isSampleTimeValid,
           let pt = player.playerTime(forNodeTime: nt) {
            lastSampleTime = max(0, pt.sampleTime)
        }
        return lastSampleTime
    }

    /// 再生中のセグメントとトラック内の位置 (秒)
    func status() -> (index: Int, segment: Segment, position: Double)? {
        guard !segments.isEmpty else { return nil }
        let t = sampleTime()
        let index = segments.lastIndex { $0.offset <= t } ?? 0
        let seg = segments[index]
        let within = min(max(0, t - seg.offset), seg.frameCount)
        let pos = Double(seg.startFrame - seg.item.startFrame + within) / seg.item.sampleRate
        return (index, seg, pos)
    }
}

/// AVAudioEngine による再生エンジン。
///
///     player A ─┐
///               ├─ mixer ─ EQ(10band) ─ TimePitch ─ Varispeed ─ ASMR ─ main mixer ─ output
///     player B ─┘                                                  └ tap → スペクトラム
///
/// - 同じ形式の次の曲は同じプレイヤーに連結してギャップレス再生
/// - クロスフェード時はもう一方のプレイヤーで次の曲を重ねる
final class AudioEngine {
    static let eqFrequencies: [Float] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    let engine = AVAudioEngine()
    let spectrum = SpectrumAnalyzer()
    private let sum = AVAudioMixerNode()
    private let eq = AVAudioUnitEQ(numberOfBands: 10)
    private let timePitch = AVAudioUnitTimePitch()
    private let varispeed = AVAudioUnitVarispeed()
    /// ASMR モードの処理 (L/R 入れ替え・コンプレッサー・ラウドネス補正・リミッター)。オフのときは素通し
    private let asmr: AVAudioUnitEffect
    private let asmrShared: ASMRShared
    private var loopJumping = false
    /// 左右の確認音。ASMR の処理 (入れ替え) を通さず、出力の左右にそのまま出す
    private let checker = AVAudioPlayerNode()
    private var checkGeneration = 0
    private let decks = [Deck(bus: 0), Deck(bus: 1)]
    private var activeIndex = 0
    private var activeDeck: Deck { decks[activeIndex] }
    private var otherDeck: Deck { decks[1 - activeIndex] }

    private enum Upcoming {
        case chained
        case preloaded(PlaybackItem)
        case crossfade(PlaybackItem)
    }

    private struct Crossfade {
        let from: Deck
        let to: Deck
        var start: CFTimeInterval
        let duration: Double
        var pausedAt: CFTimeInterval?
    }

    private var upcoming: Upcoming?
    private var crossfade: Crossfade?
    private var reportedSegment = -1
    private var timer: Timer?

    private(set) var current: PlaybackItem?
    private(set) var isPlaying = false

    // 設定
    var crossfadeDuration: Double = 0
    var loop: ClosedRange<Double>?
    var volume: Float = 0.8 { didSet { applyVolume() } }
    var fadeMultiplier: Float = 1 { didSet { applyVolume() } }
    var balance: Float = 0 { didSet { decks.forEach { $0.player.pan = balance } } }
    var rate: Float = 1 { didSet { applyRate() } }
    var pitch: Float = 0 { didSet { applyRate() } }
    var preservePitch = true { didSet { applyRate() } }
    var asmrSettings = ASMRSettings() { didSet { publishASMR() } }
    /// 一時停止・再開・シークをフェードでつなぎ、プツッという音を出さない (ASMR モード)
    var softTransitions = false
    /// 音を一時的に絞る値と、そこへ近づく速さ (ASMR の処理ユニットがサンプル単位でなめらかに動かす)
    private var duck: Float = 1
    private var duckTime: Float = 0.006
    private var duckRestart: UInt32 = 0
    private var duckGeneration = 0
    /// フェードアウトが終わるのを待っている一時停止があるか
    private var pausePending = false
    private var pauseGeneration = 0
    /// EQ から出力までの経路のサンプルレート。出力デバイスに合わせる
    private(set) var chainSampleRate: Double = 48000
    private let offline: Bool
    /// 選ばれている出力デバイス (nil ならシステムの設定に従う)
    private var selectedDevice: AudioDeviceID?
    /// デバイスのサンプルレートとビット深度を曲に合わせて切り替える (合えば、サンプルレートの変換もビットの切り捨ても入らない)
    var matchSampleRate = false
    /// 出力デバイスを排他的に使う (ほかのアプリの音が混ざらない)
    /// (切り替えは setExclusiveMode で行う)
    private(set) var exclusiveMode = false
    private var hoggedDevice: AudioDeviceID?
    /// 排他モードの切り替えの途中か (曲の読み込みは、これが終わるのを待つ)
    private var switchingExclusive = false
    /// エンジンを始められなかった (出力デバイスが使えないなど)
    var onStartFailure: (() -> Void)?
    /// こちらで切り替える前の、デバイスのサンプルレートと形式 (終了時に戻す)
    private var originalRates: [AudioDeviceID: Double] = [:]
    private var originalFormats: [AudioDeviceID: AudioStreamBasicDescription] = [:]
    /// こちらでデバイスを切り替えている最中か (終わったあとで読み込み直すので、その間は立て直しをしない)
    private var reconfiguring = false
    /// 出力の構成が変わったあとの確認を予約してあるか
    private var recoveryScheduled = false
    private var lastRecovery: CFTimeInterval = 0
    /// 再生中のはずなのにエンジンが止まっている状態が続いた回数 (tick ごと)
    private var stalledTicks = 0
    /// 直前にこちらで切り替えたサンプルレート (ほかのアプリに戻されたときに、取り合いを続けないため)
    private var lastRateSwitch: (target: Double, time: CFTimeInterval)?
    /// 直前にこちらで切り替えたビット深度 (同じく、取り合いを続けないため)
    private var lastDepthSwitch: (bits: Int, time: CFTimeInterval)?
    /// パラメトリック EQ の設定 (nil なら使わない)
    var eqProfile: EQProfile? { didSet { publishEQ() } }

    /// 少し待ってから実行する (テストでは、描画した時間どおりに進む仮の時計に差し替える)
    var after: (_ seconds: Double, _ work: @escaping () -> Void) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    /// フェードアウトが終わるのを待っているシークの行き先
    private var pendingSeek: Double?

    /// 処理ユニットの状況 (持ち上げ dB, 抑え dB, リミッター dB, 高音のやわらげ dB, 入力の大きさ dBFS, 出力の大きさ dBFS)
    var asmrMeters: (boost: Float, cut: Float, limit: Float, soften: Float, input: Float, output: Float) {
        (asmrShared.meters[0], asmrShared.meters[1], asmrShared.meters[2], asmrShared.meters[3], asmrShared.meters[4], asmrShared.meters[5])
    }

    // コールバック
    /// 次に再生する区間 (準備済みなら返す)
    var provideNext: (() -> PlaybackItem?)?
    /// 再生が次の区間に進んだ
    var onAdvance: ((UUID) -> Void)?
    /// 予定していた区間をすべて再生し終えた
    var onFinished: (() -> Void)?
    var onTick: ((Double, Double) -> Void)?
    var onConfigurationChange: (() -> Void)?

    /// - Parameter offlineFormat: テスト用。指定すると音を出さず、`engine.renderOffline` で描画する
    init(offlineFormat: AVAudioFormat? = nil) {
        offline = offlineFormat != nil
        if let offlineFormat {
            try? engine.enableManualRenderingMode(.offline, format: offlineFormat, maximumFrameCount: 4096)
        }
        ASMRProcessorUnit.register()
        asmr = AVAudioUnitEffect(audioComponentDescription: ASMRProcessorUnit.componentDescription)
        asmrShared = (asmr.auAudioUnit as? ASMRProcessorUnit)?.shared ?? ASMRShared()
        engine.attach(asmr)
        engine.attach(sum)
        engine.attach(eq)
        engine.attach(timePitch)
        engine.attach(varispeed)
        let placeholder = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        for deck in decks {
            engine.attach(deck.player)
            engine.connect(deck.player, to: sum, fromBus: 0, toBus: deck.bus, format: placeholder)
            deck.format = placeholder
            deck.onSegmentPlayed = { [weak self] d, gen, seg in self?.segmentPlayed(d, seg) }
        }
        let chain = AVAudioFormat(standardFormatWithSampleRate: engine.outputNode.outputFormat(forBus: 0).sampleRate > 0
            ? engine.outputNode.outputFormat(forBus: 0).sampleRate : 48000, channels: 2)!
        chainSampleRate = chain.sampleRate
        connectChain(chain)
        // サンプルレートの違う曲を変換するときの品質を最高にする
        // (標準のままだと、変換の誤差が約 40dB 大きく、高域も早く落ち始める)
        sum.auAudioUnit.renderQuality = 127
        engine.mainMixerNode.auAudioUnit.renderQuality = 127
        engine.attach(checker)
        engine.connect(checker, to: engine.mainMixerNode, format: ChannelCheck.format)

        for (i, band) in eq.bands.enumerated() {
            band.frequency = Self.eqFrequencies[i]
            band.filterType = i == 0 ? .lowShelf : i == 9 ? .highShelf : .parametric
            band.bandwidth = 1.0
            band.gain = 0
            band.bypass = false
        }
        eq.bypass = true
        applyRate()
        applyVolume()

        publishASMR()
        installTap()

        if !offline { observeDefaultOutput() }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.outputConfigurationChanged()
        }
        engine.prepare()
    }

    // MARK: - 出力までの経路

    /// 速度・キーの変更に使う部品を、今つないでいるか。
    /// これらは「素通し」に設定しても音をわずかに変えてしまうので、使わないときは経路から外す
    private var timePitchInChain = false
    private var varispeedInChain = false

    private func connectChain(_ format: AVAudioFormat) {
        var last: AVAudioNode = eq
        engine.connect(sum, to: eq, format: format)
        if timePitchInChain {
            engine.connect(last, to: timePitch, format: format)
            last = timePitch
        }
        if varispeedInChain {
            engine.connect(last, to: varispeed, format: format)
            last = varispeed
        }
        engine.connect(last, to: asmr, format: format)
        engine.connect(asmr, to: engine.mainMixerNode, format: format)
    }

    private func installTap() {
        let analyzer = spectrum
        asmr.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            analyzer.process(buffer)
        }
    }

    /// 経路を別のサンプルレートでつなぎ直す。
    /// 出力デバイスと同じにしておくと、デバイスと同じサンプルレートの曲は一度も変換されずに出力まで届く
    /// (再生中の曲は、つなぎ直したあとに読み込み直すこと)
    func rebuildChain(sampleRate: Double) {
        guard abs(sampleRate - chainSampleRate) > 0.5 else { return }
        reconnectChain(sampleRate: sampleRate)
    }

    private func reconnectChain(sampleRate: Double) {
        guard sampleRate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { return }
        let wasRunning = engine.isRunning
        if wasRunning { engine.pause() }
        asmr.removeTap(onBus: 0)
        for node in [sum, eq, timePitch, varispeed, asmr] as [AVAudioNode] { engine.disconnectNodeOutput(node) }
        connectChain(format)
        installTap()
        chainSampleRate = sampleRate
        publishEQ()
        engine.prepare()
        if wasRunning { startEngine() }
    }

    /// 出力デバイスの今のサンプルレート
    private var deviceSampleRate: Double { engine.outputNode.outputFormat(forBus: 0).sampleRate }

    /// 今の出力デバイス。排他モード中は、取ったデバイス (その間、システムの「既定の出力」からは外れている)
    private var currentDevice: AudioDeviceID? {
        guard !offline else { return nil }
        if let device = selectedDevice ?? hoggedDevice { return device }
        let fallback = AudioOutputs.defaultDeviceID() ?? 0
        return fallback == 0 ? nil : fallback
    }

    var outputDeviceID: AudioDeviceID? { currentDevice }

    /// エンジンの出力が今つながっているデバイス
    private var outputUnitDevice: AudioDeviceID {
        guard let unit = engine.outputNode.audioUnit else { return 0 }
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size)
        return device
    }

    /// エンジンの出力先を、このデバイスに指定する
    private func pinOutput(to device: AudioDeviceID) {
        guard let unit = engine.outputNode.audioUnit, device != 0 else { return }
        var id = device
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &id, UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// 条件が成り立つまで待つ (最長 seconds 秒)
    @MainActor
    private func wait(upTo seconds: Double, until condition: () -> Bool) async {
        let limit = CACurrentMediaTime() + seconds
        while !condition(), CACurrentMediaTime() < limit { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// 曲に合わせるために、デバイスをどう切り替えるか (切り替えなくてよければ nil)。
    /// サンプルレートは、同じ値があればそれ、なければ整数倍。
    /// ビット深度は、今の形式では曲のデータを運びきれないときだけ上げる (16bit のデバイスに 24bit の曲など)
    private func deviceSwitch(for item: PlaybackItem) -> (device: AudioDeviceID, rate: Double?, format: OutputDevice.PhysicalFormat?)? {
        guard matchSampleRate, let device = currentDevice, let now = OutputDevice.nominalSampleRate(device) else { return nil }
        var rate = now
        if let best = OutputDevice.bestRate(for: item.sampleRate, available: OutputDevice.availableSampleRates(device)),
           !wasJustReverted(from: best) { rate = best }
        var format: OutputDevice.PhysicalFormat?
        // ビット深度の決まっていない音源 (MP3 など) は、24bit あれば足りる
        let needed = item.sourceBits ?? 24
        // (足りているときは、デバイスが受け付ける形式の一覧までは読まない。曲の終わりぎわに繰り返し呼ばれるため)
        if let current = OutputDevice.physicalFormat(device), current.precision < min(needed, 24) {
            format = OutputDevice.betterFormat(needed: needed, current: current,
                                               available: OutputDevice.availablePhysicalFormats(device, rate: rate))
            if let wanted = format, let last = lastDepthSwitch, last.bits == wanted.bits, CACurrentMediaTime() - last.time < 10 {
                format = nil
            }
        }
        let rateChange = abs(now - rate) > 0.5 ? rate : nil
        return rateChange == nil && format == nil ? nil : (device, rateChange, format)
    }

    /// 曲を読み込む前に、出力側を整える。
    /// 「デバイスの形式を曲に合わせる」がオンなら、デバイスを曲に最も合うサンプルレートとビット深度へ切り替える。
    /// そのうえで、経路をデバイスのサンプルレートに合わせる
    @MainActor
    func prepareOutput(for item: PlaybackItem) async {
        guard !offline else { return }
        await wait(upTo: 6) { !switchingExclusive }
        if let change = deviceSwitch(for: item) {
            let device = change.device
            reconfiguring = true
            defer { reconfiguring = false }
            if originalRates[device] == nil { originalRates[device] = OutputDevice.nominalSampleRate(device) }
            if originalFormats[device] == nil { originalFormats[device] = OutputDevice.physicalDescription(device) }
            decks.forEach { $0.stop() }
            engine.stop()
            // ビット深度を上げるときは、形式ごと切り替える (サンプルレートも一緒に切り替わる)
            var depth = change.format
            if let format = depth, !OutputDevice.setPhysicalFormat(device, format) { depth = nil }
            let target = depth?.rate ?? change.rate
            if depth != nil || change.rate.map({ OutputDevice.setNominalSampleRate(device, $0) }) == true {
                func settled() -> Bool {
                    if let target, abs((OutputDevice.nominalSampleRate(device) ?? 0) - target) >= 0.5 { return false }
                    if let depth, OutputDevice.physicalFormat(device)?.bits != depth.bits { return false }
                    return true
                }
                // 切り替わるまで待つ (最長 2 秒)
                await wait(upTo: 2) { settled() }
                // 切り替えの通知が出そろうのを待つ
                try? await Task.sleep(for: .milliseconds(150))
                if settled() {
                    if let rate = change.rate { lastRateSwitch = (rate, CACurrentMediaTime()) }
                    if let depth { lastDepthSwitch = (depth.bits, CACurrentMediaTime()) }
                }
            }
        }
        let rate = deviceSampleRate
        if rate > 0 { rebuildChain(sampleRate: rate) }
    }

    /// 少し前に同じサンプルレートへ切り替えたのに、今は違う値になっている = ほかのアプリが別の値に戻した。
    /// 切り替え合いが続かないよう、しばらくはこちらから切り替えない (変換して再生する)
    private func wasJustReverted(from target: Double) -> Bool {
        guard let last = lastRateSwitch else { return false }
        return abs(last.target - target) < 0.5 && CACurrentMediaTime() - last.time < 10
    }

    // MARK: - 出力が止まったときの立て直し

    /// 出力の構成が変わった (デバイスの抜き差し、サンプルレートの変更など)。このときエンジンは自分で止まる。
    /// こちらの切り替えの途中なら終わるのを待ち、そのうえで必要なら読み込み直してもらう
    private func outputConfigurationChanged() {
        guard !recoveryScheduled else { return }
        recoveryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.recoveryScheduled = false
            if self.reconfiguring || self.switchingExclusive {
                self.outputConfigurationChanged()
                return
            }
            self.recoverIfNeeded()
        }
    }

    /// 再生中のはずなのにエンジンが止まっている、または経路のサンプルレートがデバイスと合っていなければ、読み込み直してもらう。
    /// (こちらの切り替えのあとで、すでに再生し直せているなら何もしない)
    private func recoverIfNeeded() {
        guard current != nil else { return }
        let stalled = isPlaying && !pausePending && !engine.isRunning
        let rate = deviceSampleRate
        let mismatched = rate > 0 && abs(rate - chainSampleRate) > 0.5
        guard stalled || mismatched else { return }
        lastRecovery = CACurrentMediaTime()
        onConfigurationChange?()
    }

    /// 再生中のはずなのにエンジンが止まったままになっていないかを見張る (tick から呼ぶ)。
    /// 通知を取りこぼしても、0.7 秒ほどで読み込み直す
    private func watchForStall() {
        guard isPlaying, !pausePending, !reconfiguring, !switchingExclusive, !engine.isRunning else {
            stalledTicks = 0
            return
        }
        stalledTicks += 1
        if stalledTicks >= 20, CACurrentMediaTime() - lastRecovery > 3 {
            stalledTicks = 0
            lastRecovery = CACurrentMediaTime()
            onConfigurationChange?()
        }
    }

    /// 次の曲へそのまま続けて進めるか (デバイスの形式を合わせる設定で、デバイスの切り替えが要るなら進めない)
    private func canContinue(to next: PlaybackItem) -> Bool { deviceSwitch(for: next) == nil }

    /// 排他モードを取る / 手放す。うまくいったかを返す。
    ///
    /// 排他モードを取ると、そのデバイスはシステムの「既定の出力」から外れる (デバイスが 1 つなら、既定の出力は「なし」になる)。
    /// エンジンの出力は既定のデバイスを追うので、そのままだと出力先を見失って、止まったまま始められなくなる。
    /// そこで、エンジンを止めてから取り、既定の出力の切り替わりが落ち着くのを待って、取ったデバイスを出力先に指定し直す。
    /// 呼んだ側は、このあと再生中の曲を読み込み直すこと
    @MainActor
    @discardableResult
    func setExclusiveMode(_ on: Bool) async -> Bool {
        exclusiveMode = on
        guard !offline else { return false }
        await wait(upTo: 6) { !switchingExclusive }
        switchingExclusive = true
        reconfiguring = true
        defer {
            reconfiguring = false
            switchingExclusive = false
        }
        let want = exclusiveMode
        let target = currentDevice
        if want, hoggedDevice != nil, hoggedDevice == target { return true }
        if !want, hoggedDevice == nil { return true }

        decks.forEach { $0.stop() }
        engine.stop()
        if let held = hoggedDevice {
            OutputDevice.setHog(held, false)
            hoggedDevice = nil
            // 手放したデバイスが、既定の出力に戻るのを待つ
            await wait(upTo: 2) { (AudioOutputs.defaultDeviceID() ?? 0) != 0 }
            try? await Task.sleep(for: .milliseconds(200))
        }
        var succeeded = !want
        if want, let device = target, OutputDevice.setHog(device, true) {
            hoggedDevice = device
            // 既定の出力から外れる (その処理がエンジンの出力先を書き換える) のを待ってから、出力先に指定する
            await wait(upTo: 2) { AudioOutputs.defaultDeviceID() != device }
            try? await Task.sleep(for: .milliseconds(250))
            for _ in 0..<12 {
                pinOutput(to: device)
                try? await Task.sleep(for: .milliseconds(100))
                if outputUnitDevice == device, deviceSampleRate > 0 {
                    succeeded = true
                    break
                }
            }
            if !succeeded {
                // 取れたのに出力先にできなかった: 手放して元に戻す
                OutputDevice.setHog(device, false)
                hoggedDevice = nil
                await wait(upTo: 2) { (AudioOutputs.defaultDeviceID() ?? 0) != 0 }
            }
        }
        if hoggedDevice == nil {
            // 選んであるデバイス (なければ既定の出力) に戻るのを待つ
            if let selected = selectedDevice { pinOutput(to: selected) }
            await wait(upTo: 2) { self.deviceSampleRate > 0 }
        }
        let rate = deviceSampleRate
        if rate > 0 { rebuildChain(sampleRate: rate) }
        return succeeded
    }

    /// 排他モード中に、システムの既定の出力が変わった (別のデバイスがつながれたなど)。
    /// エンジンの出力先がそちらへ動いてしまったら、取っているデバイスに戻す
    private func defaultOutputChanged() {
        guard !reconfiguring, let held = hoggedDevice else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.reconfiguring, self.hoggedDevice == held, self.outputUnitDevice != held else { return }
            self.pinOutput(to: held)
            self.outputConfigurationChanged()
        }
    }

    private func observeDefaultOutput() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.defaultOutputChanged()
        }
    }

    /// 排他モードを取れているか
    var isExclusive: Bool { hoggedDevice != nil }

    /// 切り替えたサンプルレートと形式を元に戻す。終了時 (releaseExclusive) は、排他モードも手放す
    func restoreOutputDevice(releaseExclusive: Bool = false) {
        if releaseExclusive, let held = hoggedDevice {
            OutputDevice.setHog(held, false)
            hoggedDevice = nil
        }
        for (device, rate) in originalRates {
            // ビット深度も変えていたら、形式ごと戻す (サンプルレートも一緒に戻る)
            if let original = originalFormats[device], OutputDevice.physicalFormat(device)?.bits != Int(original.mBitsPerChannel) {
                var format = original
                format.mSampleRate = rate
                if OutputDevice.setPhysicalDescription(device, format) { continue }
            }
            OutputDevice.setNominalSampleRate(device, rate)
        }
        originalRates.removeAll()
        originalFormats.removeAll()
        lastRateSwitch = nil
        lastDepthSwitch = nil
    }

    /// 出力デバイスの情報 (名前・サンプルレート・デバイスへ送る形式・つなぎ方)
    var outputInfo: (name: String, rate: Double, format: OutputDevice.PhysicalFormat?, transport: String?) {
        guard let device = currentDevice else { return ("出力", deviceSampleRate, nil, nil) }
        return (OutputDevice.name(device) ?? "出力", OutputDevice.nominalSampleRate(device) ?? deviceSampleRate,
                OutputDevice.physicalFormat(device), OutputDevice.transport(device))
    }

    // MARK: - 再生制御

    func load(_ item: PlaybackItem, at seconds: Double = 0, play: Bool) {
        cancelPendingPause()
        pendingSeek = nil
        cancelCrossfade()
        decks.forEach { $0.stop() }
        upcoming = nil
        let deck = activeDeck
        connect(deck, format: item.file.processingFormat)
        deck.fade = 1
        deck.schedule(item, from: seconds)
        current = item
        reportedSegment = 0
        if play {
            // 曲の途中から鳴らし始めるときは、無音からフェードインする
            self.play(fadeInFromSilence: softTransitions && seconds > 0.05)
        } else {
            isPlaying = false
            stopTimer()
            if engine.isRunning, !checker.isPlaying { engine.pause() }
        }
        onTick?(seconds, item.duration)
    }

    func play() { play(fadeInFromSilence: false) }

    private func play(fadeInFromSilence: Bool) {
        guard current != nil else { return }
        if pausePending {
            // 一時停止のフェードアウトの途中: 止めずにそのまま音を戻す
            cancelPendingPause()
            setDuck(1, time: 0.04)
            isPlaying = true
            startTimer()
            return
        }
        // 絞ってある状態 (フェードして止めたあと) や曲の途中からは、無音から上げ直す
        let fadeIn = fadeInFromSilence || duck < 1
        if fadeIn { setDuck(0, time: 0.006, restart: true) }
        startEngine()
        if var xf = crossfade, let paused = xf.pausedAt {
            xf.start += CACurrentMediaTime() - paused
            xf.pausedAt = nil
            crossfade = xf
            xf.from.player.play()
        }
        activeDeck.player.play()
        isPlaying = true
        startTimer()
        // プレイヤーの音が出始めてから上げる
        if fadeIn { self.fadeIn(after: 0.05) } else { setDuck(1, time: 0.006) }
    }

    /// - Parameter immediately: フェードを待たずに止める (すでに音が小さくなっているスリープタイマーの終わりなど)
    func pause(immediately: Bool = false) {
        if pausePending {
            if immediately {
                cancelPendingPause()
                finishPause()
            }
            return
        }
        guard isPlaying else { return }
        isPlaying = false
        stopTimer()
        // 次に再生するときにフェードインできるよう、止めるときは絞った状態にしておく
        if softTransitions { setDuck(0, time: 0.03) }
        if softTransitions, !immediately, engine.isRunning {
            // 音を絞りきってから止める (波形の途中で切るとプツッと鳴る)
            pauseGeneration += 1
            let generation = pauseGeneration
            pausePending = true
            after(0.15) { [weak self] in
                guard let self, self.pausePending, self.pauseGeneration == generation else { return }
                self.finishPause()
            }
            tick()
        } else {
            finishPause()
        }
    }

    private func finishPause() {
        pausePending = false
        for d in decks where d.isLoaded {
            _ = d.sampleTime()
            d.player.pause()
        }
        crossfade?.pausedAt = CACurrentMediaTime()
        tick()
        if !checker.isPlaying { engine.pause() }
    }

    private func cancelPendingPause() {
        pausePending = false
        pauseGeneration += 1
    }

    func stop() {
        cancelPendingPause()
        pendingSeek = nil
        cancelCrossfade()
        decks.forEach { $0.stop() }
        upcoming = nil
        current = nil
        isPlaying = false
        stopTimer()
        if !checker.isPlaying { engine.pause() }
    }

    var position: Double { pendingSeek ?? activeDeck.status()?.position ?? 0 }

    func seek(to seconds: Double) {
        guard let item = current else { return }
        guard softTransitions, isPlaying, engine.isRunning else {
            pendingSeek = nil
            performSeek(to: seconds)
            return
        }
        // 再生中は、一瞬絞ってから移動して戻す。続けて呼ばれたら最後の行き先だけを使う
        let first = pendingSeek == nil
        pendingSeek = seconds
        onTick?(seconds, item.duration)
        guard first else { return }
        setDuck(0, time: 0.006)
        after(0.03) { [weak self] in
            guard let self, let target = self.pendingSeek else { return }
            self.pendingSeek = nil
            self.performSeek(to: target)
            if self.isPlaying { self.fadeIn(after: 0.02, time: 0.012) }
        }
    }

    private func performSeek(to seconds: Double) {
        guard let item = current else { return }
        cancelCrossfade()
        if case .preloaded = upcoming { otherDeck.stop() }
        upcoming = nil
        let deck = activeDeck
        let wasPlaying = isPlaying
        deck.stop()
        deck.schedule(item, from: min(max(0, seconds), max(0, item.duration - 0.05)))
        reportedSegment = 0
        if wasPlaying { deck.player.play() }
        onTick?(seconds, item.duration)
    }

    /// キューの並びが変わったときなど、予約済みの「次の曲」を破棄する
    func invalidateUpcoming() {
        guard let up = upcoming else { return }
        switch up {
        case .chained:
            upcoming = nil
            seek(to: position)
        case .preloaded:
            otherDeck.stop()
            upcoming = nil
        case .crossfade:
            upcoming = nil
        }
    }

    func setEQ(bands: [Float], preamp: Float, enabled: Bool) {
        for (i, g) in bands.prefix(eq.bands.count).enumerated() { eq.bands[i].gain = g }
        eq.globalGain = preamp
        // すべて 0dB のときは通さない (通すだけでも計算の丸めが入り、元の音と 1 ビット単位では一致しなくなる)
        eq.bypass = !enabled || (preamp == 0 && bands.allSatisfy { $0 == 0 })
    }

    func setOutputDevice(_ id: AudioDeviceID?) {
        guard let unit = engine.outputNode.audioUnit else { return }
        var device = id ?? AudioOutputs.defaultDeviceID() ?? 0
        guard device != 0 else { return }
        let wasRunning = engine.isRunning
        engine.stop()
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                             &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        selectedDevice = id
        let rate = deviceSampleRate
        if rate > 0 { rebuildChain(sampleRate: rate) }
        if wasRunning { startEngine() }
    }

    // MARK: - 内部

    private func publishEQ() {
        asmrShared.publishEQ(eqProfile.map { EQDesign.stages(for: $0, sampleRate: chainSampleRate) } ?? [])
    }

    private func publishASMR() {
        var s = asmrSettings
        s.duck = duck
        s.duckTime = duckTime
        s.duckRestart = duckRestart
        asmrShared.publish(s)
    }

    /// 音を絞る / 戻す。restart を付けると、いったん無音にしてから target へ向かう
    private func setDuck(_ target: Float, time: Float, restart: Bool = false) {
        duckGeneration += 1
        duck = target
        duckTime = time
        if restart { duckRestart &+= 1 }
        publishASMR()
    }

    /// 少し待ってから音を戻す (プレイヤーが鳴り始める前に上げきってしまわないように)
    private func fadeIn(after delay: Double, time: Float = 0.08) {
        duckGeneration += 1
        let generation = duckGeneration
        after(delay) { [weak self] in
            guard let self, self.duckGeneration == generation else { return }
            self.setDuck(1, time: time)
        }
    }

    // MARK: - 左右の確認音

    /// 左で 1 回、右で 2 回、小さな音を鳴らす
    func playChannelCheck() {
        guard let buffer = ChannelCheck.makeBuffer() else { return }
        checkGeneration += 1
        let generation = checkGeneration
        checker.stop()
        startEngine()
        checker.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.checkGeneration == generation else { return }
                self.checker.stop()
                if !self.isPlaying, !self.pausePending { self.engine.pause() }
            }
        }
        checker.play()
    }

    private func startEngine() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            NSLog("Kanade: engine start failed: \(error)")
            // 再生中の表示のまま固まらないよう、止めて知らせる
            isPlaying = false
            stopTimer()
            onStartFailure?()
        }
    }

    private func applyVolume() {
        engine.mainMixerNode.outputVolume = max(0, volume * volume * fadeMultiplier)
    }

    private func applyRate() {
        if preservePitch {
            timePitch.rate = rate
            timePitch.pitch = pitch * 100
            timePitch.bypass = rate == 1 && pitch == 0
            varispeed.rate = 1
            varispeed.bypass = true
        } else {
            varispeed.rate = rate
            varispeed.bypass = rate == 1
            timePitch.rate = 1
            timePitch.pitch = pitch * 100
            timePitch.bypass = pitch == 0
        }
        // 使う部品だけを経路に入れる。入れ替えたら、再生中の曲は同じ位置から読み込み直す
        let needsTimePitch = !timePitch.bypass, needsVarispeed = !varispeed.bypass
        guard needsTimePitch != timePitchInChain || needsVarispeed != varispeedInChain else { return }
        timePitchInChain = needsTimePitch
        varispeedInChain = needsVarispeed
        let position = self.position, playing = isPlaying, item = current
        reconnectChain(sampleRate: chainSampleRate)
        if let item { load(item, at: position, play: playing) }
    }

    private func connect(_ deck: Deck, format: AVAudioFormat) {
        if let f = deck.format, f.sampleRate == format.sampleRate, f.channelCount == format.channelCount { return }
        engine.disconnectNodeOutput(deck.player)
        engine.connect(deck.player, to: sum, fromBus: 0, toBus: deck.bus, format: format)
        deck.player.pan = balance
        deck.format = format
    }

    private func canChain(_ deck: Deck, _ item: PlaybackItem) -> Bool {
        guard let f = deck.format else { return false }
        let g = item.file.processingFormat
        return f.sampleRate == g.sampleRate && f.channelCount == g.channelCount
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        if !offline { watchForStall() }
        let deck = activeDeck
        guard let (index, seg, pos) = deck.status() else { return }
        if let target = pendingSeek {
            // 移動の途中は行き先を知らせる (古い位置を知らせると表示が戻ってしまう)
            onTick?(target, seg.item.duration)
            return
        }

        if index != reportedSegment {
            reportedSegment = index
            current = seg.item
            deck.gain = seg.item.gain
            if case .chained = upcoming { upcoming = nil }
            onAdvance?(seg.item.trackID)
        }
        let duration = seg.item.duration
        onTick?(pos, duration)
        guard isPlaying else { return }

        if let loop, loop.upperBound > loop.lowerBound, pos >= loop.upperBound - 0.03, !loopJumping {
            // つなぎ目でプツッと鳴らないよう、一瞬絞ってから戻る
            loopJumping = true
            setDuck(0, time: 0.006)
            after(0.03) { [weak self] in
                guard let self else { return }
                self.loopJumping = false
                if self.loop == loop, self.pendingSeek == nil { self.performSeek(to: loop.lowerBound) }
                if self.isPlaying, self.pendingSeek == nil { self.setDuck(1, time: 0.006) }
            }
            return
        }

        updateCrossfade()

        let remaining = (duration - pos) / Double(max(rate, 0.1))
        let isLast = index == deck.segments.count - 1
        if isLast, upcoming == nil, crossfade == nil, remaining < max(3, crossfadeDuration + 1.5),
           let next = provideNext?(), canContinue(to: next) {
            let xf = crossfadeDuration > 0.05 && !next.continues(seg.item)
                && duration > crossfadeDuration * 2 && next.duration > crossfadeDuration * 2
            if xf {
                upcoming = .crossfade(next)
            } else if canChain(deck, next) {
                deck.schedule(next)
                upcoming = .chained
            } else {
                let other = otherDeck
                other.stop()
                connect(other, format: next.file.processingFormat)
                other.fade = 1
                other.schedule(next)
                other.player.prepare(withFrameCount: 8192)
                upcoming = .preloaded(next)
            }
        }
        if case .crossfade(let next) = upcoming, remaining <= crossfadeDuration {
            startCrossfade(next, over: max(0.2, remaining))
        }
    }

    private func startCrossfade(_ next: PlaybackItem, over duration: Double) {
        let from = activeDeck, to = otherDeck
        to.stop()
        connect(to, format: next.file.processingFormat)
        to.fade = 0
        to.schedule(next)
        to.player.play()
        activeIndex = 1 - activeIndex
        crossfade = Crossfade(from: from, to: to, start: CACurrentMediaTime(), duration: duration)
        upcoming = nil
        current = next
        reportedSegment = 0
        onAdvance?(next.trackID)
    }

    private func updateCrossfade() {
        guard let xf = crossfade, xf.pausedAt == nil else { return }
        let p = min(1, (CACurrentMediaTime() - xf.start) / xf.duration)
        xf.from.fade = Float(cos(p * .pi / 2))
        xf.to.fade = Float(sin(p * .pi / 2))
        if p >= 1 { cancelCrossfade() }
    }

    private func cancelCrossfade() {
        guard let xf = crossfade else { return }
        xf.from.stop()
        xf.to.fade = 1
        crossfade = nil
    }

    private func segmentPlayed(_ deck: Deck, _ seg: Deck.Segment) {
        if let xf = crossfade, xf.from === deck {
            cancelCrossfade()
            return
        }
        guard deck === activeDeck, seg.end >= deck.scheduledEnd else { return }

        if case .preloaded(let next) = upcoming {
            let old = deck
            activeIndex = 1 - activeIndex
            activeDeck.player.play()
            old.stop()
            upcoming = nil
            current = next
            reportedSegment = 0
            onAdvance?(next.trackID)
            return
        }
        if case .crossfade(let next) = upcoming {
            // フェードの開始に間に合わなかった (極端に短い曲など) → そのまま切り替え
            upcoming = nil
            load(next, play: true)
            onAdvance?(next.trackID)
            return
        }
        isPlaying = false
        stopTimer()
        onFinished?()
    }
}
