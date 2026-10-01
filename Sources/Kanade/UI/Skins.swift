import AppKit
import SwiftUI

/// 再生画面の「プレイヤー」部分。Blender でレンダリングした素材 (Resources/Skins) を重ね、
/// 回転・針・文字などの動く部分だけをアプリ側で描く。
struct PlayerSkinView: View {
    let skin: PlayerSkin

    var body: some View {
        switch skin {
        case .standard: EmptyView()
        case .turntable: TurntableSkin()
        case .cassette: CassetteSkin()
        case .cd: DiscmanSkin()
        case .amp: AmpSkin()
        }
    }
}

// MARK: - 共通

private extension PlayerModel {
    var progress: Double {
        guard clock.duration > 0 else { return 0 }
        return min(1, max(0, clock.position / clock.duration))
    }
    var artworkCG: CGImage? { artwork?.cgImageValue }
    var artworkKey: Int { artwork.map { ObjectIdentifier($0).hashValue } ?? 0 }
}

private struct Pt: Decodable {
    let x: Double, y: Double
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
    }
    var cg: CGPoint { CGPoint(x: x, y: y) }
}

private struct Rect: Decodable {
    let x: Double, y: Double, w: Double, h: Double
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        w = try c.decode(Double.self)
        h = try c.decode(Double.self)
    }
    var cg: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// キャンバス座標 (ピクセル) → 表示座標への変換
private struct Canvas {
    let size: CGSize
    let scale: CGFloat
    var full: CGRect { CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale) }
    func p(_ pt: CGPoint) -> CGPoint { CGPoint(x: pt.x * scale, y: pt.y * scale) }
    func r(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale) }
    func v(_ value: Double) -> CGFloat { CGFloat(value) * scale }
    func box(center: Pt, size: [Double]) -> CGRect {
        CGRect(x: v(center.x - size[0] / 2), y: v(center.y - size[1] / 2), width: v(size[0]), height: v(size[1]))
    }
}

/// キャンバスの縦横比を保って表示し、座標変換を子に渡す
private struct SkinFrame<Content: View>: View {
    let canvas: CGSize
    @ViewBuilder let content: (Canvas) -> Content

    var body: some View {
        GeometryReader { g in
            let s = g.size.width / canvas.width
            ZStack(alignment: .topLeading) {
                content(Canvas(size: canvas, scale: s))
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .aspectRatio(canvas.width / canvas.height, contentMode: .fit)
    }
}

private struct Layer: View {
    let image: CGImage?
    /// 機器の本体に付ける接地影
    var castsShadow = false
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().interpolation(.high)
                .shadow(color: .black.opacity(castsShadow ? 0.28 : 0), radius: castsShadow ? 14 : 0, x: 0, y: castsShadow ? 10 : 0)
                .shadow(color: .black.opacity(castsShadow ? 0.18 : 0), radius: castsShadow ? 3 : 0, x: 0, y: castsShadow ? 2 : 0)
                .allowsHitTesting(false)
        }
    }
}

private extension View {
    func place(_ rect: CGRect) -> some View {
        frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
    }
    func place(center: CGPoint, size: CGFloat) -> some View {
        frame(width: size, height: size).position(center)
    }
}

/// 点灯した LED の柔らかい光
private struct LEDGlow: View {
    let color: Color
    let size: CGFloat
    let on: Bool
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [color, color.opacity(0.55), color.opacity(0)], center: .center, startRadius: 0, endRadius: size))
            .frame(width: size * 2, height: size * 2)
            .opacity(on ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: on)
            .allowsHitTesting(false)
    }
}

private struct HitArea: View {
    let rect: CGRect
    var circle = false
    let action: () -> Void
    var body: some View {
        Group {
            if circle { Circle().fill(.white.opacity(0.001)) } else { Rectangle().fill(.white.opacity(0.001)) }
        }
        .place(rect)
        .onTapGesture(perform: action)
    }
}

// MARK: - レコードプレイヤー

private struct TurntableLayout: Decodable {
    struct Disc: Decodable { let center: Pt; let size: Double; let labelRadius: Double; let rpm: Double }
    struct Arm: Decodable { let pivot: Pt; let renderedAngle, outerAngle, innerAngle, restAngle, length: Double }
    struct Box: Decodable { let center: Pt; let size: [Double] }
    let canvas: [Double]
    let disc: Disc
    let arm: Arm
    let buttons: [String: Box]

    func radius(atAngle deg: Double) -> Double {
        let a = deg * .pi / 180
        return hypot(arm.pivot.x + arm.length * cos(a) - disc.center.x, arm.pivot.y + arm.length * sin(a) - disc.center.y)
    }

    /// 針先が盤の中心からその半径に来るアーム角 (画面座標、度)
    func angle(forProgress p: Double) -> Double {
        let r0 = radius(atAngle: arm.outerAngle), r1 = radius(atAngle: arm.innerAngle)
        let r = r0 + (r1 - r0) * min(max(p, 0), 1)
        let P = arm.pivot, C = disc.center, L = arm.length
        let d = hypot(C.x - P.x, C.y - P.y)
        let beta = atan2(C.y - P.y, C.x - P.x) * 180 / .pi
        let phi = acos(min(1, max(-1, (L * L + d * d - r * r) / (2 * L * d)))) * 180 / .pi
        func near(_ x: Double) -> Double { arm.outerAngle + remainder(x - arm.outerAngle, 360) }
        let a = near(beta + phi), b = near(beta - phi)
        return abs(a - arm.outerAngle) < abs(b - arm.outerAngle) ? a : b
    }

    func progress(forAngle deg: Double) -> Double {
        let lo = min(arm.outerAngle, arm.innerAngle), hi = max(arm.outerAngle, arm.innerAngle)
        let d = min(max(arm.outerAngle + remainder(deg - arm.outerAngle, 360), lo), hi)
        let r0 = radius(atAngle: arm.outerAngle), r1 = radius(atAngle: arm.innerAngle)
        return min(1, max(0, (radius(atAngle: d) - r0) / (r1 - r0)))
    }
}

private struct TurntableSkin: View {
    @Environment(PlayerModel.self) private var model
    @State private var record: CGImage?
    @State private var dragProgress: Double?
    private let assets = SkinAssets.shared

    var body: some View {
        if let L = assets.layout(.turntable, as: TurntableLayout.self) {
            SkinFrame(canvas: CGSize(width: L.canvas[0], height: L.canvas[1])) { cv in
                deck(L, cv)
                controls(L, cv)
                arm(L, cv)
            }
            .task(id: model.artworkKey) { await renderRecord(L) }
        }
    }

    private func renderRecord(_ L: TurntableLayout) async {
        guard let disc = assets.image(.turntable, "disc") else { return }
        let art = model.artworkCG
        let accent = NSColor(model.palette.accent)
        let r = CGFloat(L.disc.labelRadius)
        record = await Task.detached(priority: .userInitiated) {
            SkinArt.labelledRecord(disc: disc, art: art, labelRadius: r, accent: accent)
        }.value
    }

    @ViewBuilder
    private func deck(_ L: TurntableLayout, _ cv: Canvas) -> some View {
        let center = cv.p(L.disc.center.cg)
        let size = cv.v(L.disc.size)
        let speed = model.isPlaying && !model.powerSaving ? L.disc.rpm / 60 * model.effectiveRate : 0
        Layer(image: assets.image(.turntable, "base"), castsShadow: true).place(cv.full)
        Spinner(image: record ?? assets.image(.turntable, "disc"), speed: speed, inertia: 1.6)
            .place(center: center, size: size)
        Layer(image: assets.image(.turntable, "sheen", additive: true))
            .place(center: center, size: size)
            .opacity(0.8)
        Layer(image: assets.image(.turntable, "spindle")).place(center: center, size: size)
        HitArea(rect: CGRect(x: center.x - size * 0.45, y: center.y - size * 0.45, width: size * 0.9, height: size * 0.9), circle: true) {
            model.togglePlay()
        }
        .help("クリックで再生 / 一時停止")
    }

    @ViewBuilder
    private func controls(_ L: TurntableLayout, _ cv: Canvas) -> some View {
        ForEach(["33", "45"], id: \.self) { key in
            let rate = key == "33" ? 1.0 : 1.35
            if let led = L.buttons["led\(key)"] {
                LEDGlow(color: Color(red: 1, green: 0.28, blue: 0.18), size: cv.v(led.size[0]) * 1.1, on: abs(model.effectiveRate - rate) < 0.01)
                    .position(cv.p(led.center.cg))
            }
            if let b = L.buttons[key] {
                HitArea(rect: cv.box(center: b.center, size: b.size)) {
                    if model.asmrMode {
                        model.showToast("ASMR モード中は速度を変えられません", symbol: "ear")
                    } else {
                        withAnimation { model.rate = rate }
                    }
                }
                .help(key == "33" ? "33⅓ 回転 (通常の速さ)" : "45 回転 (速く・高く)")
            }
        }
        if let b = L.buttons["start"] {
            HitArea(rect: cv.box(center: b.center, size: b.size)) { model.togglePlay() }
        }
    }

    @ViewBuilder
    private func arm(_ L: TurntableLayout, _ cv: Canvas) -> some View {
        let angle = L.angle(forProgress: dragProgress ?? model.progress)
        let rotation = Angle.degrees(angle - L.arm.renderedAngle)
        let anchor = UnitPoint(x: L.arm.pivot.x / cv.size.width, y: L.arm.pivot.y / cv.size.height)
        let lifted = !model.isPlaying
        let spring: Animation? = dragProgress == nil ? .spring(duration: 0.9) : nil
        Layer(image: assets.image(.turntable, "arm_shadow"))
            .place(cv.full)
            .offset(x: lifted ? cv.v(10) : 0, y: lifted ? cv.v(14) : 0)
            .opacity(lifted ? 0.7 : 1)
            .rotationEffect(rotation, anchor: anchor)
            .animation(spring, value: angle)
            .animation(.easeInOut(duration: 0.35), value: lifted)
        Layer(image: assets.image(.turntable, "arm"))
            .place(cv.full)
            .rotationEffect(rotation, anchor: anchor)
            .animation(spring, value: angle)
        needleHandle(L, cv, angle: angle)
    }

    /// 針先をつかんで好きな位置に落とす
    private func needleHandle(_ L: TurntableLayout, _ cv: Canvas, angle: Double) -> some View {
        let a = angle * .pi / 180
        let tip = CGPoint(x: L.arm.pivot.x + L.arm.length * cos(a), y: L.arm.pivot.y + L.arm.length * sin(a))
        return Circle().fill(.white.opacity(0.001))
            .frame(width: cv.v(130), height: cv.v(130))
            .position(cv.p(tip))
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let deg = atan2(v.location.y / cv.scale - L.arm.pivot.y, v.location.x / cv.scale - L.arm.pivot.x) * 180 / .pi
                    dragProgress = L.progress(forAngle: deg)
                }
                .onEnded { _ in
                    if let p = dragProgress { model.seek(to: p * model.clock.duration) }
                    dragProgress = nil
                })
            .help("針をつかんで好きな位置に落とす")
    }
}

// MARK: - カセット

private struct CassetteLayout: Decodable {
    let canvas: [Double]
    let hubs: [Pt]
    let hubSize: Double
    let packRadius: [Double]
    let label: Rect
    let window: Rect
    let cassette: Rect
}

private struct CassetteSkin: View {
    @Environment(PlayerModel.self) private var model
    @State private var wind: Double = 0
    @State private var lastTrack: UUID?
    private let assets = SkinAssets.shared

    var body: some View {
        if let L = assets.layout(.cassette, as: CassetteLayout.self) {
            SkinFrame(canvas: CGSize(width: L.canvas[0], height: L.canvas[1])) { cv in
                tape(L, cv)
                Layer(image: assets.image(.cassette, "front")).place(cv.full)
                LabelInk(label: cv.r(L.label.cg), window: cv.r(L.window.cg))
            }
            .contentShape(Rectangle())
            .onTapGesture { model.togglePlay() }
            .onChange(of: model.clock.position) { old, new in
                // 同じ曲の中で大きく飛んだら早送り / 巻き戻しの演出
                defer { lastTrack = model.currentID }
                guard lastTrack == model.currentID, abs(new - old) > 3 else { return }
                wind = new > old ? 1 : -1
                Task {
                    try? await Task.sleep(for: .seconds(0.8))
                    wind = 0
                }
            }
        }
    }

    @ViewBuilder
    private func tape(_ L: CassetteLayout, _ cv: Canvas) -> some View {
        Layer(image: assets.image(.cassette, "back"), castsShadow: true).place(cv.full)
        CassetteReels(L: L, cv: cv, wind: wind)
    }
}

/// テープの巻き (再生位置に合わせて左右の量が入れ替わる) と、回転するハブ
private struct CassetteReels: View {
    @Environment(PlayerModel.self) private var model
    let L: CassetteLayout
    let cv: Canvas
    /// 早送り (+1) / 巻き戻し (-1) の演出
    var wind: Double

    var body: some View {
        let rMin = L.packRadius[0], rMax = L.packRadius[1]
        let p = model.clock.coarseProgress
        // 巻きの量は 1 秒に 1pt も変わらないので、表示上 0.5pt 変わったときだけ描き直す
        // (再生位置の更新ごとにアニメーションさせると、画面全体を毎フレーム描き直すことになる)
        let radii = [1 - p, p].map { f in (cv.v(sqrt(rMin * rMin + (rMax * rMax - rMin * rMin) * f)) * 2).rounded() / 2 }
        let base = wind != 0 ? wind * 9 : (model.isPlaying && !model.powerSaving ? model.effectiveRate : 0)
        let hub = SkinAssets.shared.image(.cassette, "hub")
        ForEach(0..<2, id: \.self) { i in
            TapePack(radius: radii[i])
                .position(cv.p(L.hubs[i].cg))
        }
        ForEach(0..<2, id: \.self) { i in
            Spinner(image: hub, speed: base * 1.15 * cv.v(rMin) / radii[i], inertia: 4)
                .place(center: cv.p(L.hubs[i].cg), size: cv.v(L.hubSize))
        }
    }
}

private struct TapePack: View {
    let radius: CGFloat
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [Color(red: 0.3, green: 0.2, blue: 0.13), Color(red: 0.17, green: 0.11, blue: 0.07)],
                                         center: .center, startRadius: 0, endRadius: radius))
            // テープ端面のかすかな光沢 (回転しない)
            Circle().fill(AngularGradient(colors: [.white.opacity(0), .white.opacity(0.1), .white.opacity(0), .white.opacity(0.06), .white.opacity(0)],
                                          center: .center, angle: .degrees(-40)))
        }
        .frame(width: radius * 2, height: radius * 2)
        .allowsHitTesting(false)
    }
}

/// カセットのラベルに手書きした曲名 (窓より上の余白に収める)
private struct LabelInk: View {
    @Environment(PlayerModel.self) private var model
    let label: CGRect
    let window: CGRect

    var body: some View {
        let t = model.currentTrack
        let ink = Color(red: 0.13, green: 0.17, blue: 0.4)
        let top = label.minY, room = window.minY - label.minY   // 窓の上の余白
        let x0 = label.minX + label.width * 0.05, w = label.width * 0.9
        ZStack(alignment: .topLeading) {
            // 上端の色帯と種別
            VStack(spacing: 0) {
                Rectangle().fill(model.palette.accent.opacity(0.8))
                Rectangle().fill(model.palette.secondary.opacity(0.8))
            }
            .frame(width: label.width, height: room * 0.14)
            .position(x: label.midX, y: top + room * 0.13)
            Text("TYPE I  NORMAL  C-60")
                .font(.system(size: room * 0.075, weight: .heavy))
                .foregroundStyle(.white.opacity(0.9))
                .position(x: label.maxX - label.width * 0.12, y: top + room * 0.13)
            // 罫線
            ForEach([0.62, 0.9], id: \.self) { y in
                Rectangle().fill(Color(red: 0.55, green: 0.68, blue: 0.88).opacity(0.5))
                    .frame(width: w * 0.88, height: max(0.5, room * 0.008))
                    .position(x: x0 + w * 0.12 + w * 0.44, y: top + room * y)
            }
            Text("A")
                .font(.system(size: room * 0.3, weight: .black, design: .rounded))
                .foregroundStyle(model.palette.accent.opacity(0.85))
                .position(x: x0 + w * 0.04, y: top + room * 0.52)
            (t.map(shortTitleText) ?? Text(""))
                .font(.custom("Klee-Demibold", size: room * 0.3))
                .lineLimit(1)
                .frame(width: w * 0.86, alignment: .leading)
                .position(x: x0 + w * 0.12 + w * 0.43, y: top + room * 0.5)
            Text(t?.displayArtist ?? "")
                .font(.custom("Klee-Medium", size: room * 0.19))
                .lineLimit(1)
                .frame(width: w * 0.86, alignment: .leading)
                .position(x: x0 + w * 0.12 + w * 0.43, y: top + room * 0.8)
        }
        .foregroundStyle(ink.opacity(0.9))
        .allowsHitTesting(false)
    }
}

// MARK: - ポータブル CD プレイヤー

private struct CDLayout: Decodable {
    struct Disc: Decodable { let center: Pt; let radius: Double; let holeRadius: Double }
    struct Square: Decodable { let center: Pt; let size: Double }
    struct Button: Decodable { let center: Pt; let radius: Double }
    let canvas: [Double]
    let disc: Disc
    let hub: Square
    let sheen: Square
    let lcd: Rect
    let buttons: [Button]
}

private struct DiscmanSkin: View {
    @Environment(PlayerModel.self) private var model
    @State private var disc: CGImage?
    private let assets = SkinAssets.shared

    var body: some View {
        if let L = assets.layout(.cd, as: CDLayout.self) {
            SkinFrame(canvas: CGSize(width: L.canvas[0], height: L.canvas[1])) { cv in
                discLayers(L, cv)
                LCDReadout().place(cv.r(L.lcd.cg))
                buttons(L, cv)
            }
            .task(id: model.artworkKey) { await renderDisc(L) }
        }
    }

    private func renderDisc(_ L: CDLayout) async {
        let art = model.artworkCG
        let accent = NSColor(model.palette.accent)
        let r = CGFloat(L.disc.radius), hr = CGFloat(L.disc.holeRadius)
        disc = await Task.detached(priority: .userInitiated) { SkinArt.printedDisc(art: art, radius: r, holeRadius: hr, accent: accent) }.value
    }

    @ViewBuilder
    private func discLayers(_ L: CDLayout, _ cv: Canvas) -> some View {
        let center = cv.p(L.disc.center.cg)
        let hubSize = cv.v(L.hub.size)
        Layer(image: assets.image(.cd, "base"), castsShadow: true).place(cv.full)
        Spinner(image: disc, speed: model.isPlaying && !model.powerSaving ? 1.1 * model.effectiveRate : 0, inertia: 1.3)
            .place(center: center, size: cv.v(L.disc.radius * 2))
        Layer(image: assets.image(.cd, "disc_sheen", additive: true))
            .place(center: cv.p(L.sheen.center.cg), size: cv.v(L.sheen.size))
            .opacity(0.9)
        // ミラーバンドのかすかな虹色 (回転しない)
        Circle()
            .fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red], center: .center))
            .mask(Circle().strokeBorder(lineWidth: hubSize * 0.08))
            .frame(width: hubSize * 0.9, height: hubSize * 0.9)
            .position(cv.p(L.hub.center.cg))
            .opacity(0.1)
            .allowsHitTesting(false)
        Layer(image: assets.image(.cd, "hub")).place(center: cv.p(L.hub.center.cg), size: hubSize)
        Layer(image: assets.image(.cd, "lid")).place(cv.full)
        HitArea(rect: CGRect(x: center.x - cv.v(L.disc.radius), y: center.y - cv.v(L.disc.radius),
                             width: cv.v(L.disc.radius * 2), height: cv.v(L.disc.radius * 2)), circle: true) { model.togglePlay() }
            .help("クリックで再生 / 一時停止")
    }

    @ViewBuilder
    private func buttons(_ L: CDLayout, _ cv: Canvas) -> some View {
        ForEach(Array(L.buttons.enumerated()), id: \.offset) { i, b in
            let r = cv.v(b.radius)
            Image(systemName: i == 0 ? "backward.end.fill" : "forward.end.fill")
                .font(.system(size: r * 0.55, weight: .bold))
                .foregroundStyle(.black.opacity(0.4))
                .frame(width: r * 2, height: r * 2)
                .contentShape(Circle())
                .position(cv.p(b.center.cg))
                .onTapGesture { i == 0 ? model.previous() : model.next() }
        }
    }
}

/// 液晶: 消えているセグメントをうっすら残し、表示中の数字を乗算で重ねる
private struct LCDReadout: View {
    @Environment(PlayerModel.self) private var model
    @State private var blink = false

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let digits = Font.custom("DINAlternate-Bold", size: h * 0.62)
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("TRACK").font(.system(size: h * 0.16, weight: .bold))
                    ZStack(alignment: .leading) {
                        Text("88").font(digits).opacity(0.07)
                        Text(String(format: "%02d", trackNumber % 100)).font(digits)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    HStack(spacing: h * 0.12) {
                        Text("ESP").opacity(model.isPreparing ? (blink ? 1 : 0.1) : 0.1)
                        Text("BASS").opacity(model.eqEnabled && model.eqBands.prefix(3).contains { $0 > 0 } ? 0.9 : 0.1)
                        Image(systemName: model.isPlaying ? "play.fill" : "pause.fill")
                    }
                    .font(.system(size: h * 0.15, weight: .bold))
                    let time = formatTime(model.clock.position)
                    ZStack(alignment: .trailing) {
                        Text(String(time.map { $0.isNumber ? "8" : $0 })).font(digits).monospacedDigit().opacity(0.07)
                        Text(time).font(digits).monospacedDigit()
                    }
                }
            }
            .foregroundStyle(Color(red: 0.08, green: 0.11, blue: 0.06).opacity(0.85))
            .padding(.horizontal, h * 0.2)
            .padding(.vertical, h * 0.06)
            .frame(width: g.size.width, height: h)
        }
        .allowsHitTesting(false)
        .task(id: model.isPreparing) {
            while model.isPreparing {
                blink.toggle()
                try? await Task.sleep(for: .seconds(0.4))
            }
            blink = false
        }
    }

    private var trackNumber: Int {
        model.currentTrack?.titleWithoutAlbum?.number ?? model.currentTrack?.meta.trackNumber
            ?? (model.currentID.flatMap { id in model.queue.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0)
    }
}

// MARK: - アンプ (アナログ VU メーター)

private struct AmpLayout: Decodable {
    struct Circ: Decodable { let center: Pt; let radius: Double }
    let canvas: [Double]
    let meters: [Rect]
    let knob: Circ
    let led: Circ
}

private struct AmpSkin: View {
    @Environment(PlayerModel.self) private var model
    @State private var dragStart: Double?
    private let assets = SkinAssets.shared

    var body: some View {
        if let L = assets.layout(.amp, as: AmpLayout.self) {
            SkinFrame(canvas: CGSize(width: L.canvas[0], height: L.canvas[1])) { cv in
                Layer(image: assets.image(.amp, "base"), castsShadow: true).place(cv.full)
                ForEach(Array(L.meters.enumerated()), id: \.offset) { i, m in
                    VUNeedle(analyzer: model.engine.spectrum, channel: i, playing: model.isPlaying && !model.powerSaving,
                             color: NSColor(red: 0.1, green: 0.08, blue: 0.07, alpha: 1))
                        .place(cv.r(m.cg))
                        .allowsHitTesting(false)
                }
                Layer(image: assets.image(.amp, "glass")).place(cv.full)
                power(L, cv)
                knob(L, cv)
            }
        }
    }

    @ViewBuilder
    private func power(_ L: AmpLayout, _ cv: Canvas) -> some View {
        let c = cv.p(L.led.center.cg), r = cv.v(L.led.radius)
        LEDGlow(color: Color(red: 1, green: 0.3, blue: 0.2), size: r * 1.6, on: model.isPlaying).position(c)
        HitArea(rect: CGRect(x: c.x - r * 2.5, y: c.y - r * 2.5, width: r * 5, height: r * 5), circle: true) { model.togglePlay() }
            .help("POWER: 再生 / 一時停止")
    }

    private func knob(_ L: AmpLayout, _ cv: Canvas) -> some View {
        let r = cv.v(L.knob.radius)
        return Capsule()
            .fill(.black.opacity(0.55))
            .frame(width: r * 0.09, height: r * 0.34)
            .offset(y: -r * 0.6)
            .rotationEffect(.degrees(-135 + 270 * model.volume))
            .frame(width: r * 2, height: r * 2)
            .contentShape(Circle())
            .position(cv.p(L.knob.center.cg))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if dragStart == nil { dragStart = model.volume }
                    model.volume = min(1, max(0, (dragStart ?? 0) - v.translation.height / 160 + v.translation.width / 320))
                }
                .onEnded { _ in dragStart = nil })
            .help("上下にドラッグで音量")
    }
}

// MARK: - ミニプレイヤー: ポータブルカセットプレイヤー

private struct WalkmanLayout: Decodable {
    struct Key: Decodable { let action: String; let rect: Rect; let clipY: Double; let press: Double }
    struct Wheel: Decodable { let center: Pt; let size: Double; let clipY: Double }
    struct Circ: Decodable { let center: Pt; let radius: Double }
    let canvas: [Double]
    /// 見下ろす角度による縦方向の縮み (cos)
    let tilt: Double
    /// カセットの素材 (Skins/cassette) の 1px がこのキャンバスで何 px になるか
    let cassetteScale: Double
    /// カセットの中心が写る位置 (ハブの高さ / ラベル面の高さ)
    let reels: Pt
    let label: Pt
    let keys: [Key]
    let wheel: Wheel
    let led: Circ
}

/// カセットの見た目のときのミニプレイヤー。少し上から見下ろしたポータブルカセットプレイヤーで、
/// 上面のキーで操作する (再生キーは再生中ずっと押し込まれたまま)。
struct WalkmanPlayer: View {
    static let width: CGFloat = 340
    static var height: CGFloat {
        guard let L = SkinAssets.shared.layout(folder: "walkman", as: WalkmanLayout.self) else { return 268 }
        return (width * L.canvas[1] / L.canvas[0]).rounded()
    }

    @Environment(PlayerModel.self) private var model
    @State private var pressed: String?
    @State private var wind: Double = 0
    @State private var windTask: Task<Void, Never>?
    @State private var volumeStart: Double?
    private let assets = SkinAssets.shared

    var body: some View {
        if let L = assets.layout(folder: "walkman", as: WalkmanLayout.self),
           let C = assets.layout(.cassette, as: CassetteLayout.self) {
            SkinFrame(canvas: CGSize(width: L.canvas[0], height: L.canvas[1])) { cv in
                Layer(image: image("body")).place(cv.full)
                cassette(L, C, cv)
                Layer(image: image("lid")).place(cv.full)
                ForEach(L.keys, id: \.action) { key in keyView(L, key, cv) }
                wheel(L, cv)
                LEDGlow(color: Color(red: 1, green: 0.26, blue: 0.16), size: cv.v(L.led.radius) * 1.8, on: model.isPlaying)
                    .position(cv.p(L.led.center.cg))
            }
        }
    }

    private func image(_ name: String) -> CGImage? { assets.image(folder: "walkman", name) }

    /// 中のカセット: 真上から描いた部品を、見下ろす角度に合わせて縦に縮めて重ねる
    @ViewBuilder
    private func cassette(_ L: WalkmanLayout, _ C: CassetteLayout, _ cv: Canvas) -> some View {
        let cc = Canvas(size: CGSize(width: C.canvas[0], height: C.canvas[1]), scale: cv.scale * L.cassetteScale)
        ZStack(alignment: .topLeading) { CassetteReels(L: C, cv: cc, wind: wind) }
            .frame(width: cc.full.width, height: cc.full.height, alignment: .topLeading)
            .scaleEffect(x: 1, y: L.tilt)
            .position(cv.p(L.reels.cg))
        Layer(image: image("cassette")).place(cv.full)
        ZStack(alignment: .topLeading) { LabelInk(label: cc.r(C.label.cg), window: cc.r(C.window.cg)) }
            .frame(width: cc.full.width, height: cc.full.height, alignment: .topLeading)
            .scaleEffect(x: 1, y: L.tilt)
            .position(cv.p(L.label.cg))
    }

    // MARK: キー

    private func isDown(_ action: String) -> Bool {
        pressed == action
            || (action == "play" && model.isPlaying)
            || (action == "ff" && wind > 0) || (action == "rew" && wind < 0)
    }

    private func keyView(_ L: WalkmanLayout, _ key: WalkmanLayout.Key, _ cv: Canvas) -> some View {
        let r = cv.r(key.rect.cg)
        // 本体の上面より下は溝に隠れる
        let visible = max(1, cv.v(key.clipY) - r.minY)
        let down = isDown(key.action)
        return Layer(image: image("key_\(key.action)"))
            .frame(width: r.width, height: r.height)
            .offset(y: down ? cv.v(key.press) : 0)
            .frame(width: r.width, height: visible, alignment: .top)
            .clipped()
            .animation(.easeOut(duration: 0.07), value: down)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if pressed == nil { pressBegan(key.action) } }
                .onEnded { _ in pressEnded(key.action) })
            .help(Self.help[key.action] ?? "")
            .accessibilityElement()
            .accessibilityLabel(Self.help[key.action] ?? key.action)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { perform(key.action) }
            .position(x: r.midX, y: r.minY + visible / 2)
    }

    private static let help = [
        "stop": "停止",
        "rew": "前の曲 (長押しで巻き戻し)",
        "play": "再生",
        "ff": "次の曲 (長押しで早送り)",
    ]

    private func pressBegan(_ action: String) {
        pressed = action
        guard action == "ff" || action == "rew" else { return }
        let direction: Double = action == "ff" ? 1 : -1
        windTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.35))
            guard !Task.isCancelled else { return }
            wind = direction
            while !Task.isCancelled {
                model.skip(by: direction * 3)
                try? await Task.sleep(for: .seconds(0.12))
            }
        }
    }

    private func pressEnded(_ action: String) {
        windTask?.cancel()
        windTask = nil
        pressed = nil
        if wind != 0 {
            wind = 0
            return
        }
        perform(action)
    }

    private func perform(_ action: String) {
        switch action {
        case "stop": model.pause()
        case "play":
            if model.isPlaying { break }
            if model.queue.isEmpty { presentOpenPanel() } else { model.togglePlay() }
        case "ff": model.next()
        case "rew": model.previous()
        default: break
        }
    }

    // MARK: 音量ホイール

    /// 目盛りを回して、今の音量の数字を上に出す。左右 (または上下) のドラッグで回せる
    @ViewBuilder
    private func wheel(_ L: WalkmanLayout, _ cv: Canvas) -> some View {
        let c = cv.p(L.wheel.center.cg), size = cv.v(L.wheel.size), clip = cv.v(L.wheel.clipY)
        Layer(image: image("wheel_marks"))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(270 * model.volume))
            .scaleEffect(x: 1, y: L.tilt)
            .animation(.easeOut(duration: 0.12), value: model.volume)
            .position(c)
            .frame(width: cv.full.width, height: cv.full.height)
            .mask(alignment: .topLeading) { Rectangle().frame(width: cv.full.width, height: clip) }
            .allowsHitTesting(false)
        let top = c.y - size / 2 * L.tilt
        Rectangle().fill(.white.opacity(0.001))
            .frame(width: size, height: clip - top + size * 0.12)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if volumeStart == nil { volumeStart = model.volume }
                    model.volume = min(1, max(0, (volumeStart ?? 0) + (v.translation.width - v.translation.height) / 220))
                }
                .onEnded { _ in volumeStart = nil })
            .help("音量 (ドラッグ、またはスクロール)")
            .accessibilityElement()
            .accessibilityLabel("音量")
            .accessibilityValue("\(Int((model.volume * 100).rounded()))%")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: model.volume = min(1, model.volume + 0.05)
                case .decrement: model.volume = max(0, model.volume - 0.05)
                @unknown default: break
                }
            }
            .position(x: c.x, y: (top + clip + size * 0.12) / 2)
    }
}
