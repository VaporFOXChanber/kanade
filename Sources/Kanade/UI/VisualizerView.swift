import AppKit
import QuartzCore
import SwiftUI

/// スペクトラム / ミラー / オシロスコープ表示。
/// 毎フレームの描画は Core Animation のレイヤーで行い、SwiftUI のレイアウトを走らせない。
struct VisualizerView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        SpectrumLayerView(analyzer: model.engine.spectrum,
                          style: model.visualizer,
                          playing: model.isPlaying,
                          colors: [NSColor(model.palette.accent), NSColor(model.palette.secondary)])
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { model.visualizer = model.visualizer.next } }
            .help("クリックで表示を切り替え")
    }
}

private struct SpectrumLayerView: NSViewRepresentable {
    let analyzer: SpectrumAnalyzer
    let style: VisualizerStyle
    let playing: Bool
    let colors: [NSColor]

    func makeNSView(context: Context) -> SpectrumNSView { SpectrumNSView(analyzer: analyzer) }

    func updateNSView(_ view: SpectrumNSView, context: Context) {
        view.colors = colors
        view.style = style
        view.playing = playing
    }
}

final class SpectrumNSView: NSView {
    private let analyzer: SpectrumAnalyzer
    private let state = VisualizerState()
    private let gradient = CAGradientLayer()
    private let shape = CAShapeLayer()
    private let caps = CAShapeLayer()
    private var link: CADisplayLink?
    private var occlusionObserver: NSObjectProtocol?

    var style: VisualizerStyle = .bars { didSet { if style != oldValue { wake() } } }
    var playing = false { didSet { if playing != oldValue { wake() } } }
    var colors: [NSColor] = [] {
        didSet {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.6)
            gradient.colors = colors.map(\.cgColor)
            CATransaction.commit()
        }
    }

    init(analyzer: SpectrumAnalyzer) {
        self.analyzer = analyzer
        super.init(frame: .zero)
        wantsLayer = true
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        gradient.mask = shape
        caps.fillColor = NSColor(white: 1, alpha: 0.7).cgColor
        layer?.addSublayer(gradient)
        layer?.addSublayer(caps)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        shape.frame = bounds
        caps.frame = bounds
        CATransaction.commit()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = occlusionObserver { NotificationCenter.default.removeObserver(o) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                       object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
        }
        wake()
    }

    private var isVisibleOnScreen: Bool { window?.occlusionState.contains(.visible) ?? false }

    private func wake() {
        guard isVisibleOnScreen, style != .off else {
            stop()
            render()
            return
        }
        guard link == nil else { return }
        let l = displayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        state.update(frame: playing ? analyzer.frame(at: now) : nil, now: now)
        render()
        if !playing, state.isIdle { stop() }
    }

    private func render() {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch style {
        case .bars, .mirror:
            let (bars, capPath) = barPaths(size, mirror: style == .mirror)
            shape.path = bars
            shape.fillColor = NSColor.black.cgColor
            shape.strokeColor = nil
            caps.path = capPath
        case .wave:
            shape.path = wavePath(size)
            shape.fillColor = nil
            shape.strokeColor = NSColor.black.cgColor
            shape.lineWidth = 2
            shape.lineJoin = .round
            shape.lineCap = .round
            caps.path = nil
        case .off:
            shape.path = nil
            caps.path = nil
        }
        CATransaction.commit()
    }

    // レイヤー座標は下が y=0
    private func barPaths(_ size: CGSize, mirror: Bool) -> (CGPath, CGPath?) {
        let values = state.resampled(to: max(8, min(SpectrumAnalyzer.bandCount, Int(size.width / 7))))
        let capValues = state.resampledCaps(to: values.count)
        let n = values.count
        let step = size.width / CGFloat(n)
        let barW = max(2, step * 0.58)
        let h = size.height
        let bars = CGMutablePath(), capPath = CGMutablePath()
        for i in 0..<n {
            let x = CGFloat(i) * step + (step - barW) / 2
            let v = CGFloat(values[i])
            let rect: CGRect
            if mirror {
                let bh = max(1.5, v * h * 0.96)
                rect = CGRect(x: x, y: (h - bh) / 2, width: barW, height: bh)
            } else {
                let bh = max(1.5, v * (h - 5))
                rect = CGRect(x: x, y: 0, width: barW, height: bh)
                if capValues[i] > 0.04 {
                    capPath.addRoundedRect(in: CGRect(x: x, y: CGFloat(capValues[i]) * (h - 5) + 2, width: barW, height: 2),
                                           cornerWidth: 1, cornerHeight: 1)
                }
            }
            let r = min(barW, rect.height) / 2
            bars.addRoundedRect(in: rect, cornerWidth: r, cornerHeight: r)
        }
        return (bars, mirror ? nil : capPath)
    }

    private func wavePath(_ size: CGSize) -> CGPath {
        let wave = state.wave
        let path = CGMutablePath()
        guard wave.count > 1 else { return path }
        let mid = size.height / 2
        for (i, s) in wave.enumerated() {
            let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(wave.count - 1),
                            y: mid + CGFloat(max(-1, min(1, s * 2.2))) * mid * 0.9)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }
}

/// 描画用の平滑化状態 (アタックは速く、リリースはゆっくり)
final class VisualizerState {
    private(set) var bands = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private(set) var caps = [Float](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private var capHold = [Double](repeating: 0, count: SpectrumAnalyzer.bandCount)
    private(set) var wave = [Float](repeating: 0, count: SpectrumAnalyzer.waveCount)
    private var last: CFTimeInterval = 0

    var isIdle: Bool {
        bands.allSatisfy { $0 < 0.004 } && caps.allSatisfy { $0 < 0.004 } && wave.allSatisfy { abs($0) < 0.002 }
    }

    func update(frame: SpectrumAnalyzer.Frame?, now: CFTimeInterval) {
        let dt = Float(min(0.1, max(0.001, last == 0 ? 1.0 / 60 : now - last)))
        last = now
        let target = frame?.bands ?? []
        for i in bands.indices {
            let t = i < target.count ? target[i] : 0
            bands[i] += (t - bands[i]) * min(1, dt * (t > bands[i] ? 28 : 7))
            if bands[i] >= caps[i] {
                caps[i] = bands[i]
                capHold[i] = now + 0.35
            } else if now > capHold[i] {
                caps[i] = max(bands[i], caps[i] - dt * 0.9)
            }
        }
        let w = frame?.wave ?? []
        for i in wave.indices {
            let t = i < w.count ? w[i] : 0
            wave[i] += (t - wave[i]) * min(1, dt * 30)
        }
    }

    func resampled(to n: Int) -> [Float] { resample(bands, n) }
    func resampledCaps(to n: Int) -> [Float] { resample(caps, n) }

    private func resample(_ src: [Float], _ n: Int) -> [Float] {
        guard n < src.count else { return src }
        return (0..<n).map { i in
            let a = i * src.count / n, b = max(a + 1, (i + 1) * src.count / n)
            return src[a..<b].max() ?? 0
        }
    }
}
