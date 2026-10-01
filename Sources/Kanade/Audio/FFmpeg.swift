import CryptoKit
import Foundation

/// 外部の ffmpeg / ffprobe を使った変換・解析。
/// macOS がネイティブに扱えない形式 (WMA, APE, DSD, WavPack, TTA, MKA, WebM ...) のためのフォールバック。
enum FFmpeg {
    static var customDirectory: String? {
        get { UserDefaults.standard.string(forKey: "ffmpegDirectory")?.nilIfBlank }
        set { UserDefaults.standard.set(newValue, forKey: "ffmpegDirectory") }
    }

    static func tool(_ name: String) -> String? {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        if let c = customDirectory { dirs.insert(c, at: 0) }
        for d in dirs {
            let p = (d as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var ffmpeg: String? { tool("ffmpeg") }
    static var ffprobe: String? { tool("ffprobe") }
    static var isAvailable: Bool { ffmpeg != nil && ffprobe != nil }

    enum Failure: LocalizedError {
        case missing
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .missing: "この形式の再生には ffmpeg が必要です（ターミナルで brew install ffmpeg）"
            case .failed(let m): "変換に失敗しました: \(m)"
            }
        }
    }

    // MARK: - プロセス実行

    @discardableResult
    static func run(_ exe: String, _ args: [String], onLine: ((String) -> Void)? = nil) async throws -> (Data, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice

        // 終了通知と stdout / stderr の読み切りの 3 つが揃ったら完了
        // (waitUntilExit はランループに依存し、GCD スレッド上では戻らないことがある)
        let group = DispatchGroup()
        let collected = LockedData(), errData = LockedData()
        group.enter()
        p.terminationHandler = { _ in group.leave() }
        try p.run()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData.append(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let reader = out.fileHandleForReading
            if let onLine {
                var pending = ""
                while case let d = reader.availableData, !d.isEmpty {
                    pending += String(decoding: d, as: UTF8.self)
                    var lines = pending.components(separatedBy: "\n")
                    pending = lines.removeLast()
                    lines.forEach(onLine)
                }
            } else {
                collected.append(reader.readDataToEndOfFile())
            }
            group.leave()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                group.notify(queue: .global(qos: .userInitiated)) {
                    let stderr = String(decoding: errData.value, as: UTF8.self)
                    if p.terminationStatus == 0 {
                        cont.resume(returning: (collected.value, stderr))
                    } else {
                        let last = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(p.terminationStatus)"
                        cont.resume(throwing: Failure.failed(last))
                    }
                }
            }
        } onCancel: {
            p.terminate()
        }
    }

    // MARK: - 解析

    struct Probe {
        var json: [String: Any]
        var format: [String: Any] { json["format"] as? [String: Any] ?? [:] }
        var streams: [[String: Any]] { json["streams"] as? [[String: Any]] ?? [] }
        var audio: [String: Any]? {
            let a = streams.filter { $0["codec_type"] as? String == "audio" }
            return a.first { (($0["disposition"] as? [String: Any])?["default"] as? Int) == 1 } ?? a.first
        }
        var cover: [String: Any]? {
            streams.first {
                $0["codec_type"] as? String == "video"
                    && (($0["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
            }
        }
        /// format と音声ストリームのタグを小文字キーでまとめたもの
        var tags: [String: String] {
            var t: [String: String] = [:]
            for src in [audio?["tags"], format["tags"]] {
                for (k, v) in (src as? [String: Any]) ?? [:] {
                    if let s = v as? String { t[k.lowercased()] = s }
                }
            }
            return t
        }
    }

    static func probe(_ url: URL) async throws -> Probe {
        guard let ffprobe else { throw Failure.missing }
        let (data, _) = try await run(ffprobe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", url.path])
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return Probe(json: json)
    }

    static let losslessCodecs: Set<String> = [
        "flac", "alac", "ape", "wavpack", "tta", "tak", "mlp", "truehd", "shorten", "wmalossless", "mp4als", "dst", "ralf",
    ]

    static func isLossless(_ codec: String) -> Bool {
        losslessCodecs.contains(codec) || codec.hasPrefix("pcm_") || codec.hasPrefix("dsd_")
    }

    // MARK: - 変換

    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Kanade/Converted", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func cacheURL(for source: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(source.path)|\(size)|\(mtime)".utf8))
        let name = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(name + ".flac")
    }

    /// 任意の音源を、macOS が再生できる FLAC に変換する (キャッシュあり)
    static func convertToFLAC(_ source: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dest = cacheURL(for: source)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dest.path)
            return dest
        }
        guard let ffmpeg else { throw Failure.missing }
        let info = try await probe(source)
        guard let a = info.audio, let index = a["index"] as? Int else {
            throw Failure.failed("音声トラックが見つかりません")
        }
        let codec = a["codec_name"] as? String ?? ""
        let rate = Int(a["sample_rate"] as? String ?? "") ?? 0
        let channels = a["channels"] as? Int ?? 2
        let bits = Int(a["bits_per_raw_sample"] as? String ?? "") ?? (a["bits_per_sample"] as? Int ?? 0)
        let duration = Double(info.format["duration"] as? String ?? "") ?? 0

        var args = ["-v", "error", "-nostdin", "-y", "-i", source.path, "-map", "0:\(index)", "-vn",
                    "-map_metadata", "0", "-c:a", "flac", "-compression_level", "0"]
        if !isLossless(codec) || (bits > 0 && bits <= 16 && !codec.hasPrefix("dsd")) {
            args += ["-sample_fmt", "s16"]
        }
        if rate > 192_000 { args += ["-ar", rate % 44100 == 0 ? "88200" : "96000"] }
        if channels > 8 { args += ["-ac", "2"] }
        let temp = dest.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".part.flac")
        args += ["-progress", "pipe:1", "-f", "flac", temp.path]

        do {
            try await run(ffmpeg, args) { line in
                if duration > 0, line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) {
                    progress(min(1, us / 1_000_000 / duration))
                }
            }
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: temp, to: dest)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        pruneCache()
        return dest
    }

    /// 埋め込みアートワークを取り出す。動画ファイルなら数秒目のフレームをサムネイルにする
    static func extractCover(_ url: URL) async -> Data? {
        guard let ffmpeg else { return nil }
        func isImage(_ d: Data) -> Bool { d.starts(with: [0xFF, 0xD8]) || d.starts(with: [0x89, 0x50, 0x4E, 0x47]) }

        let base = ["-v", "error", "-nostdin"]
        if let (d, _) = try? await run(ffmpeg, base + ["-i", url.path, "-an", "-map", "0:v:0", "-frames:v", "1",
                                                       "-c:v", "copy", "-f", "image2pipe", "pipe:1"]) {
            if isImage(d) { return d }
            if d.isEmpty { return nil } // 映像なし
        }
        let encode = ["-an", "-map", "0:v:0", "-frames:v", "1", "-vf", "scale='min(1200,iw)':-2",
                      "-c:v", "mjpeg", "-q:v", "3", "-f", "image2pipe", "pipe:1"]
        for seek in [["-ss", "5"], []] {
            if let (d, _) = try? await run(ffmpeg, base + seek + ["-i", url.path] + encode), isImage(d) { return d }
        }
        return nil
    }

    /// 変換キャッシュが 4GB を超えたら古いものから削除
    static func pruneCache(limit: Int64 = 4 << 30) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries = files.compactMap { u -> (URL, Int64, Date)? in
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (u, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > limit else { return }
        entries.sort { $0.2 < $1.2 }
        for e in entries where total > limit {
            try? fm.removeItem(at: e.0)
            total -= e.1
        }
    }

    static func cacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
