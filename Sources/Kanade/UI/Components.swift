import AppKit
import SwiftUI

// MARK: - アートワーク

struct ArtworkView: View {
    let image: NSImage?
    var palette: Palette = .default
    var cornerRadius: CGFloat = 16

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFill()
                        .transition(.opacity)
                        .id(ObjectIdentifier(image))
                } else {
                    ZStack {
                        LinearGradient(colors: [palette.accent.opacity(0.55), palette.secondary.opacity(0.35), .black.opacity(0.4)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        GeometryReader { g in
                            Image(systemName: "music.note")
                                .font(.system(size: g.size.width * 0.3, weight: .ultraLight))
                                .foregroundStyle(.white.opacity(0.8))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }
}

struct ThumbnailView: View {
    let track: Track
    var size: CGFloat = 38
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().interpolation(.medium).scaledToFill()
            } else {
                Rectangle().fill(.white.opacity(0.08))
                Image(systemName: "music.note").font(.system(size: size * 0.38)).foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .task(id: "\(track.artworkKey)#\(ArtworkStore.shared.revision)") {
            image = ArtworkStore.shared.cachedThumbnail(for: track)
            if image == nil { image = await ArtworkStore.shared.thumbnail(for: track) }
        }
    }
}

// MARK: - アートワークの影

/// 事前に描いておく影の画像。SwiftUI の .shadow は再描画のたびにぼかしを計算し直すため、
/// 再生位置が更新されるだけで大きな負荷になる。配色ごとに一度だけ描いて使い回す。
@MainActor
enum ShadowCache {
    private static var cache: [String: CGImage] = [:]
    static let inner: CGFloat = 400
    static let canvas = 640

    static func image(accent: Color, glow: Double) -> CGImage? {
        let ns = NSColor(accent).usingColorSpace(.sRGB) ?? .black
        let key = String(format: "%.3f-%.3f-%.3f-%.2f", ns.redComponent, ns.greenComponent, ns.blueComponent, glow)
        if let hit = cache[key] { return hit }
        guard let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let o = (CGFloat(canvas) - inner) / 2
        let path = CGPath(roundedRect: CGRect(x: o, y: o, width: inner, height: inner), cornerWidth: 18, cornerHeight: 18, transform: nil)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        if glow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 80, color: ns.withAlphaComponent(glow).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: CGColor(gray: 0, alpha: 0.45))
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
        // アートワークに隠れる部分は抜く
        ctx.setBlendMode(.clear)
        ctx.addPath(path)
        ctx.fillPath()
        let img = ctx.makeImage()
        if cache.count > 32 { cache.removeAll() }
        cache[key] = img
        return img
    }
}

extension View {
    /// アートワーク用の影 (事前描画の画像を敷く)
    func artworkShadow(_ accent: Color, glow: Double = 0.32) -> some View {
        background {
            GeometryReader { g in
                if let img = ShadowCache.image(accent: accent, glow: glow) {
                    let k = CGFloat(ShadowCache.canvas) / ShadowCache.inner
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .frame(width: g.size.width * k, height: g.size.height * k)
                        .position(x: g.size.width / 2, y: g.size.height / 2)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - ボタン

struct IconButton: View {
    let symbol: String
    var size: CGFloat = 15
    var active = false
    var tint: Color = .white
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .frame(width: size * 2 + 4, height: size * 2 + 4)
                .foregroundStyle(active ? AnyShapeStyle(tint) : AnyShapeStyle(.white.opacity(hover ? 0.95 : 0.66)))
                .background(Circle().fill(.white.opacity(hover ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - スライダー

struct CapsuleSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var tint: Color
    @State private var hover = false
    @State private var dragging = false

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let frac = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let h: CGFloat = hover || dragging ? 6 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height: h)
                Capsule().fill(tint).frame(width: max(h, w * frac), height: h)
                Circle().fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .offset(x: w * frac - 6)
                    .opacity(hover || dragging ? 1 : 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    dragging = true
                    let f = min(max(g.location.x / w, 0), 1)
                    value = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                }
                .onEnded { _ in dragging = false })
            .onHover { hover = $0 }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// イコライザー用の縦スライダー (ダブルクリックで 0dB)
struct EQSlider: View {
    @Binding var value: Float
    var range: ClosedRange<Float> = -12...12
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let span = range.upperBound - range.lowerBound
            let frac = CGFloat((value - range.lowerBound) / span)
            let y = (h - 14) * (1 - frac) + 7
            let zero = (h - 14) * CGFloat(range.upperBound / span) + 7
            ZStack(alignment: .top) {
                Capsule().fill(.white.opacity(0.12)).frame(width: 4, height: h)
                Rectangle().fill(.white.opacity(0.35)).frame(width: 12, height: 1).offset(y: zero)
                Capsule().fill(tint).frame(width: 4, height: max(1, abs(y - zero))).offset(y: min(y, zero))
                Circle().fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(y: y - 7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let f = 1 - min(max((g.location.y - 7) / (h - 14), 0), 1)
                value = ((range.lowerBound + Float(f) * span) * 2).rounded() / 2
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 0 })
        }
    }
}

// MARK: - 小物

struct Badge: View {
    let text: String
    var highlight: Color?

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(highlight ?? .white.opacity(0.75))
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background((highlight ?? .white).opacity(highlight == nil ? 0.1 : 0.16), in: Capsule())
            .overlay(Capsule().strokeBorder((highlight ?? .clear).opacity(0.35), lineWidth: 0.5))
    }
}

/// 再生中を示す 3 本のバー。アニメーションは Core Animation に任せる (メインスレッドを使わない)
struct PlayingIndicator: NSViewRepresentable {
    var playing: Bool
    var color: Color

    func makeNSView(context: Context) -> BarsIndicatorView { BarsIndicatorView() }
    func updateNSView(_ view: BarsIndicatorView, context: Context) { view.update(playing: playing, color: NSColor(color)) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: BarsIndicatorView, context: Context) -> CGSize? {
        CGSize(width: 13, height: 12)
    }
}

final class BarsIndicatorView: NSView {
    private let bars = (0..<3).map { _ in CALayer() }
    private var playing: Bool?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for b in bars {
            b.anchorPoint = CGPoint(x: 0.5, y: 0)
            b.cornerRadius = 1.5
            layer?.addSublayer(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, b) in bars.enumerated() {
            b.bounds = CGRect(x: 0, y: 0, width: 3, height: bounds.height)
            b.position = CGPoint(x: 1.5 + CGFloat(i) * 5, y: 0)
        }
        CATransaction.commit()
    }

    func update(playing: Bool, color: NSColor) {
        bars.forEach { $0.backgroundColor = color.cgColor }
        guard playing != self.playing else { return }
        self.playing = playing
        for (i, b) in bars.enumerated() {
            b.removeAllAnimations()
            if playing {
                let a = CABasicAnimation(keyPath: "transform.scale.y")
                a.fromValue = 0.25
                a.toValue = 1.0
                a.duration = 0.38 + Double(i) * 0.11
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.timeOffset = Double(i) * 0.17
                b.add(a, forKey: "bounce")
            } else {
                b.transform = CATransform3DMakeScale(1, 0.25, 1)
            }
        }
    }
}

extension View {
    /// 数値の変化に合わせてラベルを滑らかに切り替える
    func numericTransition() -> some View { contentTransition(.numericText()) }
}

/// 曲名がアルバム名で始まる場合は、アルバム名を省いて「曲番号 曲名」にする (番号は薄く表示)
func shortTitleText(_ track: Track) -> Text {
    guard let short = track.titleWithoutAlbum else { return Text(track.displayTitle) }
    guard let n = short.number else { return Text(short.title) }
    let number = Text(String(format: "%02d", n)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
    return Text("\(number)  \(short.title)")
}

func rateLabel(_ r: Double) -> String {
    abs(r * 10 - (r * 10).rounded()) < 0.001 ? String(format: "%.1f×", r) : String(format: "%.2f×", r)
}
