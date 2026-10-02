import AppKit
import SwiftUI

/// 常に手前に表示される小さなプレイヤー。ボタン以外ならどこをつかんでも動かせる。
/// プレイヤーの見た目がカセットのときは、ポータブルカセットプレイヤーの姿になる。
struct MiniPlayerView: View {
    @Environment(PlayerModel.self) private var model
    @State private var hover = false

    private var walkman: Bool { model.skin == .cassette && SkinAssets.shared.available(.cassette) && WalkmanPlayer.available }

    var body: some View {
        Group {
            if walkman {
                WalkmanPlayer().frame(width: WalkmanPlayer.width, height: WalkmanPlayer.height)
            } else {
                StandardMiniPlayer()
            }
        }
        .overlay(alignment: walkman ? .topLeading : .topTrailing) {
            if hover {
                Button { MiniPlayerPanel.shared.close() } label: {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("ミニプレイヤーを閉じる")
                .accessibilityLabel("ミニプレイヤーを閉じる")
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { MiniWindowMover.shared.drag(translation: $0.translation) }
            .onEnded { _ in MiniWindowMover.shared.endDrag() })
        .contextMenu {
            Button("メインウィンドウを表示") { WindowOpener.showMain() }
            Button("ミニプレイヤーを閉じる") { MiniPlayerPanel.shared.close() }
        }
        // 他のアプリを使っている最中でも、最初のクリックからドラッグやボタンが効くようにする
        .allowsWindowActivationEvents(true)
        .onHover { hover = $0 }
        .transaction { t in
            if model.powerSaving {
                t.animation = nil
                t.disablesAnimations = true
            }
        }
        .preferredColorScheme(.dark)
    }
}

extension WalkmanPlayer {
    static var available: Bool { SkinAssets.shared.image(folder: "walkman", "body") != nil }
}

private struct StandardMiniPlayer: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let t = model.currentTrack
        HStack(spacing: 12) {
            ArtworkView(image: model.artwork, palette: model.palette, cornerRadius: 9)
                .frame(width: 58, height: 58)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 3) {
                (t.map(shortTitleText) ?? Text("再生していません")).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(t?.displayArtist ?? "").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                MiniProgress().padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                IconButton(symbol: "backward.fill", size: 12, help: "前の曲") { model.previous() }
                IconButton(symbol: model.isPlaying ? "pause.fill" : "play.fill", size: 16, help: "再生 / 一時停止") { model.togglePlay() }
                IconButton(symbol: "forward.fill", size: 12, help: "次の曲") { model.next() }
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .frame(width: 380)
        .background(Backdrop(palette: model.palette))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct MiniProgress: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let c = model.clock
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(model.palette.accent).frame(width: g.size.width * min(1, c.position / max(c.duration, 0.001)))
            }
        }
        .frame(height: 3)
    }
}

// MARK: - ウィンドウ

/// ミニプレイヤーのウィンドウ。クリックしても Kanade を手前のアプリに切り替えないパネルにしてある。
/// ふつうのウィンドウだと、別のアプリを使っている最中に動かしたりボタンを押したりするたびに Kanade が手前のアプリになり、
/// 使っていたアプリから操作が離れて、メインウィンドウまで前に出てくることがある
@MainActor
final class MiniPlayerPanel {
    static let shared = MiniPlayerPanel()

    private var panel: NSPanel?

    var isOpen: Bool { panel != nil }

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let content = NSHostingController(rootView: MiniPlayerView().environment(PlayerModel.shared))
        // 見た目の切り替えで中身の大きさが変わったら、ウィンドウも合わせる
        content.sizingOptions = [.preferredContentSize]
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.title = "ミニプレイヤー"
        p.isReleasedWhenClosed = false
        // ほかのアプリの「常に手前」のウィンドウよりも前に出す
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.utilityWindow)))
        // Kanade が手前のアプリでない間も出したままにする (パネルは既定で隠れる)
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentViewController = content
        p.setContentSize(content.view.fittingSize)
        MiniWindowMover.shared.attach(p)
        p.orderFrontRegardless()
        panel = p
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        // 閉じている間は、中身を描き直さない
        p.contentViewController = nil
        p.close()
        // ミニプレイヤーだけで使っていたときは、最後のウィンドウを閉じたときと同じように終了する
        if !NSApp.windows.contains(where: { $0.isVisible || $0.isMiniaturized }) { NSApp.terminate(nil) }
    }
}

// MARK: - ウィンドウの移動

/// ミニプレイヤーのウィンドウをドラッグで動かし、画面の端の近くで離すと端に吸い付かせる。
/// 位置は覚えておき、次に開いたときも同じ場所に出す。
@MainActor
final class MiniWindowMover {
    static let shared = MiniWindowMover()

    /// 画面の端からの余白と、吸い付く距離
    private let margin: CGFloat = 8
    private let snapDistance: CGFloat = 28
    private let positionKey = "miniTopLeft"

    private weak var window: NSWindow?
    private var start: (mouse: CGPoint, origin: CGPoint)?
    private var lastFrame: NSRect?
    private var observers: [NSObjectProtocol] = []
    private var scrollMonitor: Any?

    func attach(_ w: NSWindow) {
        guard window !== w else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        window = w
        // どのデスクトップ (フルスクリーンのアプリの上を含む) にもついてくる
        w.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        w.isMovableByWindowBackground = false
        // 透明なウィンドウは「透明な部分のクリックを下のウィンドウに通す」扱いになり、
        // 画像を重ねて描いたウォークマンは本体の上でもクリックが素通りしてしまう。明示して全体で受け取る
        w.ignoresMouseEvents = false
        // 形に沿った影 (透明な部分には付かない)
        w.hasShadow = true
        observers = [
            NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: w, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didResize() }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.settle(animated: false) }
            },
        ]
        if scrollMonitor == nil {
            // ウォークマンの上でスクロールすると音量ホイールが回る
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let target = event.window.map(ObjectIdentifier.init)
                // 指 (ホイール) を上に動かすと大きくなる向きにそろえる (ナチュラルスクロールの設定によらない)
                let physical = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
                let delta = physical * (event.hasPreciseScrollingDeltas ? 0.0025 : 0.02)
                let consumed = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let w = self.window, target == ObjectIdentifier(w), PlayerModel.shared.skin == .cassette else { return false }
                    let model = PlayerModel.shared
                    model.volume = min(1, max(0, model.volume + Double(delta)))
                    return true
                }
                return consumed ? nil : event
            }
        }
        restore()
    }

    func drag(translation: CGSize) {
        guard let w = window else { return }
        let mouse = Self.pointerLocation()
        if start == nil {
            // ジェスチャーが始まった時点の移動量を差し引いて、押した位置を基準にする
            start = (CGPoint(x: mouse.x - translation.width, y: mouse.y + translation.height), w.frame.origin)
        }
        guard let s = start else { return }
        w.setFrameOrigin(CGPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
    }

    /// 処理中のドラッグイベントの位置 (画面座標)。ウィンドウ内の座標はウィンドウと一緒に動いてしまうので使わない
    private static func pointerLocation() -> CGPoint {
        if let e = NSApp.currentEvent, e.type == .leftMouseDragged || e.type == .leftMouseDown,
           let p = e.cgEvent?.location, let top = NSScreen.screens.first?.frame.maxY {
            return CGPoint(x: p.x, y: top - p.y)
        }
        return NSEvent.mouseLocation
    }

    func endDrag() {
        start = nil
        settle(animated: true)
    }

    /// 画面内に収め、端の近くなら端に吸い付かせて、位置を保存する
    private func settle(animated: Bool) {
        guard let w = window else { return }
        let target = snapped(w.frame, snap: true)
        if target != w.frame {
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    w.animator().setFrame(target, display: true)
                }
            } else {
                w.setFrame(target, display: true)
            }
        }
        lastFrame = target
        Defaults.set(positionKey, [target.minX, target.maxY])
    }

    private func snapped(_ frame: NSRect, snap: Bool) -> NSRect {
        let screen = NSScreen.screens.max { $0.visibleFrame.intersection(frame).area < $1.visibleFrame.intersection(frame).area } ?? NSScreen.main
        guard let vf = screen?.visibleFrame.insetBy(dx: margin, dy: margin) else { return frame }
        var f = frame
        f.origin.x = min(max(f.minX, vf.minX), vf.maxX - f.width)
        f.origin.y = min(max(f.minY, vf.minY), vf.maxY - f.height)
        if snap {
            if f.minX - vf.minX < snapDistance { f.origin.x = vf.minX }
            if vf.maxX - f.maxX < snapDistance { f.origin.x = vf.maxX - f.width }
            if f.minY - vf.minY < snapDistance { f.origin.y = vf.minY }
            if vf.maxY - f.maxY < snapDistance { f.origin.y = vf.maxY - f.height }
        }
        return f
    }

    private func restore() {
        guard let w = window else { return }
        if let p = Defaults.array(positionKey) as? [Double], p.count == 2 {
            w.setFrameTopLeftPoint(CGPoint(x: p[0], y: p[1]))
        } else if let vf = NSScreen.main?.visibleFrame {
            // はじめて開くときは、画面の右上
            w.setFrameTopLeftPoint(CGPoint(x: vf.maxX - w.frame.width - margin, y: vf.maxY - margin))
        }
        let f = snapped(w.frame, snap: false)
        w.setFrame(f, display: true)
        lastFrame = f
        // 中身が描かれてから影の形を計算し直す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak w] in w?.invalidateShadow() }
    }

    /// 見た目の切り替えで大きさが変わったら、端に寄せていた辺 (なければ左上) を動かさない
    private func didResize() {
        guard let w = window else { return }
        defer { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak w] in w?.invalidateShadow() } }
        guard let last = lastFrame, last.size != w.frame.size, start == nil else {
            lastFrame = w.frame
            return
        }
        let vf = (w.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: margin, dy: margin) ?? last
        var f = w.frame
        f.origin.x = abs(vf.maxX - last.maxX) < 2 ? last.maxX - f.width : last.minX
        f.origin.y = abs(last.minY - vf.minY) < 2 ? last.minY : last.maxY - f.height
        f = snapped(f, snap: false)
        w.setFrame(f, display: true)
        lastFrame = f
        Defaults.set(positionKey, [f.minX, f.maxY])
    }
}

private extension NSRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
