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

    // MARK: 情報

    /// デバイスへ実際に送る形式 (ビット深度とサンプルレート)
    static func physicalFormat(_ device: AudioDeviceID) -> (bits: Int, rate: Double)? {
        var addr = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &streams) == noErr, let stream = streams.first else { return nil }
        var formatAddr = address(kAudioStreamPropertyPhysicalFormat)
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &formatAddr, 0, nil, &formatSize, &format) == noErr else { return nil }
        return (Int(format.mBitsPerChannel), format.mSampleRate)
    }

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
