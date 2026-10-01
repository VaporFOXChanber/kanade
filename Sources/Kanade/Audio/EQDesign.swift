import Foundation

/// パラメトリック EQ の 1 バンド
struct ParametricBand: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case peak, lowShelf, highShelf, highPass, lowPass
        var id: String { rawValue }
        var label: String {
            ["peak": "ピーク", "lowShelf": "ローシェルフ", "highShelf": "ハイシェルフ", "highPass": "ハイパス", "lowPass": "ローパス"][rawValue]!
        }
        /// ゲインを持つ種類か (ハイパス・ローパスにはない)
        var hasGain: Bool { self == .peak || self == .lowShelf || self == .highShelf }
    }

    var id = UUID()
    var kind: Kind = .peak
    /// 中心 (または折れ点) の周波数 (Hz)
    var frequency: Double = 1000
    /// 持ち上げ / 下げる量 (dB)
    var gain: Double = 0
    /// 鋭さ。大きいほど狭い範囲に効く
    var q: Double = 1
    var enabled = true
}

/// ヘッドホンごとの補正などをまとめた、名前つきのパラメトリック EQ の設定
struct EQProfile: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    /// 全体の音量の調整 (dB)。持ち上げるバンドがあるときは、その分を下げておくとクリップしない
    var preamp: Double = 0
    var bands: [ParametricBand] = []

    /// 音を変えない設定か
    var isFlat: Bool { abs(preamp) < 0.01 && bands.allSatisfy { !$0.enabled || ($0.kind.hasGain && abs($0.gain) < 0.01) } }
}

/// 2 次フィルター (バイクアッド) の設計。Audio EQ Cookbook (RBJ) の式による
enum EQDesign {
    /// 係数 [b0, b1, b2, a1, a2] (a0 = 1 に正規化)
    static func coefficients(_ band: ParametricBand, sampleRate: Double) -> [Double] {
        let identity: [Double] = [1, 0, 0, 0, 0]
        guard band.enabled, band.frequency > 0, band.frequency < sampleRate * 0.49, band.q > 0 else { return identity }
        if band.kind.hasGain, abs(band.gain) < 0.001 { return identity }
        let w0 = 2 * Double.pi * band.frequency / sampleRate
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * band.q)
        let A = pow(10, band.gain / 40)
        let b: (Double, Double, Double), a: (Double, Double, Double)
        switch band.kind {
        case .peak:
            b = (1 + alpha * A, -2 * cw, 1 - alpha * A)
            a = (1 + alpha / A, -2 * cw, 1 - alpha / A)
        case .lowShelf:
            let k = 2 * A.squareRoot() * alpha
            b = (A * ((A + 1) - (A - 1) * cw + k), 2 * A * ((A - 1) - (A + 1) * cw), A * ((A + 1) - (A - 1) * cw - k))
            a = ((A + 1) + (A - 1) * cw + k, -2 * ((A - 1) + (A + 1) * cw), (A + 1) + (A - 1) * cw - k)
        case .highShelf:
            let k = 2 * A.squareRoot() * alpha
            b = (A * ((A + 1) + (A - 1) * cw + k), -2 * A * ((A - 1) + (A + 1) * cw), A * ((A + 1) + (A - 1) * cw - k))
            a = ((A + 1) - (A - 1) * cw + k, 2 * ((A - 1) - (A + 1) * cw), (A + 1) - (A - 1) * cw - k)
        case .highPass:
            b = ((1 + cw) / 2, -(1 + cw), (1 + cw) / 2)
            a = (1 + alpha, -2 * cw, 1 - alpha)
        case .lowPass:
            b = ((1 - cw) / 2, 1 - cw, (1 - cw) / 2)
            a = (1 + alpha, -2 * cw, 1 - alpha)
        }
        return [b.0 / a.0, b.1 / a.0, b.2 / a.0, a.1 / a.0, a.2 / a.0]
    }

    /// 処理ユニットへ渡す係数の並び。先頭はプリアンプ (ゲインだけの段)
    static func stages(for profile: EQProfile, sampleRate: Double) -> [[Float]] {
        var out: [[Float]] = []
        if abs(profile.preamp) > 0.001 { out.append([Float(pow(10, profile.preamp / 20)), 0, 0, 0, 0]) }
        for band in profile.bands {
            let c = coefficients(band, sampleRate: sampleRate)
            if c != [1, 0, 0, 0, 0] { out.append(c.map { Float($0) }) }
        }
        return Array(out.prefix(ASMRShared.eqBands))
    }

    /// 設定全体の、ある周波数での変化量 (dB)
    static func response(of profile: EQProfile, at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
        var db = profile.preamp
        for band in profile.bands {
            let c = coefficients(band, sampleRate: sampleRate)
            let nr = c[0] + c[1] * c1 + c[2] * c2, ni = -(c[1] * s1 + c[2] * s2)
            let dr = 1 + c[3] * c1 + c[4] * c2, di = -(c[3] * s1 + c[4] * s2)
            db += 10 * log10((nr * nr + ni * ni) / (dr * dr + di * di))
        }
        return db
    }

    /// 設定全体で、どの周波数でも超えない持ち上げ量の見積もり (dB)。プリアンプの自動調整に使う
    static func peakGain(of profile: EQProfile, sampleRate: Double) -> Double {
        var flat = profile
        flat.preamp = 0
        var peak = -Double.infinity
        var f = 16.0
        while f < min(20000, sampleRate * 0.49) {
            peak = max(peak, response(of: flat, at: f, sampleRate: sampleRate))
            f *= pow(2, 1.0 / 24)
        }
        return peak
    }

    // MARK: AutoEQ / Equalizer APO の設定ファイル

    private static let filterLine = try! NSRegularExpression(
        pattern: #"^\s*Filter\s*\d*\s*:\s*(ON|OFF)\s+([A-Za-z]+)\s+Fc\s+([\d.]+)\s*Hz(?:\s+Gain\s+(-?[\d.]+)\s*dB)?(?:\s+Q\s+([\d.]+))?"#,
        options: .caseInsensitive)
    private static let preampLine = try! NSRegularExpression(pattern: #"^\s*Preamp\s*:\s*(-?[\d.]+)\s*dB"#, options: .caseInsensitive)

    /// AutoEQ の「ParametricEQ.txt」(Equalizer APO の書式) を読む。フィルターが 1 つもなければ nil
    ///
    ///     Preamp: -6.4 dB
    ///     Filter 1: ON PK Fc 105 Hz Gain -3.2 dB Q 0.70
    ///     Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
    static func parseAutoEQ(_ text: String) -> (preamp: Double, bands: [ParametricBand])? {
        var preamp = 0.0
        var bands: [ParametricBand] = []
        for line in text.components(separatedBy: .newlines) {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = preampLine.firstMatch(in: line, range: range) {
                preamp = Double(ns.substring(with: m.range(at: 1))) ?? 0
                continue
            }
            guard let m = filterLine.firstMatch(in: line, range: range) else { continue }
            func group(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)) }
            let kind: ParametricBand.Kind
            switch group(2)!.uppercased() {
            case "PK", "PEQ", "MODAL": kind = .peak
            case "LSC", "LS", "LSQ": kind = .lowShelf
            case "HSC", "HS", "HSQ": kind = .highShelf
            case "HP", "HPQ": kind = .highPass
            case "LP", "LPQ": kind = .lowPass
            default: continue
            }
            guard let frequency = group(3).flatMap(Double.init), frequency > 0 else { continue }
            bands.append(ParametricBand(kind: kind, frequency: frequency, gain: group(4).flatMap(Double.init) ?? 0,
                                        q: group(5).flatMap(Double.init) ?? 0.7071, enabled: group(1)!.uppercased() == "ON"))
        }
        return bands.isEmpty ? nil : (preamp, bands)
    }
}
