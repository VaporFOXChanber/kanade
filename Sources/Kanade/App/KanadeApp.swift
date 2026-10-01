import AppKit
import SwiftUI

@main
struct KanadeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = PlayerModel.shared

    var body: some Scene {
        Window("Kanade", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 840, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1160, height: 780)
        .commands { PlayerCommands(model: model) }

        Window("ライブラリ", id: "library") {
            LibraryView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .defaultSize(width: 1000, height: 660)

        Window("ミニプレイヤー", id: "mini") {
            MiniPlayerView().environment(model)
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .defaultPosition(.topTrailing)

        Settings {
            SettingsView().environment(model)
        }
    }
}

struct PlayerCommands: Commands {
    let model: PlayerModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = WindowOpener.action = openWindow
        CommandGroup(replacing: .newItem) {
            Button("開く…") { presentOpenPanel() }.keyboardShortcut("o")
            Divider()
            Button("この作品のアートワークを選ぶ…") { model.chooseArtwork() }.disabled(model.currentTrack == nil)
            Button("アートワークを元に戻す") { model.clearCustomArtwork() }.disabled(!model.hasCustomArtwork)
            Divider()
            Button("曲の情報") { NotificationCenter.default.post(name: .kanadeShowInfo, object: nil) }
                .keyboardShortcut("i").disabled(model.currentTrack == nil)
            Button("再生キューをプレイリストとして保存") { model.saveQueueAsPlaylist() }.disabled(model.queue.isEmpty)
        }
        CommandMenu("再生") {
            Button("再生 / 一時停止") { model.togglePlay() }
            Button("次の曲") { model.next() }.keyboardShortcut(.rightArrow, modifiers: .command)
            Button("前の曲") { model.previous() }.keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("10 秒進む") { model.skip(by: 10) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("10 秒戻る") { model.skip(by: -10) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Divider()
            Button("音量を上げる") { model.volume = min(1, model.volume + 0.05) }.keyboardShortcut(.upArrow, modifiers: .command)
            Button("音量を下げる") { model.volume = max(0, model.volume - 0.05) }.keyboardShortcut(.downArrow, modifiers: .command)
            Button("消音") { model.muted.toggle() }
            Divider()
            Button("速度を上げる") { model.changeRate(by: 0.05) }.keyboardShortcut("=", modifiers: .command).disabled(model.asmrMode)
            Button("速度を下げる") { model.changeRate(by: -0.05) }.keyboardShortcut("-", modifiers: .command).disabled(model.asmrMode)
            Button("等速に戻す") { model.rate = 1 }.keyboardShortcut("0", modifiers: .command).disabled(model.asmrMode || model.rate == 1)
            Divider()
            Button("シャッフル") { model.shuffle.toggle() }.keyboardShortcut("s")
            Button("リピートを切り替え") { model.repeatMode = model.repeatMode.next }.keyboardShortcut("r")
            Button("A-B リピート") { model.toggleABLoop() }.keyboardShortcut("b")
            Divider()
            Button(model.isCurrentFavorite ? "お気に入りから外す" : "お気に入りに追加") { model.toggleFavorite() }
                .keyboardShortcut("f", modifiers: [.command, .shift]).disabled(model.currentTrack == nil)
            Button("しおりをはさむ") { model.addBookmark() }.keyboardShortcut("d")
            Button("前のしおりへ") { model.previousBookmark() }.keyboardShortcut("[")
            Button("次のしおりへ") { model.nextBookmark() }.keyboardShortcut("]")
            Divider()
            Button("スリープタイマーを 15 分延ばす") { model.extendSleep() }.disabled(model.sleepDeadline == nil)
            Button("おやすみ前の位置へ戻る") { model.returnToSleepPoint() }.disabled(model.lastSleepPoint == nil)
            Divider()
            Toggle("ASMR モード", isOn: Binding(get: { model.asmrMode }, set: { model.asmrMode = $0 }))
                .keyboardShortcut("a", modifiers: [.command, .option])
            Toggle("左右を入れ替え (ASMR)", isOn: Binding(get: { model.swapChannels }, set: { model.swapChannels = $0 }))
                .disabled(!model.asmrMode)
            Toggle("省電力表示 (ASMR)", isOn: Binding(get: { model.lowPowerDisplay }, set: { model.lowPowerDisplay = $0 }))
                .disabled(!model.asmrMode)
            Button("左右を確認 (ASMR)") { model.playChannelCheck() }.disabled(!model.asmrMode)
            Divider()
            Toggle("排他モード", isOn: Binding(get: { model.exclusiveMode }, set: { model.exclusiveMode = $0 }))
                .disabled(model.switchingExclusive)
            Toggle("デバイスのサンプルレートを曲に合わせる", isOn: Binding(get: { model.matchSampleRate }, set: { model.matchSampleRate = $0 }))
        }
        CommandGroup(before: .toolbar) {
            Button("歌詞を表示 / 隠す") { withAnimation { model.showLyrics.toggle() } }.keyboardShortcut("l")
            Button("再生キューを表示 / 隠す") { model.showQueue.toggle() }.keyboardShortcut("u")
            Button("プレイヤーの見た目を切り替え") { model.skin = model.skin.next }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("ビジュアライザーを切り替え") { model.visualizer = model.visualizer.next }.keyboardShortcut("v", modifiers: [.command, .option])
            Button("イコライザー・音響効果…") { NotificationCenter.default.post(name: .kanadeShowSound, object: nil) }
                .keyboardShortcut("e", modifiers: [.command, .option])
            Button("ミニプレイヤー") { openWindow(id: "mini") }.keyboardShortcut("m", modifiers: [.command, .option])
            Button("ライブラリ") { openWindow(id: "library") }.keyboardShortcut("l", modifiers: [.command, .option])
            Divider()
        }
    }
}

/// AppKit 側 (AppDelegate) から SwiftUI のウィンドウを開くための橋渡し
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction?

    static func showMain() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            w.makeKeyAndOrderFront(nil)
        } else {
            action?(id: "main")
        }
        NSApp.activate()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = PlayerModel.shared
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // テキスト入力中はそのまま
            if event.window?.firstResponder is NSText { return event }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard mods.isEmpty || mods == .shift else { return event }
            switch event.keyCode {
            case 49: model.togglePlay(); return nil // space
            case 123: model.skip(by: mods == .shift ? -30 : -5); return nil // ←
            case 124: model.skip(by: mods == .shift ? 30 : 5); return nil // →
            default: break
            }
            if mods.isEmpty, let c = event.charactersIgnoringModifiers?.lowercased() {
                switch c {
                case "m": model.muted.toggle(); return nil
                case "[", "]":
                    // ASMR モード中は等速のまま
                    model.changeRate(by: c == "[" ? -0.05 : 0.05)
                    return nil
                default: break
                }
            }
            return event
        }

        // 開発用: 画面を画像に書き出して終了する (確認用のビルドだけ)
        let snapshot = DevSnapshot.directory
        if let snapshot { Task { await DevSnapshot.run(into: snapshot) } }

        // コマンドライン引数で渡されたファイル (open -a Kanade --args ...)
        let paths = CommandLine.arguments.dropFirst().filter {
            !$0.hasPrefix("-") && $0 != snapshot?.path && FileManager.default.fileExists(atPath: $0)
        }
        if !paths.isEmpty { model.open(paths.map { URL(fileURLWithPath: $0) }) }

        // 引数やファイル付きで起動されると SwiftUI がメインウィンドウを開かないことがあるので保険
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if !NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
                WindowOpener.showMain()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        PlayerModel.shared.open(urls)
        // ファイルを開く形で起動された場合、SwiftUI はメインウィンドウを自動では開かない
        DispatchQueue.main.async { WindowOpener.showMain() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // ミニプレイヤーだけが出ているときも、Dock のアイコンでメインウィンドウを戻す
        if !NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
            WindowOpener.showMain()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        PlayerModel.shared.saveNow()
        // 切り替えた出力デバイスのサンプルレートと排他モードを元に戻す
        PlayerModel.shared.engine.restoreOutputDevice(releaseExclusive: true)
    }
}
