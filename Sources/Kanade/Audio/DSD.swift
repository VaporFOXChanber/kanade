import CryptoKit
import Foundation

/// DSD のファイル (DSF / DSDIFF) の読み取り
enum DSDFile {
    enum Layout: Equatable {
        /// DSF: チャンネルごとに blockSize バイトずつ並ぶ。lsbFirst なら、バイトの中で時間の早いビットが下位にある
        case dsf(blockSize: Int, lsbFirst: Bool)
        /// DSDIFF: チャンネルが 1 バイトずつ交互に並ぶ (時間の早いビットが上位)
        case dff
    }

    struct Info: Equatable {
        /// 1 秒あたりのビット数 (DSD64 なら 2,822,400)
        var sampleRate: Double
        var channels: Int
        /// 1 チャンネルあたりのビット数
        var bitCount: Int64
        /// データの始まる位置と長さ (バイト)
        var dataOffset: UInt64
        var dataLength: UInt64
        var layout: Layout

        var duration: Double { sampleRate > 0 ? Double(bitCount) / sampleRate : 0 }
        /// "DSD64" のような呼び名
        var label: String { "DSD\(Int((sampleRate / 44100).rounded()))" }
    }

    static let extensions: Set<String> = ["dsf", "dff"]

    /// ファイルの先頭を読んで、形式を調べる。DSD でない、または圧縮 (DST) されていて読めないなら nil
    static func info(_ url: URL) -> Info? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return nil }
        switch String(decoding: head, as: UTF8.self) {
        case "DSD ": return dsfInfo(handle)
        case "FRM8": return dffInfo(handle)
        default: return nil
        }
    }

    private static func dsfInfo(_ handle: FileHandle) -> Info? {
        // "DSD " チャンク (28 バイト) の次に "fmt " チャンク (52 バイト)、その次に "data" チャンク
        guard (try? handle.seek(toOffset: 0)) != nil, let d = try? handle.read(upToCount: 92), d.count == 92 else { return nil }
        func u32(_ at: Int) -> UInt32 { d.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian }
        func u64(_ at: Int) -> UInt64 { d.subdata(in: at..<at + 8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.littleEndian }
        guard String(decoding: d[28..<32], as: UTF8.self) == "fmt ", u64(32) == 52, u32(44) == 0,   // 形式 ID 0 = そのままの DSD
              String(decoding: d[80..<84], as: UTF8.self) == "data" else { return nil }
        let channels = Int(u32(52)), rate = Double(u32(56)), bits = u32(60), blockSize = Int(u32(72))
        let count = Int64(u64(64)), dataSize = u64(84)
        guard channels > 0, rate > 0, bits == 1 || bits == 8, blockSize > 0, count > 0, dataSize > 12 else { return nil }
        return Info(sampleRate: rate, channels: channels, bitCount: count, dataOffset: 92, dataLength: dataSize - 12,
                    layout: .dsf(blockSize: blockSize, lsbFirst: bits == 1))
    }

    private static func dffInfo(_ handle: FileHandle) -> Info? {
        func read(_ count: Int) -> Data? {
            guard let d = try? handle.read(upToCount: count), d.count == count else { return nil }
            return d
        }
        func be64(_ d: Data) -> UInt64 { d.reduce(0) { $0 << 8 | UInt64($1) } }
        guard (try? handle.seek(toOffset: 4)) != nil, let size = read(8), let form = read(4),
              String(decoding: form, as: UTF8.self) == "DSD " else { return nil }
        let end = 12 + be64(size)
        var offset: UInt64 = 16
        var rate = 0.0, channels = 0, compressed = false
        while offset + 12 <= end {
            guard (try? handle.seek(toOffset: offset)) != nil, let header = read(12) else { return nil }
            let id = String(decoding: header.prefix(4), as: UTF8.self), length = be64(header.suffix(8))
            switch id {
            case "PROP":
                // "SND " のあとに、サンプルレート・チャンネル・圧縮方式の小さなチャンクが並ぶ
                guard length >= 4, length < 1 << 20, let body = read(Int(length)) else { return nil }
                var p = 4
                while p + 12 <= body.count {
                    let sub = String(decoding: body[body.startIndex + p..<body.startIndex + p + 4], as: UTF8.self)
                    let subLength = Int(be64(body.subdata(in: body.startIndex + p + 4..<body.startIndex + p + 12)))
                    let start = body.startIndex + p + 12
                    guard subLength >= 0, start + subLength <= body.endIndex else { break }
                    let content = body.subdata(in: start..<start + subLength)
                    if sub == "FS  ", content.count >= 4 { rate = Double(be64(content.prefix(4))) }
                    if sub == "CHNL", content.count >= 2 { channels = Int(be64(content.prefix(2))) }
                    if sub == "CMPR", content.count >= 4 { compressed = String(decoding: content.prefix(4), as: UTF8.self) != "DSD " }
                    p += 12 + subLength + (subLength & 1)
                }
            case "DSD ":
                guard !compressed, rate > 0, channels > 0, length > 0 else { return nil }
                return Info(sampleRate: rate, channels: channels, bitCount: Int64(length) / Int64(channels) * 8,
                            dataOffset: offset + 12, dataLength: length, layout: .dff)
            case "DST ":
                return nil   // 圧縮された DSD は、そのままでは送れない
            default: break
            }
            offset += 12 + length + (length & 1)
        }
        return nil
    }
}

/// DoP (DSD over PCM): DSD のビットを、24bit の PCM の形に包んで DAC へ送る方式。
/// 1 サンプルは「目印 8bit (0x05 と 0xFA を交互に) + DSD 16bit」。対応した DAC は目印を見て、中身を DSD として再生する。
/// 途中で 1 ビットでも変わる (音量を掛ける、ほかの音と混ざる、サンプルレートを変換する) と DSD として読めなくなり、
/// 雑音として鳴ってしまう。そのため、送っている間は一切の加工を通さない
enum DoP {
    static let markers: [UInt8] = [0x05, 0xFA]
    /// 無音を表す DSD のビットの並び
    static let silence: UInt8 = 0x69

    /// DSD のビットレートに対する、包んだあとの PCM のサンプルレート (DSD64 → 176.4kHz)
    static func pcmRate(forDSD rate: Double) -> Double { rate / 16 }

    /// 包んだファイルの置き場所 (変換キャッシュの中)
    static func cacheURL(for source: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("dop|\(source.path)|\(size)|\(mtime)".utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return FFmpeg.cacheDirectory.appendingPathComponent(name + ".dop.wav")
    }

    enum Failure: LocalizedError {
        case unsupported(String)
        var errorDescription: String? {
            switch self { case .unsupported(let reason): reason }
        }
    }

    /// DSD のファイルを DoP の WAV (24bit) に包み直す (キャッシュあり)。音のデータは 1 ビットも変えない
    static func convert(_ source: URL) throws -> URL {
        let dest = cacheURL(for: source)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        }
        guard let info = DSDFile.info(source) else { throw Failure.unsupported("DSD のファイルとして読めません") }
        let temp = dest.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part.wav")
        do {
            try wrap(source, info: info, to: temp)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        FFmpeg.pruneCache()
        return dest
    }

    /// WAV のヘッダー (24bit・ステレオ)
    static func wavHeader(frames: Int, rate: Double) -> Data {
        var d = Data()
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(frames * 6)
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(2)
        le32(UInt32(rate)); le32(UInt32(rate) * 6); le16(6); le16(24)
        d.append(contentsOf: Array("data".utf8)); le32(bytes)
        return d
    }

    /// 左右の DSD のバイト列 (時間の早いビットが上位) を、DoP のサンプルに詰める。
    /// firstFrame は、このかたまりの最初のサンプルが全体の何番目か (目印の順番を決める)
    static func pack(left: UnsafeBufferPointer<UInt8>, right: UnsafeBufferPointer<UInt8>, frames: Int, firstFrame: Int,
                     into out: UnsafeMutableBufferPointer<UInt8>) {
        for f in 0..<frames {
            let marker = markers[(firstFrame + f) & 1]
            let o = f * 6
            // 24bit のリトルエンディアン: 下位から「あとの 8 ビット・先の 8 ビット・目印」
            out[o] = left[2 * f + 1]; out[o + 1] = left[2 * f]; out[o + 2] = marker
            out[o + 3] = right[2 * f + 1]; out[o + 4] = right[2 * f]; out[o + 5] = marker
        }
    }

    private static let reversed: [UInt8] = (0..<256).map { v in
        var x = UInt8(v), r: UInt8 = 0
        for _ in 0..<8 { r = r << 1 | x & 1; x >>= 1 }
        return r
    }

    /// DSD のファイルの中身を、DoP の WAV として dest に書き出す
    static func wrap(_ source: URL, info: DSDFile.Info, to dest: URL) throws {
        guard info.channels == 2 else { throw Failure.unsupported("ステレオ以外の DSD は、DoP では送れません") }
        // 16 ビットで 1 サンプル。目印が交互に続くよう、サンプル数は偶数にそろえる (曲をつなげて再生しても順番が崩れない)
        var frames = Int(min(info.bitCount, Int64(info.dataLength) * 8 / Int64(info.channels)) / 16)
        frames -= frames & 1
        guard frames > 0 else { throw Failure.unsupported("DSD のデータがありません") }
        guard frames * 6 < 0xFFFF_0000 else { throw Failure.unsupported("長すぎて、DoP のファイルにできません") }

        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source), output = try FileHandle(forWritingTo: dest)
        defer {
            try? input.close()
            try? output.close()
        }
        try output.write(contentsOf: wavHeader(frames: frames, rate: pcmRate(forDSD: info.sampleRate)))
        try input.seek(toOffset: info.dataOffset)

        var written = 0
        switch info.layout {
        case .dsf(let blockSize, let lsbFirst):
            // 左のブロック、右のブロック、の順に並んでいる
            var left = [UInt8](repeating: 0, count: blockSize), right = left
            var out = [UInt8](repeating: 0, count: blockSize / 2 * 6)
            while written < frames {
                guard let chunk = try input.read(upToCount: blockSize * 2), chunk.count == blockSize * 2 else { break }
                chunk.withUnsafeBytes { raw in
                    let p = raw.bindMemory(to: UInt8.self)
                    for i in 0..<blockSize {
                        left[i] = lsbFirst ? reversed[Int(p[i])] : p[i]
                        right[i] = lsbFirst ? reversed[Int(p[blockSize + i])] : p[blockSize + i]
                    }
                }
                let count = min(blockSize / 2, frames - written)
                left.withUnsafeBufferPointer { l in
                    right.withUnsafeBufferPointer { r in
                        out.withUnsafeMutableBufferPointer { pack(left: l, right: r, frames: count, firstFrame: written, into: $0) }
                    }
                }
                try output.write(contentsOf: Data(out[0..<count * 6]))
                written += count
            }
        case .dff:
            // 左右が 1 バイトずつ交互に並んでいる
            let step = 1 << 15   // 一度に詰めるサンプル数
            var left = [UInt8](repeating: 0, count: step * 2), right = left
            var out = [UInt8](repeating: 0, count: step * 6)
            while written < frames {
                let count = min(step, frames - written)
                guard let chunk = try input.read(upToCount: count * 4), chunk.count == count * 4 else { break }
                chunk.withUnsafeBytes { raw in
                    let p = raw.bindMemory(to: UInt8.self)
                    for i in 0..<count * 2 {
                        left[i] = p[2 * i]
                        right[i] = p[2 * i + 1]
                    }
                }
                left.withUnsafeBufferPointer { l in
                    right.withUnsafeBufferPointer { r in
                        out.withUnsafeMutableBufferPointer { pack(left: l, right: r, frames: count, firstFrame: written, into: $0) }
                    }
                }
                try output.write(contentsOf: Data(out[0..<count * 6]))
                written += count
            }
        }
        guard written == frames else { throw Failure.unsupported("DSD のデータが途中で切れています") }
    }

    // MARK: 確認用の音

    /// 対応を確かめるための音のファイル (DSD64 の DoP、約 5 秒)。なければ作る
    static func testToneURL() throws -> URL {
        let url = FFmpeg.cacheDirectory.appendingPathComponent("dop-check-v1.dop.wav")
        if !FileManager.default.fileExists(atPath: url.path) { try testTone().write(to: url, options: .atomic) }
        return url
    }

    /// 確認用の音: 440Hz を、0.8 秒鳴らして 0.5 秒休む、を 4 回 (出だしと終わりは 40 ms かけてなめらかに)。
    /// 大きさは、DSD の基準の大きさより 14 dB 小さい
    static func testTone(seconds: Double = 5.2) -> Data {
        let rate = 2_822_400.0
        let bytes = DSDModulator.encode(count: Int(seconds * rate) / 16 * 16) { n in
            let t = Double(n) / rate, cycle = t.truncatingRemainder(dividingBy: 1.3)
            guard cycle < 0.8 else { return 0 }
            let edge = min(1, min(cycle, 0.8 - cycle) / 0.04)
            return 0.1 * (0.5 - 0.5 * cos(.pi * edge)) * sin(2 * .pi * 440 * t)
        }
        var frames = bytes.count / 2
        frames -= frames & 1
        var data = wavHeader(frames: frames, rate: pcmRate(forDSD: rate))
        var out = [UInt8](repeating: 0, count: frames * 6)
        bytes.withUnsafeBufferPointer { b in
            out.withUnsafeMutableBufferPointer { pack(left: b, right: b, frames: frames, firstFrame: 0, into: $0) }
        }
        data.append(contentsOf: out)
        return data
    }

    // MARK: 送ってよいかの判断

    /// 出力デバイスが DoP に対応しているかの確認結果 (利用者が、小さい音量で実際に聴いて確かめたもの)
    enum Support: String, Codable {
        /// 対応している
        case verified
        /// 対応しているが、DAC の音量を最大にしているときだけ (音量を下げると DSD として読めなくなる DAC)
        case verifiedAtFullVolume
        /// 対応していない (雑音になった)
        case unsupported
    }

    /// DSD の曲を再生するときの出力の状況
    struct Conditions: Equatable {
        /// 「DSD をそのまま送る」の設定
        var enabled: Bool
        var bitPerfect: Bool
        /// 排他モードを取れているか (ほかのアプリの音が混ざらない)
        var exclusive: Bool
        var support: Support?
        /// デバイスが受け付けるサンプルレート
        var deviceRates: [Double]
        /// 送り先のサンプルレートで使える、整数の形式のうちビット数のいちばん多いもの (なければ nil)
        var integerBits: Int?
        /// デバイス側の音量 (0〜1。Mac から変えられないデバイスなら nil)
        var deviceVolume: Double?
    }

    enum Plan: Equatable {
        /// DoP で送る (PCM としてのサンプルレート)
        case send(rate: Double)
        /// 送らない (PCM に変換して再生する)。理由は、設定がオフのときなど、わざわざ知らせなくてよいなら nil
        case convert(reason: String?)
    }

    /// DSD の曲を DoP で送るかどうかを決める。対応しているか分からないデバイスへは送らない
    static func plan(for info: DSDFile.Info?, _ c: Conditions) -> Plan {
        guard let info else { return .convert(reason: nil) }
        guard c.enabled else { return .convert(reason: nil) }
        guard info.channels == 2 else { return .convert(reason: "ステレオ以外の DSD") }
        guard c.bitPerfect else { return .convert(reason: "ビットパーフェクト再生がオフ") }
        guard c.exclusive else { return .convert(reason: "排他モードがオフ") }
        let rate = pcmRate(forDSD: info.sampleRate)
        guard c.deviceRates.contains(where: { abs($0 - rate) < 0.5 }) else {
            return .convert(reason: "デバイスが \(String(format: "%g", rate / 1000))kHz に非対応")
        }
        guard let bits = c.integerBits, bits >= 24 else { return .convert(reason: "デバイスに 24bit の形式がない") }
        switch c.support {
        case nil: return .convert(reason: "DAC の対応を未確認")
        case .unsupported: return .convert(reason: "DAC が DoP に非対応")
        case .verifiedAtFullVolume:
            guard let volume = c.deviceVolume, volume < 0.999 else { return .send(rate: rate) }
            return .convert(reason: "DAC の音量が最大でない")
        case .verified: return .send(rate: rate)
        }
    }
}

/// PCM の波形を DSD のビット列に直す (確認用の音を作るための、簡単な 2 次のデルタシグマ変調)
enum DSDModulator {
    /// count ビット分を作って、時間の早いビットを上位にしたバイト列で返す。input は -0.5〜0.5 程度の波形
    static func encode(count: Int, input: (Int) -> Double) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count / 8)
        var s1 = 0.0, s2 = 0.0
        for i in 0..<bytes.count {
            var byte: UInt8 = 0
            for bit in 0..<8 {
                let y = s2 >= 0 ? 1.0 : -1.0
                s1 += input(i * 8 + bit) - y
                s2 += s1 - y
                byte = byte << 1 | (y > 0 ? 1 : 0)
            }
            bytes[i] = byte
        }
        return bytes
    }

    /// DSD のバイト列 (時間の早いビットが上位) を、移動平均でならして波形に戻す (テスト用の、ごく簡単な復調)
    static func decode(_ bytes: [UInt8], window: Int = 64) -> [Double] {
        var bits = [Double]()
        bits.reserveCapacity(bytes.count * 8)
        for b in bytes { for k in (0..<8).reversed() { bits.append(b >> UInt8(k) & 1 == 1 ? 1 : -1) } }
        var out = [Double](repeating: 0, count: max(0, bits.count - window))
        var sum = bits.prefix(window).reduce(0, +)
        for i in 0..<out.count {
            out[i] = sum / Double(window)
            sum += bits[i + window] - bits[i]
        }
        return out
    }
}
