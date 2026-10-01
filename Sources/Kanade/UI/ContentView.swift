import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(PlayerModel.self) private var model
    @State private var dropTargeted = false
    /// ウィンドウを閉じると SwiftUI はウィンドウを隠すだけなので、そのままだと見えない画面が
    /// 再生位置の更新のたびに描き直され続ける。閉じている間は中身を外しておく。
    @State private var windowOpen = true

    var body: some View {
        ZStack {
            Backdrop(palette: model.palette)
            if model.powerSaving {
                // 省電力表示: 画面を暗めにする
                Color.black.opacity(0.4).ignoresSafeArea().allowsHitTesting(false)
            }

            if windowOpen {
                HStack(spacing: 0) {
                    NowPlayingView()
                        .frame(minWidth: 460)
                    if model.showQueue {
                        QueueView()
                            .frame(width: 340)
                            .padding(.vertical, 12)
                            .padding(.trailing, 12)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }

            if dropTargeted {
                ZStack {
                    Rectangle().fill(.black.opacity(0.35))
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle").font(.system(size: 52, weight: .light))
                        Text("ドロップしてキューに追加").font(.title2.bold())
                    }
                    .foregroundStyle(.white)
                    .padding(44)
                    .glassEffect(.regular, in: .rect(cornerRadius: 28))
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                HStack(spacing: 8) {
                    Image(systemName: toast.symbol).foregroundStyle(model.palette.accent)
                    Text(toast.message).lineLimit(2)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(toast.id)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls, play: !model.isPlaying)
            return true
        } isTargeted: { t in
            withAnimation(.easeOut(duration: 0.2)) { dropTargeted = t }
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: model.showQueue)
        .animation(.easeInOut(duration: 0.3), value: model.visualizer)
        .preferredColorScheme(.dark)
        .tint(model.palette.accent)
        .ignoresSafeArea()
        .background(WindowOpenReader { windowOpen = $0 })
        .transaction { t in
            // 省電力表示ではアニメーションをすべて止める
            if model.powerSaving {
                t.animation = nil
                t.disablesAnimations = true
            }
        }
    }
}

/// ウィンドウが開いているか (閉じて隠された状態でないか) を知らせる。しまっている (Dock に入れた) 間は開いている扱い
struct WindowOpenReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        private let onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var reported: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] n in
                    let closing = n.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated { self?.update(closing: closing) }
                    // ファイルを開く操作を受けたとき、SwiftUI はウィンドウをいったん閉じてから出し直す。
                    // 出し直されたウィンドウが手前に来ない (ほかのアプリの後ろにある) と何の通知も来ないので、少し待って確かめ直す
                    if closing {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                            MainActor.assumeIsolated { self?.update(closing: false) }
                        }
                    }
                })
            }
        }

        private func update(closing: Bool) {
            guard let window else { return }
            let open = !closing && (window.isVisible || window.isMiniaturized)
            // 最初に表示される前の「まだ見えていない」状態では外さない
            if reported == nil {
                if open { reported = true }
                return
            }
            guard open != reported else { return }
            reported = open
            onChange(open)
        }
    }
}

/// アートワークをぼかした背景
struct Backdrop: View {
    let palette: Palette

    var body: some View {
        ZStack {
            LinearGradient(colors: palette.background, startPoint: .topLeading, endPoint: .bottomTrailing)
            if let blur = palette.blur {
                // Color.clear に重ねることで、画像がウィンドウより大きなサイズを要求しないようにする
                Color.clear
                    .overlay {
                        Image(nsImage: blur)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 70, opaque: true)
                            .saturation(1.35)
                    }
                    .clipped()
                    .opacity(0.62)
                    .transition(.opacity)
                    .id(ObjectIdentifier(blur))
            }
            RadialGradient(colors: [palette.accent.opacity(0.22), .clear], center: .topLeading, startRadius: 0, endRadius: 780)
            RadialGradient(colors: [palette.secondary.opacity(0.14), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 700)
            LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}
