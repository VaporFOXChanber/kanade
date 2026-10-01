import Foundation
@testable import Kanade

/// テストで使うサンプルレートと、リミッターの先読みによる遅れ (サンプル)
let testSampleRate = 48000.0
let latency = Int(0.003 * testSampleRate)

struct Stereo {
    var left: [Float]
    var right: [Float]
    var count: Int { left.count }
}

/// 区間ごとに左右の大きさ (RMS, dBFS) を決めた信号の 1 区間
struct Segment {
    let seconds: Double
    let left: Float
    let right: Float

    init(_ seconds: Double, _ left: Float, _ right: Float? = nil) {
        self.seconds = seconds
        self.left = left
        self.right = right ?? left
    }

    var frames: Int { Int(seconds * testSampleRate) }
}

/// 毎回同じ値が出る乱数 (テストの結果が実行のたびに変わらないように)
struct TestRandom {
    var seed: UInt64

    mutating func next() -> Float {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: seed >> 11) % 1_000_000) / 1_000_000 * 2 - 1
    }
}

/// ささやき声に近い、高域を落とした雑音。各区間の RMS は指定した値にぴったり合わせる
func noiseSignal(_ segments: [Segment], seed: UInt64 = 42) -> Stereo {
    var random = TestRandom(seed: seed)
    var out = Stereo(left: [], right: [])
    var state: (Float, Float) = (0, 0)
    for segment in segments {
        var l = [Float](repeating: 0, count: segment.frames), r = l
        for i in 0..<segment.frames {
            state.0 += 0.35 * (random.next() - state.0)
            state.1 += 0.35 * (random.next() - state.1)
            l[i] = state.0
            r[i] = state.1
        }
        out.left += scaled(l, toRMS: segment.left)
        out.right += scaled(r, toRMS: segment.right)
    }
    return out
}

private func scaled(_ x: [Float], toRMS target: Float) -> [Float] {
    let current = rmsDB(x, 0..<x.count)
    let gain = pow(10, (target - current) / 20)
    return x.map { $0 * gain }
}

func sine(_ frequency: Double, amplitude: Float, seconds: Double) -> Stereo {
    let n = Int(seconds * testSampleRate)
    let x = (0..<n).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / testSampleRate)) }
    return Stereo(left: x, right: x)
}

/// 処理本体 (ASMRKernel) を、実際の描画と同じく 512 サンプルずつ動かす。
/// `changes` に入れた設定は、そのサンプル位置に来たところで差し替える (再生中の設定変更)。
func process(_ input: Stereo, settings: ASMRSettings, changes: [(at: Int, settings: ASMRSettings)] = []) -> Stereo {
    var kernel = ASMRKernel()
    kernel.prepare(sampleRate: testSampleRate, maxFrames: 4096)
    defer { kernel.release() }
    let shared = ASMRShared()
    shared.publish(settings)

    var pending = changes.sorted { $0.at < $1.at }
    var left = input.left, right = input.right
    let total = input.count
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            var position = 0
            while position < total {
                while let change = pending.first, change.at <= position {
                    shared.publish(change.settings)
                    pending.removeFirst()
                }
                kernel.sync(shared)
                let frames = min(512, total - position)
                kernel.process(l.baseAddress! + position, r.baseAddress! + position, frames: frames)
                position += frames
            }
        }
    }
    return Stereo(left: left, right: right)
}

func rmsDB(_ x: [Float], _ range: Range<Int>) -> Float {
    var sum = 0.0
    for i in range { sum += Double(x[i]) * Double(x[i]) }
    return Float(10 * log10(sum / Double(max(1, range.count)) + 1e-20))
}

func peak(_ x: [Float], _ range: Range<Int>) -> Float {
    var m: Float = 0
    for i in range { m = max(m, abs(x[i])) }
    return m
}

/// 入力の `range` に対応する出力 (先読みの分だけ遅れている) との大きさの差 (dB)
func gainDB(_ input: [Float], _ output: [Float], _ range: Range<Int>) -> Float {
    let shifted = (range.lowerBound + latency)..<min(output.count, range.upperBound + latency)
    return rmsDB(output, shifted) - rmsDB(input, range)
}

/// いくつかの正弦波を重ねた信号 (左右で大きさを変えられる)
func tones(_ parts: [(frequency: Double, left: Float, right: Float)], seconds: Double) -> Stereo {
    let n = Int(seconds * testSampleRate)
    var out = Stereo(left: [Float](repeating: 0, count: n), right: [Float](repeating: 0, count: n))
    for part in parts {
        for i in 0..<n {
            let v = Float(sin(2 * Double.pi * part.frequency * Double(i) / testSampleRate))
            out.left[i] += part.left * v
            out.right[i] += part.right * v
        }
    }
    return out
}

/// 信号に含まれる、ある周波数の成分の大きさ (振幅)
func toneAmplitude(_ x: [Float], _ frequency: Double, _ range: Range<Int>) -> Float {
    var re = 0.0, im = 0.0
    for i in range {
        let phase = 2 * Double.pi * frequency * Double(i) / testSampleRate
        re += Double(x[i]) * cos(phase)
        im += Double(x[i]) * sin(phase)
    }
    return Float(2 * (re * re + im * im).squareRoot() / Double(range.count))
}

/// ある周波数の成分だけを見た、入力から出力への大きさの変化 (dB)
func toneGainDB(_ input: [Float], _ output: [Float], _ frequency: Double, _ range: Range<Int>) -> Float {
    let shifted = (range.lowerBound + latency)..<(range.upperBound + latency)
    return 20 * log10(toneAmplitude(output, frequency, shifted) / toneAmplitude(input, frequency, range))
}

/// 区間の並びから、n 番目の区間の後半 (ゲインが落ち着いたところ) の範囲を返す
func settledHalf(of index: Int, in segments: [Segment]) -> Range<Int> {
    let start = segments[..<index].reduce(0) { $0 + $1.frames }
    let frames = segments[index].frames
    return (start + frames / 2)..<(start + frames - latency)
}

func whole(_ index: Int, in segments: [Segment]) -> Range<Int> {
    let start = segments[..<index].reduce(0) { $0 + $1.frames }
    return start..<(start + segments[index].frames)
}
