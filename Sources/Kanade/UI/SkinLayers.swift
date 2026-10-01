import AppKit
import ImageIO
import QuartzCore
import SwiftUI

// MARK: - ディスプレイリンクで動く NSView の土台

/// 画面に見えている間だけ毎フレーム `tick` を呼ぶ。`tick` が false を返すと止まる。
class DisplayLinkView: NSView {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

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

    var needsFrames: Bool { false }

    func wake() {
        guard window?.occlusionState.contains(.visible) == true, needsFrames else {
            link?.invalidate()
            link = nil
            return
        }
        guard link == nil else { return }
        last = 0
        let l = displayLink(target: self, selector: #selector(step))
        l.add(to: .main, forMode: .common)
        link = l
    }

    @objc private func step(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = last == 0 ? 1.0 / 60 : min(0.1, now - last)
        last = now
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let keep = tick(dt: dt)
        CATransaction.commit()
        if !keep {
            link?.invalidate()
            link = nil
        }
    }

    func tick(dt: Double) -> Bool { false }
}

// MARK: - 回転する円盤 (レコード・CD・カセットのハブ)

/// `speed` (回転/秒、負で反時計回り) に慣性つきで追従して回る画像
struct Spinner: NSViewRepresentable {
    let image: CGImage?
    var speed: Double
    var inertia: Double = 2.2

    func makeNSView(context: Context) -> SpinnerView { SpinnerView() }

    func updateNSView(_ view: SpinnerView, context: Context) {
        view.setImage(image)
        view.inertia = inertia
        view.target = speed
    }
}

final class SpinnerView: DisplayLinkView {
    private let disc = CALayer()
    /// 回転角 (時計回りが正、ラジアン) と回転速度 (回転/秒)
    private var angle: Double = 0
    private var velocity: Double = 0
    /// 一定の速さで回っている間は Core Animation の繰り返しアニメーションに任せ、毎フレームの計算をしない
    private var cruise: (start: CFTimeInterval, angle: Double, speed: Double)?
    var inertia: Double = 2.2
    var target: Double = 0 {
        didSet {
            guard target != oldValue else { return }
            leaveCruise()
            wake()
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        disc.contentsGravity = .resizeAspect
        layer?.addSublayer(disc)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: CGImage?) {
        guard (disc.contents as AnyObject?) !== image else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.contents = image
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.bounds = bounds
        disc.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override var needsFrames: Bool { cruise == nil && (target != 0 || velocity != 0) }

    override func tick(dt: Double) -> Bool {
        velocity += (target - velocity) * min(1, dt * inertia)
        if abs(target - velocity) < 0.002 { velocity = target }
        angle += velocity * dt * 2 * .pi
        angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
        // レイヤー座標は y が上向きなので、時計回りは負の角度
        disc.transform = CATransform3DMakeRotation(CGFloat(-angle), 0, 0, 1)
        if velocity == target, target != 0 {
            enterCruise()
            return false
        }
        return needsFrames
    }

    private func enterCruise() {
        let now = CACurrentMediaTime()
        cruise = (now, angle, velocity)
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = -angle
        a.byValue = -2 * Double.pi * (velocity > 0 ? 1 : -1)
        a.duration = 1 / abs(velocity)
        a.repeatCount = .infinity
        a.beginTime = disc.convertTime(now, from: nil)
        a.isRemovedOnCompletion = false
        disc.add(a, forKey: "cruise")
    }

    /// 速さが変わるときは、アニメーションで進んだ分の角度を引き継いで毎フレームの計算に戻す
    private func leaveCruise() {
        guard let c = cruise else { return }
        cruise = nil
        let turns = c.speed * (CACurrentMediaTime() - c.start)
        angle = (c.angle + turns.truncatingRemainder(dividingBy: 1) * 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disc.removeAnimation(forKey: "cruise")
        disc.transform = CATransform3DMakeRotation(CGFloat(-angle), 0, 0, 1)
        CATransaction.commit()
    }
}

// MARK: - VU メーターの針

struct VUNeedle: NSViewRepresentable {
    let analyzer: SpectrumAnalyzer
    let channel: Int
    let playing: Bool
    let color: NSColor

    func makeNSView(context: Context) -> VUNeedleView { VUNeedleView(analyzer: analyzer, channel: channel) }

    func updateNSView(_ view: VUNeedleView, context: Context) {
        view.color = color
        view.playing = playing
    }
}

final class VUNeedleView: DisplayLinkView {
    /// 針の振れ幅 (度)。メーター面の目盛りと共有する
    static let sweep: Double = 44
    /// 0VU = -10dBFS (最近の音圧の高い曲でも 0 付近で振れるように)、右端 = +3VU
    static let fullScale: Float = pow(10, -10 / 20) * pow(10, 3 / 20)
    static let rest: Double = -0.035

    private let analyzer: SpectrumAnalyzer
    private let channel: Int
    private let needle = CAShapeLayer()
    private let led = CALayer()
    private var position: Double = rest
    private var velocity: Double = 0
    private var ledLevel: Float = 0

    var playing = false { didSet { if playing != oldValue { wake() } } }
    var color: NSColor = .systemRed {
        didSet { needle.strokeColor = color.cgColor }
    }

    init(analyzer: SpectrumAnalyzer, channel: Int) {
        self.analyzer = analyzer
        self.channel = channel
        super.init(frame: .zero)
        needle.lineWidth = 2.2
        needle.lineCap = .round
        needle.shadowColor = NSColor.black.cgColor
        needle.shadowOpacity = 0.6
        needle.shadowRadius = 2
        needle.shadowOffset = CGSize(width: 1, height: -2)
        led.backgroundColor = NSColor.systemRed.cgColor
        led.opacity = 0
        led.shadowColor = NSColor.systemRed.cgColor
        led.shadowOpacity = 1
        led.shadowRadius = 6
        led.shadowOffset = .zero
        layer?.masksToBounds = true
        layer?.addSublayer(needle)
        layer?.addSublayer(led)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let h = bounds.height
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: h * 1.08))
        needle.path = path
        needle.position = CGPoint(x: bounds.midX, y: -h * 0.2)
        let s = max(5, h * 0.05)
        led.frame = CGRect(x: bounds.maxX - s * 2.6, y: bounds.maxY - s * 2.6, width: s, height: s)
        led.cornerRadius = s / 2
        apply()
        CATransaction.commit()
    }

    override var needsFrames: Bool { playing || abs(position - Self.rest) > 0.001 || abs(velocity) > 0.001 || ledLevel > 0 }

    override func tick(dt: Double) -> Bool {
        var target = Self.rest
        if playing, let f = analyzer.frame(at: CACurrentMediaTime()) {
            let rms = channel == 0 ? f.left : f.right
            target = Double(min(1.05, rms / Self.fullScale))
            if target >= 0.98 { ledLevel = 1 }
        }
        // VU メーター相当のバリスティクス (約 300ms で追従、わずかにオーバーシュート)
        let k = 70.0, c = 12.5
        velocity += (k * (target - position) - c * velocity) * dt
        position += velocity * dt
        if position < Self.rest - 0.01 { position = Self.rest - 0.01; velocity = max(0, velocity) }
        ledLevel = max(0, ledLevel - Float(dt) * 2.5)
        apply()
        return needsFrames
    }

    private func apply() {
        let deg = Self.sweep * (1 - 2 * position)
        needle.transform = CATransform3DMakeRotation(CGFloat(deg * .pi / 180), 0, 0, 1)
        led.opacity = ledLevel
    }
}

// MARK: - スキン画像 (Blender でレンダリングした素材) の読み込みと合成

@MainActor
final class SkinAssets {
    static let shared = SkinAssets()
    private var cache: [String: CGImage] = [:]
    private var layouts: [String: Data] = [:]

    private func url(_ skin: String, _ file: String) -> URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("Skins/\(skin)/\(file)")
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    func available(_ skin: PlayerSkin) -> Bool { url(skin.assetFolder, "layout.json") != nil }

    /// `additive`: 黒地に光だけを描いた反射画像を、明るさ = 不透明度の画像に変換して返す。
    /// 回転する盤 (Core Animation のレイヤー) の上では SwiftUI の加算合成が効かないため、通常の合成で同じ見え方にする。
    func image(_ skin: PlayerSkin, _ name: String, additive: Bool = false) -> CGImage? {
        image(folder: skin.assetFolder, name, additive: additive)
    }

    func image(folder: String, _ name: String, additive: Bool = false) -> CGImage? {
        let key = "\(folder)/\(name)\(additive ? "+" : "")"
        if let img = cache[key] { return img }
        guard let u = url(folder, name + ".png"),
              let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              var img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if additive, let converted = Self.luminanceToAlpha(img) { img = converted }
        cache[key] = img
        return img
    }

    private static func luminanceToAlpha(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            // 乗算済みの RGB はそのまま、アルファを RGB の最大値にする (= 黒は透明、光は不透明)
            px[i + 3] = max(px[i], px[i + 1], px[i + 2])
        }
        return ctx.makeImage()
    }

    func layout<T: Decodable>(_ skin: PlayerSkin, as type: T.Type) -> T? {
        layout(folder: skin.assetFolder, as: type)
    }

    func layout<T: Decodable>(folder key: String, as type: T.Type) -> T? {
        if layouts[key] == nil, let u = url(key, "layout.json") { layouts[key] = try? Data(contentsOf: u) }
        return layouts[key].flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}

enum SkinArt {
    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func drawCover(_ art: CGImage, in ctx: CGContext, rect: CGRect) {
        let aw = CGFloat(art.width), ah = CGFloat(art.height)
        let scale = max(rect.width / aw, rect.height / ah)
        ctx.interpolationQuality = .high
        ctx.draw(art, in: CGRect(x: rect.midX - aw * scale / 2, y: rect.midY - ah * scale / 2, width: aw * scale, height: ah * scale))
    }

    /// 紙に印刷したような、ごく弱い周辺の落ち込み
    private static func printVignette(_ ctx: CGContext, center c: CGPoint, radius r: CGFloat, strength: CGFloat) {
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: strength)] as CFArray, locations: [0.55, 1])!
        ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: r, options: [])
    }

    /// レンダリングしたレコード盤に、アルバムアートのラベルを貼る
    static func labelledRecord(disc: CGImage, art: CGImage?, labelRadius r: CGFloat, accent: NSColor) -> CGImage? {
        guard let ctx = context(disc.width, disc.height) else { return nil }
        let full = CGRect(x: 0, y: 0, width: disc.width, height: disc.height)
        ctx.draw(disc, in: full)
        let c = CGPoint(x: full.midX, y: full.midY)
        let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        ctx.saveGState()
        ctx.addEllipse(in: rect)
        ctx.clip()
        if let art { drawCover(art, in: ctx, rect: rect) } else {
            ctx.setFillColor(accent.cgColor)
            ctx.fill(rect)
        }
        printVignette(ctx, center: c, radius: r, strength: 0.16)
        ctx.restoreGState()
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35))
        ctx.setLineWidth(max(1, r * 0.012))
        ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        return ctx.makeImage()
    }

    /// レーベル面にアルバムアートを印刷した CD (中央の透明部分は空けておく)
    static func printedDisc(art: CGImage?, radius r: CGFloat, holeRadius hr: CGFloat, accent: NSColor) -> CGImage? {
        let size = Int(ceil(r * 2))
        guard let ctx = context(size, size) else { return nil }
        let c = CGPoint(x: CGFloat(size) / 2, y: CGFloat(size) / 2)
        let outer = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        let ring = CGMutablePath()
        ring.addEllipse(in: outer.insetBy(dx: r * 0.012, dy: r * 0.012))
        ring.addEllipse(in: CGRect(x: c.x - hr, y: c.y - hr, width: 2 * hr, height: 2 * hr))
        // 外周の透明な縁
        ctx.setFillColor(CGColor(gray: 0.78, alpha: 0.55))
        ctx.fillEllipse(in: outer)
        ctx.saveGState()
        ctx.addPath(ring)
        ctx.clip(using: .evenOdd)
        if let art { drawCover(art, in: ctx, rect: outer) } else {
            ctx.setFillColor(accent.cgColor)
            ctx.fill(outer)
        }
        printVignette(ctx, center: c, radius: r, strength: 0.12)
        // 回転しているのがわかる程度の小さな印刷文字
        let text = NSAttributedString(string: "KANADE DIGITAL AUDIO", attributes: [
            .font: NSFont.systemFont(ofSize: r * 0.045, weight: .bold),
            .foregroundColor: NSColor(white: 1, alpha: 0.7),
            .kern: r * 0.01,
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let ts = text.size()
        text.draw(at: CGPoint(x: c.x - ts.width / 2, y: c.y - r * 0.84))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
        return ctx.makeImage()
    }
}

extension NSImage {
    var cgImageValue: CGImage? { cgImage(forProposedRect: nil, context: nil, hints: nil) }
}
