import AVFoundation

/// イヤホンの左右を確かめるための音。左で 1 回 (低い音)、右で 2 回 (高い音) 鳴る
enum ChannelCheck {
    static let sampleRate = 48000.0
    static let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    static let duration = 1.9
    /// 音の山の大きさ (-20 dBFS)。ささやき声と同じくらいで、驚かない程度にする
    static let level: Float = 0.1

    static func samples() -> (left: [Float], right: [Float]) {
        let count = Int(duration * sampleRate)
        var left = [Float](repeating: 0, count: count), right = left
        // 立ち上がりを丸め、ゆっくり消える「ポン」という音
        func strike(_ channel: inout [Float], at start: Double, frequency: Double) {
            let from = Int(start * sampleRate)
            let length = Int(0.5 * sampleRate)
            for i in 0..<length where from + i < count {
                let t = Double(i) / sampleRate
                let attack = t < 0.012 ? 0.5 - 0.5 * cos(Double.pi * t / 0.012) : 1
                let release = t > 0.45 ? 0.5 + 0.5 * cos(Double.pi * (t - 0.45) / 0.05) : 1
                let envelope = attack * exp(-t / 0.13) * release
                let tone = sin(2 * Double.pi * frequency * t) + 0.25 * sin(4 * Double.pi * frequency * t)
                channel[from + i] += level * Float(envelope * tone / 1.25)
            }
        }
        strike(&left, at: 0.05, frequency: 587.33)
        strike(&right, at: 0.85, frequency: 783.99)
        strike(&right, at: 1.2, frequency: 783.99)
        return (left, right)
    }

    static func makeBuffer() -> AVAudioPCMBuffer? {
        let (left, right) = samples()
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(left.count)
        for i in 0..<left.count {
            data[0][i] = left[i]
            data[1][i] = right[i]
        }
        return buffer
    }
}
