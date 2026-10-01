import AppKit
import SwiftUI

/// 開発用: 画面の部品をウィンドウなしで画像に書き出す。
/// 確認用のビルド (Kanade Dev.app) を `--snapshot <フォルダ>` を付けて起動したときだけ動く。
/// `--shots library,sound-output` のように名前の先頭を並べると、その画面だけを書き出す。
/// 画面を操作できない状況 (別の操作スペースにいるなど) でも、見た目を確かめられる
@MainActor
enum DevSnapshot {
    /// 書き出し先のフォルダ (確認用のビルドで、引数が付いているときだけ)
    static var directory: URL? {
        guard Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true,
              let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count else { return nil }
        return URL(fileURLWithPath: CommandLine.arguments[i + 1])
    }

    /// 書き出す画面を絞るための、名前の先頭の一覧 (指定がなければすべて)
    private static var wanted: [String]? {
        guard let i = CommandLine.arguments.firstIndex(of: "--shots"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1].split(separator: ",").map(String.init)
    }

    static func run(into dir: URL) async {
        let model = PlayerModel.shared
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 表示する中身がそろうのを少し待つ (メタデータ・アートワークの読み込み)
        try? await Task.sleep(for: .seconds(2))
        let wanted = wanted
        for shot in DevSnapshotCatalog.shots(model: model) where wanted?.contains(where: shot.name.hasPrefix) ?? true {
            shot.prepare()
            try? await Task.sleep(for: .milliseconds(150))
            guard let content = shot.view() else { continue }
            let view = content
                .environment(model)
                .background(Color(white: 0.13))
                .preferredColorScheme(.dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            var size = host.fittingSize
            if let fixed = shot.size { size = fixed }
            window.setContentSize(size)
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(shot.settle))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: dir.appendingPathComponent(shot.name + ".png"))
            }
            window.contentView = nil
        }
        NSApp.terminate(nil)
    }
}

struct DevSnapshotShot {
    let name: String
    var size: CGSize?
    var settle = 400
    var prepare: () -> Void = {}
    /// 撮る画面 (prepare のあとで作る。撮れる状態でなければ nil)
    let view: () -> AnyView?
}
