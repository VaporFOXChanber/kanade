import AVFoundation
import Testing
@testable import Kanade

@Suite("ビットパーフェクト再生")
struct BitPerfectTests {
    private typealias Format = OutputDevice.PhysicalFormat

    /// USB DAC によくある形式の一覧 (16 / 24 / 32bit の整数。ほかのアプリと混ぜられる形式と、混ぜられない形式)
    private var dacFormats: [Format] {
        [32, 24, 16].flatMap { bits in [true, false].map { Format(rate: 96000, bits: bits, mixable: $0) } }
    }

    @Test("デバイスが 16bit になっていて曲が 24bit なら、24bit の形式へ切り替える")
    func raisesDepth() {
        let current = Format(rate: 96000, bits: 16)
        #expect(OutputDevice.betterFormat(needed: 24, current: current, available: dacFormats) == Format(rate: 96000, bits: 24))
        // 20bit の曲も、足りるいちばん少ないビット数 (24bit) へ
        #expect(OutputDevice.betterFormat(needed: 20, current: current, available: dacFormats) == Format(rate: 96000, bits: 24))
        // 32bit の曲でも、アプリの中で運べるのは 24bit 分までなので、24bit で足りる
        #expect(OutputDevice.betterFormat(needed: 32, current: current, available: dacFormats) == Format(rate: 96000, bits: 24))
    }

    @Test("今の形式で曲のデータを運べるなら、切り替えない")
    func keepsEnoughDepth() {
        #expect(OutputDevice.betterFormat(needed: 16, current: Format(rate: 96000, bits: 16), available: dacFormats) == nil)
        #expect(OutputDevice.betterFormat(needed: 24, current: Format(rate: 96000, bits: 24), available: dacFormats) == nil)
        #expect(OutputDevice.betterFormat(needed: 16, current: Format(rate: 96000, bits: 32), available: dacFormats) == nil)
        // 内蔵スピーカーのような 32bit 浮動小数点は、24bit 分を運べる
        let float = Format(rate: 48000, bits: 32, isFloat: true)
        #expect(float.precision == 24)
        #expect(OutputDevice.betterFormat(needed: 24, current: float, available: [float]) == nil)
        #expect(OutputDevice.betterFormat(needed: 32, current: float, available: [float]) == nil)
    }

    @Test("足りる形式がなければ、いちばん多く運べる形式にする。今より良くならないなら切り替えない")
    func bestEffortDepth() {
        let current = Format(rate: 48000, bits: 16)
        #expect(OutputDevice.betterFormat(needed: 24, current: current,
                                          available: [Format(rate: 48000, bits: 16), Format(rate: 48000, bits: 20)])
                == Format(rate: 48000, bits: 20))
        #expect(OutputDevice.betterFormat(needed: 24, current: current, available: [Format(rate: 48000, bits: 16)]) == nil)
        #expect(OutputDevice.betterFormat(needed: 24, current: current, available: []) == nil)
    }

    @Test("チャンネル数の違う形式や、ほかのアプリと混ぜられない形式には切り替えない。整数の形式を優先する")
    func keepsKindOfFormat() {
        let current = Format(rate: 48000, bits: 16)
        let available = [
            Format(rate: 48000, bits: 24, channels: 8), Format(rate: 48000, bits: 24, mixable: false),
            Format(rate: 48000, bits: 32, isFloat: true), Format(rate: 48000, bits: 32),
        ]
        #expect(OutputDevice.betterFormat(needed: 24, current: current, available: available) == Format(rate: 48000, bits: 32))
        // 整数の形式がなければ、浮動小数点でもよい
        #expect(OutputDevice.betterFormat(needed: 24, current: current, available: Array(available.prefix(3)))
                == Format(rate: 48000, bits: 32, isFloat: true))
    }

    @Test("アプリの音量で下げていた分は、dB に直してデバイス側で下げる", arguments: [
        (1.0, 0.0), (0.9999, 0.0), (0.5, 12.04), (0.8, 3.88), (0.1, 40.0), (0.0, 120.0),
    ])
    func appVolumeAttenuation(volume: Double, expected: Double) {
        #expect(abs(DeviceVolumeOffsets.attenuation(ofAppVolume: volume) - expected) < 0.01)
    }

    @Test("デバイス側で下げた量はデバイスごとに覚え、同じデバイスを二重には下げない")
    func remembersLoweredDevices() throws {
        var offsets = DeviceVolumeOffsets()
        #expect(!offsets.isLowered("dac"))
        offsets.record("dac", db: 12)
        offsets.record("speakers", db: 0)          // 下げる必要がなかったデバイスも「合わせてある」
        #expect(offsets.isLowered("dac") && offsets.isLowered("speakers"))
        #expect(offsets.devices == ["dac", "speakers"])
        // 保存して読み直しても同じ
        let restored = try JSONDecoder().decode(DeviceVolumeOffsets.self, from: JSONEncoder().encode(offsets))
        #expect(restored == offsets)
        // 戻すときに取り出すと、もう覚えていない
        #expect(offsets.take("dac") == 12)
        #expect(offsets.take("dac") == nil)
        #expect(offsets.takeAll() == ["speakers": 0])
        #expect(offsets.devices.isEmpty)
    }

    @Test("デバイス側で下げきれない分だけ、音が大きくなる (切り替える前に確かめる)")
    func loudnessJump() {
        #expect(OutputDevice.loudnessJump(attenuation: 12, room: 30) == 0)   // 下げきれる
        #expect(OutputDevice.loudnessJump(attenuation: 12, room: 5) == 7)    // 範囲の端で止まる
        #expect(OutputDevice.loudnessJump(attenuation: 12, room: 0) == 12)   // Mac から音量を変えられないデバイス
        #expect(OutputDevice.loudnessJump(attenuation: 0, room: 0) == 0)     // もともとアプリの音量が最大
    }

    @Test("曲のビット数を出力まで運べないときは、シグナルパスにそのことを出す")
    func depthReduction() {
        #expect(SignalPath.depthReduction(source: 24, output: 16) == "24bit → 16bit（デバイスの形式）")
        #expect(SignalPath.depthReduction(source: 16, output: 16) == nil)
        #expect(SignalPath.depthReduction(source: 24, output: 24) == nil)
        #expect(SignalPath.depthReduction(source: 16, output: 24) == nil)
        #expect(SignalPath.depthReduction(source: 24, output: nil) == nil)    // デバイスの形式が分からない
        #expect(SignalPath.depthReduction(source: nil, output: 16) == nil)    // MP3 など、ビット深度の決まっていない音源
        #expect(SignalPath.depthReduction(source: 32, output: 32) == "32bit → 24bit 相当（32bit 浮動小数点で処理）")
        #expect(SignalPath.depthReduction(source: 32, output: 16) == "32bit → 16bit（デバイスの形式）")
    }

    /// 無音 1 秒のファイルを、指定した形式で書く (FLAC は、短すぎると中身のないファイルになる)
    private func makeFile(_ name: String, settings: [String: Any]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-bits-\(UUID().uuidString)-\(name)")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        buffer.frameLength = 44100
        var all: [String: Any] = [AVSampleRateKey: 44100.0, AVNumberOfChannelsKey: 2]
        all.merge(settings) { _, new in new }
        let writer = try AVAudioFile(forWriting: url, settings: all)
        try writer.write(from: buffer)
        writer.close()
        return url
    }

    @Test("曲のビット深度を、ファイルから読む (圧縮音源と浮動小数点の音源は決まっていない)")
    func readsSourceBits() throws {
        func pcm(_ bits: Int, float: Bool = false) -> [String: Any] {
            [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: float,
             AVLinearPCMIsBigEndianKey: false]
        }
        let cases: [(String, [String: Any], Int?)] = [
            ("16.wav", pcm(16), 16),
            ("24.wav", pcm(24), 24),
            ("float.wav", pcm(32, float: true), nil),
            ("24.flac", [AVFormatIDKey: kAudioFormatFLAC, AVEncoderBitDepthHintKey: 24], 24),
            ("24.m4a", [AVFormatIDKey: kAudioFormatAppleLossless, AVEncoderBitDepthHintKey: 24], 24),
            ("aac.m4a", [AVFormatIDKey: kAudioFormatMPEG4AAC], nil),
        ]
        for (name, settings, expected) in cases {
            do {
                let url = try makeFile(name, settings: settings)
                defer { try? FileManager.default.removeItem(at: url) }
                let item = PlaybackItem(trackID: UUID(), file: try AVAudioFile(forReading: url), source: url, start: 0, end: nil, gain: 1)
                #expect(item.sourceBits == expected, "\(name)")
            } catch {
                Issue.record("\(name): \(error)")
            }
        }
    }

    @Test("出力デバイスの形式と音量を読める (読むだけで、切り替えはしない)")
    func readsDeviceFormatAndVolume() throws {
        let device = try #require(AudioOutputs.defaultDeviceID())
        let format = try #require(OutputDevice.physicalFormat(device))
        #expect(format.bits > 0 && format.channels > 0)
        // 今の形式は、デバイスが受け付ける形式の一覧に入っている
        #expect(OutputDevice.availablePhysicalFormats(device, rate: format.rate).contains(format))
        if let volume = OutputDevice.volume(device) { #expect((0...1).contains(volume)) }
        #expect(OutputDevice.volumeRoomBelow(device) >= 0)
    }
}
