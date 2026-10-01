import AppKit
import ImageIO
import SwiftUI

/// アートワークから抽出した配色
struct Palette: Equatable {
    var accent: Color
    var secondary: Color
    var background: [Color]
    var blur: NSImage?

    static let `default` = Palette(
        accent: Color(red: 0.76, green: 0.66, blue: 1.0),
        secondary: Color(red: 1.0, green: 0.52, blue: 0.78),
        background: [Color(red: 0.16, green: 0.11, blue: 0.30), Color(red: 0.05, green: 0.05, blue: 0.10)],
        blur: nil
    )

    static func from(_ image: NSImage?) -> Palette {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .default }
        let size = 28
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .default }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))

        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, weight = 0.0, count = 0.0 }
        var hues = [Bucket](repeating: Bucket(), count: 24)
        var all = Bucket()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
            let (h, s, v) = hsv(r, g, b)
            all.r += r; all.g += g; all.b += b; all.count += 1
            guard s > 0.2, v > 0.18 else { continue }
            let k = min(23, Int(h * 24))
            let w = s * s * (0.4 + v)
            hues[k].r += r * w; hues[k].g += g * w; hues[k].b += b * w; hues[k].weight += w; hues[k].count += 1
        }

        let ranked = hues.enumerated().filter { $0.element.count >= 3 }.sorted { $0.element.weight > $1.element.weight }
        func color(_ bk: Bucket) -> (Double, Double, Double) { (bk.r / bk.weight, bk.g / bk.weight, bk.b / bk.weight) }

        let avg = (all.r / all.count, all.g / all.count, all.b / all.count)
        let (ah, as_, _) = hsv(avg.0, avg.1, avg.2)
        let bg1 = rgb(ah, min(as_ * 1.1, 0.7), 0.30)
        let bg2 = rgb(ah, min(as_, 0.5), 0.09)

        var accent: Color, secondary: Color
        if let first = ranked.first {
            let (r, g, b) = color(first.element)
            let (h, s, _) = hsv(r, g, b)
            accent = rgb(h, min(max(s, 0.38), 0.72), 0.97)
            if let second = ranked.dropFirst().first(where: { abs($0.offset - first.offset) >= 3 && abs($0.offset - first.offset) <= 21 }) {
                let (r2, g2, b2) = color(second.element)
                let (h2, s2, _) = hsv(r2, g2, b2)
                secondary = rgb(h2, min(max(s2, 0.35), 0.75), 0.95)
            } else {
                secondary = rgb((h + 0.08).truncatingRemainder(dividingBy: 1), min(max(s, 0.38), 0.7), 0.92)
            }
        } else {
            accent = Color(white: 0.94)
            secondary = Color(white: 0.7)
        }

        var blur: NSImage?
        if let small = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            small.interpolationQuality = .high
            small.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
            if let out = small.makeImage() { blur = NSImage(cgImage: out, size: NSSize(width: 64, height: 64)) }
        }

        return Palette(accent: accent, secondary: secondary, background: [bg1, bg2], blur: blur)
    }

    private static func hsv(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double, Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx == 0 ? 0 : d / mx, mx)
    }

    private static func rgb(_ h: Double, _ s: Double, _ v: Double) -> Color {
        Color(hue: h, saturation: s, brightness: v)
    }
}

/// アートワークの読み込みとキャッシュ (同じアルバムのトラック間で共有)。
///
/// 探す順番: 手動で指定した画像 → 音源に埋め込まれた画像 → 同じフォルダの cover.jpg など →
/// 作品のフォルダの中の画像 → (設定で有効なら) DLsite の作品画像
@MainActor
@Observable
final class ArtworkStore {
    static let shared = ArtworkStore()
    /// 画像の選び方が変わるたびに進める (表示中のサムネイルの読み直しに使う)
    private(set) var revision = 0
    /// 作品番号が分かる曲のアートワークを DLsite から取得するか
    @ObservationIgnored var downloadsEnabled = Defaults.bool("dlsiteArtwork", false)

    @ObservationIgnored private let full = NSCache<NSString, NSImage>()
    @ObservationIgnored private let thumbs = NSCache<NSString, NSImage>()
    @ObservationIgnored private var missing = Set<String>()
    @ObservationIgnored private var inflight: [String: Task<NSImage?, Never>] = [:]
    /// 手動で指定したアートワーク: 作品のキー (ArtworkFinder.workKey) → 保存したファイル名
    @ObservationIgnored private var custom: [String: String] = [:]
    /// 画像ファイルを縮小した結果 (同じ作品のトラックで使い回す)
    nonisolated(unsafe) private static let files = NSCache<NSString, NSImage>()

    private var directory: URL { DLsiteArtwork.directory(in: PlayerModel.supportDirectory) }
    private var customIndexURL: URL { directory.appendingPathComponent("custom.json") }

    init() {
        full.countLimit = 24
        thumbs.countLimit = 600
        Self.files.countLimit = 80
        if let data = try? Data(contentsOf: customIndexURL),
           let index = try? JSONDecoder().decode([String: String].self, from: data) { custom = index }
    }

    func image(for track: Track) async -> NSImage? {
        await load(track, maxPixel: 1200, cache: full, prefix: "f:")
    }

    func thumbnail(for track: Track) async -> NSImage? {
        await load(track, maxPixel: 96, cache: thumbs, prefix: "t:")
    }

    func cachedThumbnail(for track: Track) -> NSImage? {
        thumbs.object(forKey: ("t:" + track.artworkKey) as NSString)
    }

    private func load(_ track: Track, maxPixel: Int, cache: NSCache<NSString, NSImage>, prefix: String) async -> NSImage? {
        let key = prefix + track.artworkKey
        if let img = cache.object(forKey: key as NSString) { return img }
        if missing.contains(key) { return nil }
        if let t = inflight[key] { return await t.value }
        let chosen = customFile(for: track)
        let download = downloadsEnabled
        let saved = directory
        let started = revision
        let task = Task.detached(priority: maxPixel > 200 ? .userInitiated : .utility) { () -> NSImage? in
            if let chosen, let img = Self.fileImage(chosen, maxPixel: maxPixel) { return img }
            if let data = await MetadataReader.artworkData(track.url), let img = Self.downscale(data, maxPixel: maxPixel) { return img }
            if let folder = track.folderArtURL, let img = Self.fileImage(folder, maxPixel: maxPixel) { return img }
            if let found = ArtworkFinder.find(for: track.url), let img = Self.fileImage(found, maxPixel: maxPixel) { return img }
            if download, let code = ArtworkFinder.workCode(for: track.url),
               let file = await DLsiteArtwork.shared.image(code: code, in: saved) {
                return Self.fileImage(file, maxPixel: maxPixel)
            }
            return nil
        }
        inflight[key] = task
        let img = await task.value
        inflight[key] = nil
        // 読み込みの途中で選び方が変わっていたら、古い結果は覚えない
        guard started == revision else { return img }
        if let img { cache.setObject(img, forKey: key as NSString) } else { missing.insert(key) }
        return img
    }

    nonisolated private static func fileImage(_ url: URL, maxPixel: Int) -> NSImage? {
        let key = "\(maxPixel):\(url.path)" as NSString
        if let hit = files.object(forKey: key) { return hit }
        guard let data = try? Data(contentsOf: url), let img = downscale(data, maxPixel: maxPixel) else { return nil }
        files.setObject(img, forKey: key)
        return img
    }

    /// 覚えている結果をすべて捨てて、探し直させる
    func invalidate() {
        full.removeAllObjects()
        thumbs.removeAllObjects()
        Self.files.removeAllObjects()
        missing.removeAll()
        ArtworkFinder.clearCache()
        revision += 1
    }

    // MARK: 手動で指定したアートワーク

    private func customFile(for track: Track) -> URL? {
        custom[ArtworkFinder.workKey(for: track)].map { directory.appendingPathComponent($0) }
    }

    func hasCustom(for track: Track) -> Bool {
        _ = revision
        return custom[ArtworkFinder.workKey(for: track)] != nil
    }

    /// 画像ファイルを、その曲の作品のアートワークとして覚える (画像は複製して持つ)
    func setCustom(imageAt source: URL, for track: Track) -> Bool {
        guard let data = try? Data(contentsOf: source), Self.downscale(data, maxPixel: 96) != nil else { return false }
        let ext = source.pathExtension.isEmpty ? "img" : source.pathExtension.lowercased()
        let name = "custom-\(UUID().uuidString).\(ext)"
        guard (try? data.write(to: directory.appendingPathComponent(name), options: .atomic)) != nil else { return false }
        let key = ArtworkFinder.workKey(for: track)
        if let old = custom[key] { try? FileManager.default.removeItem(at: directory.appendingPathComponent(old)) }
        custom[key] = name
        saveCustomIndex()
        invalidate()
        return true
    }

    func removeCustom(for track: Track) {
        guard let old = custom.removeValue(forKey: ArtworkFinder.workKey(for: track)) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
        saveCustomIndex()
        invalidate()
    }

    private func saveCustomIndex() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        try? data.write(to: customIndexURL, options: .atomic)
    }

    // MARK: DLsite から取得した画像

    /// 取得して保存してある画像の数
    func downloadedCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { ArtworkFinder.workCode(inName: $0) != nil && !$0.hasSuffix(".none") }.count
    }

    func clearDownloads() {
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        where ArtworkFinder.workCode(inName: name) != nil {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        invalidate()
    }

    nonisolated static func downscale(_ data: Data, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return NSImage(data: data) }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return NSImage(data: data) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
