import AudioToolbox
import CoreAudio
import Foundation

/// 出力デバイスの状態の読み取りと切り替え (Core Audio)
enum OutputDevice {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    /// 今のサンプルレート
    static func nominalSampleRate(_ device: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate) == noErr && rate > 0 ? rate : nil
    }

    /// デバイスが対応しているサンプルレート (範囲で返るものは、よく使う値に置き換える)
    static func availableSampleRates(_ device: AudioDeviceID) -> [Double] {
        var addr = address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ranges) == noErr else { return [] }
        let common: [Double] = [44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000, 705600, 768000]
        var rates = Set<Double>()
        for range in ranges {
            if range.mMinimum == range.mMaximum {
                rates.insert(range.mMinimum)
            } else {
                for rate in common where rate >= range.mMinimum && rate <= range.mMaximum { rates.insert(rate) }
            }
        }
        return rates.sorted()
    }

    @discardableResult
    static func setNominalSampleRate(_ device: AudioDeviceID, _ rate: Double) -> Bool {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var value = Float64(rate)
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &value) == noErr
    }

    /// 曲のサンプルレートに最も合う、デバイスのサンプルレート。
    /// 同じ値があればそれ、なければ整数倍、それもなければ曲より高い中でいちばん低いもの。
    /// 曲のほうが高いときは、割り切れる中でいちばん高いもの、なければデバイスの最高値
    static func bestRate(for fileRate: Double, available: [Double]) -> Double? {
        let rates = available.sorted()
        guard fileRate > 0, !rates.isEmpty else { return nil }
        func isMultiple(_ a: Double, of b: Double) -> Bool {
            let ratio = a / b
            return ratio >= 1 && abs(ratio - ratio.rounded()) < 1e-6
        }
        if let exact = rates.first(where: { abs($0 - fileRate) < 0.5 }) { return exact }
        if let multiple = rates.first(where: { $0 > fileRate && isMultiple($0, of: fileRate) }) { return multiple }
        if let higher = rates.first(where: { $0 > fileRate }) { return higher }
        if let divisor = rates.last(where: { isMultiple(fileRate, of: $0) }) { return divisor }
        return rates.last
    }

    // MARK: 排他モード

    /// デバイスを排他的に使っているプロセス (-1 なら誰も使っていない)
    static func hogOwner(_ device: AudioDeviceID) -> pid_t? {
        var addr = address(kAudioDevicePropertyHogMode)
        var pid = pid_t(-1)
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &pid) == noErr ? pid : nil
    }

    /// 排他モードを取る / 手放す。取っている間、ほかのアプリはこのデバイスで音を出せない
    @discardableResult
    static func setHog(_ device: AudioDeviceID, _ on: Bool) -> Bool {
        guard let owner = hogOwner(device) else { return false }
        let mine = owner == getpid()
        if on == mine { return true }
        if on, owner != -1 { return false }   // ほかのアプリが取っている
        var addr = address(kAudioDevicePropertyHogMode)
        // 自分の pid を書くと取り、もう一度書く (または -1 を書く) と手放す
        var pid = on ? getpid() : pid_t(-1)
        guard AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<pid_t>.size), &pid) == noErr else { return false }
        return (hogOwner(device) == getpid()) == on
    }

    // MARK: デバイスへ送る形式

    /// デバイスへ実際に送る形式
    struct PhysicalFormat: Equatable {
        var rate: Double
        var bits: Int
        var channels: Int
        var isFloat = false
        /// ほかのアプリの音と混ぜて使える形式か
        var mixable = true

        /// 整数のデータを何ビット分まで正確に運べるか (32bit 浮動小数点は 24bit 分)
        var precision: Int { isFloat ? (bits >= 64 ? 53 : 24) : bits }

        init(rate: Double, bits: Int, channels: Int = 2, isFloat: Bool = false, mixable: Bool = true) {
            (self.rate, self.bits, self.channels, self.isFloat, self.mixable) = (rate, bits, channels, isFloat, mixable)
        }

        init(_ d: AudioStreamBasicDescription) {
            self.init(rate: d.mSampleRate, bits: Int(d.mBitsPerChannel), channels: Int(d.mChannelsPerFrame),
                      isFloat: d.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      mixable: d.mFormatFlags & kAudioFormatFlagIsNonMixable == 0)
        }
    }

    private static func outputStream(_ device: AudioDeviceID) -> AudioStreamID? {
        var addr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }

    /// 今の形式を、そのまま戻せる形で読む
    static func physicalDescription(_ device: AudioDeviceID) -> AudioStreamBasicDescription? {
        guard let stream = outputStream(device) else { return nil }
        var addr = address(kAudioStreamPropertyPhysicalFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    static func physicalFormat(_ device: AudioDeviceID) -> PhysicalFormat? {
        physicalDescription(device).map(PhysicalFormat.init)
    }

    /// デバイスが受け付ける形式 (リニア PCM だけ)
    private static func availableDescriptions(_ device: AudioDeviceID) -> [AudioStreamRangedDescription] {
        guard let stream = outputStream(device) else { return [] }
        var addr = address(kAudioStreamPropertyAvailablePhysicalFormats)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(stream, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(),
                                                  count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(stream, &addr, 0, nil, &size, &list) == noErr else { return [] }
        return list.filter { $0.mFormat.mFormatID == kAudioFormatLinearPCM }
    }

    /// あるサンプルレートで、デバイスが受け付ける形式
    static func availablePhysicalFormats(_ device: AudioDeviceID, rate: Double) -> [PhysicalFormat] {
        availableDescriptions(device).compactMap { d in
            guard abs(d.mFormat.mSampleRate - rate) < 0.5
                    || (d.mSampleRateRange.mMinimum - 0.5...d.mSampleRateRange.mMaximum + 0.5).contains(rate) else { return nil }
            var format = PhysicalFormat(d.mFormat)
            format.rate = rate
            return format
        }
    }

    /// 曲のデータをそのまま運ぶには今の形式ではビット数が足りないときに、切り替える先の形式。足りていれば nil。
    /// 足りる形式の中では、今と同じ種類 (整数 / 浮動小数点) でビット数のいちばん少ないものを選ぶ。
    /// 足りる形式がなければ、いちばん多く運べるもの (今より良くなるときだけ)
    static func betterFormat(needed: Int, current: PhysicalFormat, available: [PhysicalFormat]) -> PhysicalFormat? {
        // アプリの中では 32bit 浮動小数点で扱うので、24bit を超える分は運べない
        let needed = min(needed, 24)
        guard current.precision < needed else { return nil }
        let candidates = available.filter { $0.channels == current.channels && $0.mixable == current.mixable }
        func order(_ f: PhysicalFormat) -> (Int, Int) { (f.isFloat == current.isFloat ? 0 : 1, f.bits) }
        if let best = candidates.filter({ $0.precision >= needed }).min(by: { order($0) < order($1) }) { return best }
        guard let best = candidates.max(by: { $0.precision < $1.precision }), best.precision > current.precision else { return nil }
        return best
    }

    /// デバイスへ送る形式を切り替える (デバイスが受け付ける形式の中から、同じものを探して指定する)
    @discardableResult
    static func setPhysicalFormat(_ device: AudioDeviceID, _ format: PhysicalFormat) -> Bool {
        guard var description = availableDescriptions(device).first(where: {
            var candidate = PhysicalFormat($0.mFormat)
            let inRange = ($0.mSampleRateRange.mMinimum - 0.5...$0.mSampleRateRange.mMaximum + 0.5).contains(format.rate)
            guard abs(candidate.rate - format.rate) < 0.5 || inRange else { return false }
            candidate.rate = format.rate
            return candidate == format
        })?.mFormat else { return false }
        description.mSampleRate = format.rate
        return setPhysicalDescription(device, description)
    }

    @discardableResult
    static func setPhysicalDescription(_ device: AudioDeviceID, _ description: AudioStreamBasicDescription) -> Bool {
        guard let stream = outputStream(device) else { return false }
        var addr = address(kAudioStreamPropertyPhysicalFormat)
        var value = description
        return AudioObjectSetPropertyData(stream, &addr, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &value) == noErr
    }

    // MARK: デバイス側の音量

    private static var volumeAddress: AudioObjectPropertyAddress {
        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
    }

    /// デバイス側の音量 (0〜1、システムの音量と同じ値)。Mac から変えられないデバイスなら nil
    static func volume(_ device: AudioDeviceID) -> Float? {
        var addr = volumeAddress
        var settable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &addr),
              AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    @discardableResult
    static func setVolume(_ device: AudioDeviceID, _ value: Float) -> Bool {
        var addr = volumeAddress
        var v = Float32(min(1, max(0, value)))
        return AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v) == noErr
    }

    /// 音量を dB で動かせる要素 (全体の音量があればそれ、なければ左右のチャンネル)
    private static func volumeElements(_ device: AudioDeviceID) -> [UInt32] {
        func usable(_ element: UInt32) -> Bool {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var settable = DarwinBoolean(false)
            return AudioObjectHasProperty(device, &addr)
                && AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
        }
        if usable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        var addr = address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyScopeOutput)
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &channels) != noErr { channels = [1, 2] }
        return channels.filter(usable)
    }

    private static func volumeDB(_ device: AudioDeviceID, _ element: UInt32) -> (value: Float, range: ClosedRange<Float>)? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: element)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        addr.mSelector = kAudioDevicePropertyVolumeRangeDecibels
        var range = AudioValueRange()
        size = UInt32(MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &range) == noErr, range.mMinimum <= range.mMaximum else { return nil }
        return (value, Float(range.mMinimum)...Float(range.mMaximum))
    }

    /// デバイス側の音量を、あと何 dB 下げられるか (Mac から変えられないデバイスなら 0)
    static func volumeRoomBelow(_ device: AudioDeviceID) -> Float {
        let rooms = volumeElements(device).compactMap { volumeDB(device, $0) }.map { $0.value - $0.range.lowerBound }
        return max(0, rooms.min() ?? 0)
    }

    /// デバイス側の音量を dB で動かす (範囲の端で止まる)。実際に動いた量を返す
    @discardableResult
    static func adjustVolume(_ device: AudioDeviceID, byDB delta: Float) -> Float {
        var moved: Float?
        for element in volumeElements(device) {
            guard let now = volumeDB(device, element) else { continue }
            var target = Float32(min(now.range.upperBound, max(now.range.lowerBound, now.value + delta)))
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeDecibels,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            guard AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &target) == noErr else { continue }
            let step = (volumeDB(device, element)?.value ?? target) - now.value
            // 左右で動いた量が違うときは、小さいほうを答える
            moved = moved.map { abs($0) < abs(step) ? $0 : step } ?? step
        }
        return moved ?? 0
    }

    /// 曲の音量をアプリの中で下げる代わりにデバイス側で下げるときの、聞こえる大きさの変化 (dB)。
    /// attenuation はアプリの中で下げていた量、room はデバイス側であと下げられる量。
    /// デバイス側で下げきれない分だけ、音が大きくなる
    static func loudnessJump(attenuation: Double, room: Double) -> Double {
        max(0, attenuation - max(0, room))
    }

    // MARK: 情報

    static func name(_ device: AudioDeviceID) -> String? {
        var addr = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    /// つなぎ方 (内蔵・USB・Bluetooth など)
    static func transport(_ device: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &type) == noErr else { return nil }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "内蔵"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "HDMI / DisplayPort"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "仮想デバイス"
        default: return nil
        }
    }
}

/// 出力デバイス側の音量が変わったことを知らせる (システムの音量を変えたときなど)
final class DeviceVolumeObserver {
    private var device: AudioDeviceID?
    private var block: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
    var onChange: (() -> Void)?

    /// 見張るデバイスを切り替える (nil なら見張らない)
    func observe(_ device: AudioDeviceID?) {
        guard device != self.device else { return }
        if let old = self.device, let block { AudioObjectRemovePropertyListenerBlock(old, &address, .main, block) }
        self.device = device
        block = nil
        guard let device else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.onChange?() }
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr { self.block = block }
    }

    deinit { observe(nil) }
}
