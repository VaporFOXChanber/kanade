import SwiftUI

/// 波形つきシークバー
struct SeekBar: View {
    @Environment(PlayerModel.self) private var model
    @State private var hoverX: CGFloat?
    @State private var dragFraction: Double?

    var body: some View {
        let clock = model.clock
        let duration = max(clock.duration, 0.001)
        let fraction = dragFraction ?? min(1, max(0, clock.position / duration))
        let shown = dragFraction.map { $0 * duration } ?? clock.position

        VStack(spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                Canvas { ctx, size in
                    draw(ctx, size: size, fraction: fraction, duration: duration)
                }
                .overlay(alignment: .topLeading) {
                    if let x = hoverX, dragFraction == nil, model.currentTrack != nil {
                        Text(formatTime(Double(x / w) * duration))
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.55), in: Capsule())
                            .fixedSize()
                            .offset(x: min(max(0, x - 22), w - 44), y: -24)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in dragFraction = Double(min(max(g.location.x / w, 0), 1)) }
                    .onEnded { g in
                        let f = Double(min(max(g.location.x / w, 0), 1))
                        model.seek(to: f * duration)
                        dragFraction = nil
                    })
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hoverX = p.x } else { hoverX = nil }
                }
            }
            .frame(height: 34)

            HStack {
                Text(formatTime(shown))
                Spacer()
                if model.isPreparing {
                    Text(model.conversionProgress.map { "変換中 \(Int($0 * 100))%" } ?? "準備中…")
                        .foregroundStyle(model.palette.accent)
                }
                Spacer()
                Text("-" + formatTime(max(0, duration - shown)))
            }
            .font(.system(size: 11, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, fraction: Double, duration: Double) {
        let w = size.width, h = size.height
        let playedX = w * fraction
        let gradient = Gradient(colors: [model.palette.accent, model.palette.secondary])
        let shading = GraphicsContext.Shading.linearGradient(gradient, startPoint: .zero, endPoint: CGPoint(x: w, y: 0))

        // A-B 区間
        if let a = model.loopA {
            let xa = w * a / duration
            let xb = model.loopB.map { w * $0 / duration } ?? xa + 1.5
            ctx.fill(Path(roundedRect: CGRect(x: xa, y: 0, width: max(1.5, xb - xa), height: h), cornerRadius: 2),
                     with: .color(model.palette.accent.opacity(0.16)))
        }

        // しおり
        for bm in model.currentBookmarks {
            let x = w * bm.time / duration
            ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)), with: .color(.white.opacity(0.35)))
            var tri = Path()
            tri.move(to: CGPoint(x: x - 3.5, y: 0))
            tri.addLine(to: CGPoint(x: x + 3.5, y: 0))
            tri.addLine(to: CGPoint(x: x, y: 5))
            tri.closeSubpath()
            ctx.fill(tri, with: .color(model.palette.accent))
        }

        // おやすみ前の位置 (前回スリープタイマーをセットしたところ)
        if let time = model.sleepPointInCurrentTrack {
            let x = w * time / duration
            let moon = Color(red: 1, green: 0.86, blue: 0.55)
            ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)), with: .color(moon.opacity(0.4)))
            ctx.fill(Path(ellipseIn: CGRect(x: x - 3, y: -1, width: 6, height: 6)), with: .color(moon))
        }

        guard let peaks = model.waveform, !peaks.isEmpty else {
            let track = CGRect(x: 0, y: h / 2 - 2, width: w, height: 4)
            ctx.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(.white.opacity(0.18)))
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: h / 2 - 2, width: max(4, playedX), height: 4), cornerRadius: 2), with: shading)
            return
        }

        let step: CGFloat = 3
        let barW: CGFloat = 1.8
        let count = max(1, Int(w / step))
        var played = Path(), rest = Path()
        for i in 0..<count {
            let a = i * peaks.count / count
            let b = max(a + 1, (i + 1) * peaks.count / count)
            let v = CGFloat(peaks[a..<min(b, peaks.count)].max() ?? 0)
            let bh = max(2, pow(v, 0.8) * h)
            let x = CGFloat(i) * step
            let r = CGRect(x: x, y: (h - bh) / 2, width: barW, height: bh)
            if x + barW / 2 <= playedX { played.addRoundedRect(in: r, cornerSize: CGSize(width: 0.9, height: 0.9)) }
            else { rest.addRoundedRect(in: r, cornerSize: CGSize(width: 0.9, height: 0.9)) }
        }
        ctx.fill(rest, with: .color(.white.opacity(hoverX == nil ? 0.2 : 0.28)))
        ctx.fill(played, with: shading)

        if let x = hoverX {
            ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1, height: h)), with: .color(.white.opacity(0.6)))
        }
    }
}
