import Accelerate
import AVFoundation
import CoreAudio
import QuartzCore

// MARK: - スペクトラム解析

/// エンジンのタップから受け取った音声を FFT し、対数間隔の帯域レベルにする。
/// タップは 100ms 程度ごとにしか届かないので、1 バッファを複数フレームに分けて時刻付きで積み、
/// 描画側が現在時刻に合うフレームを取り出すことで滑らかに動かす。
final class SpectrumAnalyzer: @unchecked Sendable {
    static let bandCount = 72
    static let waveCount = 192

    struct Frame {
        var due: CFTimeInterval
        var bands: [Float]
        var wave: [Float]
        /// 左右チャンネルの RMS (VU メーター用)
        var left: Float = 0
        var right: Float = 0
    }

    private let fftSize = 2048
    private let hop = 512
    private let fft: FFTSetup
    private var window: [Float]
    private var history: [Float] = []
    private var bandBins: [(Int, Int, Float)] = []
    private var binRate: Double = 0
    private var frames: [Frame] = []
    private let lock = NSLock()
    /// 省電力表示のときは解析しない (表示するものがないため)
    var enabled = true

    init() {
        fft = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(fft) }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard enabled, let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard n > 0, channels > 0 else { return }
        let rate = buffer.format.sampleRate

        var mono = [Float](repeating: 0, count: n)
        for c in 0..<channels { vDSP_vadd(data[c], 1, mono, 1, &mono, 1, vDSP_Length(n)) }
        var scale = 1 / Float(channels)
        vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))

        let base = history.count
        history += mono
        if binRate != rate { buildBands(rate: rate) }

        var produced: [Frame] = []
        let now = CACurrentMediaTime()
        var end = base + hop
        while end <= history.count {
            if end >= fftSize {
                let slice = Array(history[(end - fftSize)..<end])
                let due = now + Double(end - history.count) / rate + Double(n) / rate
                var frame = analyze(slice, due: due)
                // このフレームに対応するバッファ内の区間で左右の RMS をとる
                let hi = min(n, end - base), lo = max(0, hi - 1024)
                if hi > lo {
                    vDSP_rmsqv(data[0] + lo, 1, &frame.left, vDSP_Length(hi - lo))
                    vDSP_rmsqv(data[min(1, channels - 1)] + lo, 1, &frame.right, vDSP_Length(hi - lo))
                }
                produced.append(frame)
            }
            end += hop
        }
        if history.count > fftSize * 2 { history.removeFirst(history.count - fftSize) }

        lock.lock()
        frames.removeAll { $0.due < now - 0.5 }
        frames += produced
        lock.unlock()
    }

    /// 現在時刻に表示すべきフレーム
    func frame(at time: CFTimeInterval) -> Frame? {
        lock.lock()
        defer { lock.unlock() }
        return frames.last { $0.due <= time }
    }

    func reset() {
        lock.lock()
        frames.removeAll()
        lock.unlock()
    }

    private func buildBands(rate: Double) {
        binRate = rate
        let nyquist = rate / 2
        let lo = 32.0, hi = min(18000.0, nyquist * 0.95)
        let binHz = rate / Double(fftSize)
        bandBins = (0..<Self.bandCount).map { i in
            let f0 = lo * pow(hi / lo, Double(i) / Double(Self.bandCount))
            let f1 = lo * pow(hi / lo, Double(i + 1) / Double(Self.bandCount))
            let b0 = max(1, Int(f0 / binHz))
            let b1 = max(b0 + 1, Int(f1 / binHz))
            // 高域ほど持ち上げる (+3dB/oct) と見た目のバランスが良い
            let tilt = Float(3 * log2(sqrt(f0 * f1) / 1000))
            return (b0, min(b1, fftSize / 2), tilt)
        }
    }

    private func analyze(_ samples: [Float], due: CFTimeInterval) -> Frame {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, 11, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        // 正規化: フルスケールの正弦波 ≒ 0dB
        var norm = 1 / Float(fftSize)
        vDSP_vsmul(mags, 1, &norm, &mags, 1, vDSP_Length(half))

        var bands = [Float](repeating: 0, count: Self.bandCount)
        for (i, (b0, b1, tilt)) in bandBins.enumerated() {
            var peak: Float = 0
            mags.withUnsafeBufferPointer { vDSP_maxv($0.baseAddress! + b0, 1, &peak, vDSP_Length(max(1, b1 - b0))) }
            let db = 20 * log10(max(peak, 1e-7)) + tilt
            bands[i] = min(1, max(0, (db + 66) / 56))
        }

        let step = fftSize / Self.waveCount
        let wave = (0..<Self.waveCount).map { samples[fftSize / 2 - Self.waveCount * step / 2 + $0 * step] }
        return Frame(due: due, bands: bands, wave: wave)
    }
}

// MARK: - 波形 (シークバー用)

enum WaveformBuilder {
    /// ファイル全体のピーク値を `buckets` 個に要約する
    static func peaks(of url: URL, buckets: Int = 1600) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 1 << 16
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        let perBucket = max(1, Double(file.length) / Double(buckets))
        var out = [Float](repeating: 0, count: buckets)
        var frame: AVAudioFramePosition = 0
        let channels = Int(format.channelCount)

        while frame < file.length {
            if Task.isCancelled { return nil }
            do { try file.read(into: buf, frameCount: chunk) } catch { break }
            let n = Int(buf.frameLength)
            if n == 0 { break }
            guard let data = buf.floatChannelData else { break }
            // 32 サンプルごとに間引いて最大値をとる (十分な精度で高速)
            var i = 0
            while i < n {
                var m: Float = 0
                for c in 0..<channels { m = max(m, abs(data[c][i])) }
                let b = min(buckets - 1, Int(Double(frame + AVAudioFramePosition(i)) / perBucket))
                if m > out[b] { out[b] = m }
                i += 32
            }
            frame += AVAudioFramePosition(n)
        }
        return out
    }

    /// CUE トラック用に一部を切り出し、表示用に正規化する
    static func slice(_ peaks: [Float], from: Double, to: Double) -> [Float] {
        let n = peaks.count
        let a = max(0, min(n - 1, Int(from * Double(n))))
        let b = max(a + 1, min(n, Int((to * Double(n)).rounded(.up))))
        let part = Array(peaks[a..<b])
        let top = max(part.max() ?? 1, 0.05)
        return part.map { min(1, $0 / top) }
    }
}

// MARK: - 出力デバイス

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioOutputs {
    static func list() -> [AudioOutputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var s: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &s) == noErr, s > 0 else { return nil }
            guard let name = string(id, kAudioObjectPropertyName), let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AudioOutputDevice(id: id, uid: uid, name: name)
        }
    }

    static func defaultDeviceID() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr ? id : nil
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }
}
