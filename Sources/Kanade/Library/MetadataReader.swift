import AppKit
import AVFoundation

/// タグ・技術情報・アートワーク・埋め込み歌詞の読み取り。
/// まず AVFoundation で読み、扱えない形式は ffprobe / ffmpeg にフォールバックする。
enum MetadataReader {
    struct Tags {
        var values: [String: String] = [:]
        var artwork: Data?
        subscript(_ key: String) -> String? { values[key] }
        mutating func put(_ key: String, _ value: String?) {
            guard let v = value?.nilIfBlank, values[key] == nil else { return }
            values[key] = TextDecoding.fixMojibake(v).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    // MARK: - メタデータ

    static func read(_ url: URL) async -> TrackMeta {
        var meta = TrackMeta()
        meta.loaded = true
        meta.fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)

        var tags = Tags()
        if let file = try? AVAudioFile(forReading: url) {
            applyTech(file, url: url, to: &meta)
            tags = await avTags(url, wantArtwork: false)
        } else if FFmpeg.isAvailable, let probe = try? await FFmpeg.probe(url) {
            applyProbe(probe, to: &meta)
            for (k, v) in probe.tags { tags.put(normalizedKey(k), v) }
        }

        meta.title = tags["title"]
        meta.artist = tags["artist"]
        meta.album = tags["album"]
        meta.albumArtist = tags["albumartist"]
        meta.genre = tags["genre"].map(cleanGenre)
        if let d = tags["date"], let r = d.range(of: #"\d{4}"#, options: .regularExpression) { meta.year = String(d[r]) }
        meta.trackNumber = tags["track"].flatMap(leadingInt)
        meta.discNumber = tags["disc"].flatMap(leadingInt)
        meta.rgTrackGain = tags["replaygain_track_gain"].flatMap(leadingDouble)
        meta.rgTrackPeak = tags["replaygain_track_peak"].flatMap(leadingDouble)
        meta.rgAlbumGain = tags["replaygain_album_gain"].flatMap(leadingDouble)
        meta.rgAlbumPeak = tags["replaygain_album_peak"].flatMap(leadingDouble)
        meta.hasEmbeddedLyrics = tags["lyrics"] != nil
        meta.embeddedCueSheet = tags["cuesheet"]

        if meta.bitrate == nil, let size = meta.fileSize, let d = meta.fileDuration, d > 0 {
            meta.bitrate = Int(Double(size) * 8 / d)
        }
        return meta
    }

    private static func applyTech(_ file: AVAudioFile, url: URL, to meta: inout TrackMeta) {
        let fmt = file.fileFormat
        let asbd = fmt.streamDescription.pointee
        meta.sampleRate = fmt.sampleRate
        meta.channels = Int(fmt.channelCount)
        if fmt.sampleRate > 0 { meta.fileDuration = Double(file.length) / file.processingFormat.sampleRate }

        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            let ext = url.pathExtension.lowercased()
            meta.codec = ["aif", "aiff", "aifc"].contains(ext) ? "AIFF" : ext == "caf" ? "CAF" : "WAV"
            meta.bitDepth = Int(asbd.mBitsPerChannel)
            meta.lossless = true
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            meta.codec = asbd.mFormatID == kAudioFormatFLAC ? "FLAC" : "ALAC"
            meta.bitDepth = [1: 16, 2: 20, 3: 24, 4: 32][asbd.mFormatFlags]
            meta.lossless = true
        case kAudioFormatMPEGLayer3: meta.codec = "MP3"
        case kAudioFormatMPEGLayer2: meta.codec = "MP2"
        case kAudioFormatMPEG4AAC: meta.codec = "AAC"
        case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: meta.codec = "HE-AAC"
        case kAudioFormatOpus: meta.codec = "Opus"
        case kAudioFormatAC3: meta.codec = "AC-3"
        case kAudioFormatEnhancedAC3: meta.codec = "E-AC-3"
        default:
            let id = asbd.mFormatID
            let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((id >> $0) & 0xFF))) }
            let code = String(chars).trimmingCharacters(in: .whitespaces)
            meta.codec = code == "vorb" ? "Vorbis" : code.uppercased()
        }
        if meta.lossless == nil { meta.lossless = false }
    }

    private static func applyProbe(_ probe: FFmpeg.Probe, to meta: inout TrackMeta) {
        guard let a = probe.audio else { return }
        let codec = a["codec_name"] as? String ?? ""
        let names: [String: String] = [
            "wmav1": "WMA", "wmav2": "WMA", "wmapro": "WMA Pro", "wmalossless": "WMA Lossless", "ape": "APE",
            "wavpack": "WavPack", "tta": "TTA", "tak": "TAK", "dts": "DTS", "truehd": "TrueHD", "mlp": "MLP",
            "musepack7": "Musepack", "musepack8": "Musepack", "vorbis": "Vorbis", "opus": "Opus", "flac": "FLAC",
            "alac": "ALAC", "aac": "AAC", "mp3": "MP3", "ac3": "AC-3", "eac3": "E-AC-3", "amr_nb": "AMR", "amr_wb": "AMR-WB",
            "dst": "DST", "shorten": "Shorten", "cook": "RealAudio", "speex": "Speex",
        ]
        meta.codec = names[codec] ?? (codec.hasPrefix("dsd_") ? "DSD" : codec.hasPrefix("pcm_") ? "PCM" : codec.uppercased())
        meta.sampleRate = Double(a["sample_rate"] as? String ?? "")
        meta.channels = a["channels"] as? Int
        let bits = Int(a["bits_per_raw_sample"] as? String ?? "") ?? (a["bits_per_sample"] as? Int ?? 0)
        if codec.hasPrefix("dsd_") || codec == "dst" {
            meta.bitDepth = 1
        } else if bits > 0, FFmpeg.isLossless(codec) {
            meta.bitDepth = bits
        }
        meta.lossless = FFmpeg.isLossless(codec)
        meta.bitrate = Int(a["bit_rate"] as? String ?? "") ?? Int(probe.format["bit_rate"] as? String ?? "")
        meta.fileDuration = Double(probe.format["duration"] as? String ?? "") ?? Double(a["duration"] as? String ?? "")
    }

    // MARK: - AVFoundation のタグ

    static func avTags(_ url: URL, wantArtwork: Bool) async -> Tags {
        var tags = Tags()
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return tags }
        for item in items {
            if item.commonKey == .commonKeyArtwork {
                if wantArtwork, tags.artwork == nil { tags.artwork = try? await item.load(.dataValue) }
                continue
            }
            let raw = item.identifier?.rawValue ?? ""
            var key = raw.split(separator: "/", maxSplits: 1).last.map(String.init) ?? raw
            key = (key.removingPercentEncoding ?? key).uppercased()

            if key == "TXXX" || key == "TXX" {
                let extra = try? await item.load(.extraAttributes)
                if let info = extra?[.info] as? String { key = info.uppercased() }
            } else if key.contains("REPLAYGAIN"), let dot = key.lastIndex(of: ".") {
                key = String(key[key.index(after: dot)...])
            }

            var normalized = normalizedKey(key)
            if let common = item.commonKey {
                switch common {
                case .commonKeyTitle: normalized = "title"
                case .commonKeyArtist: normalized = "artist"
                case .commonKeyAlbumName: normalized = "album"
                case .commonKeyCreationDate: normalized = "date"
                default: break
                }
            }

            var value = try? await item.load(.stringValue)
            if value == nil, let n = try? await item.load(.numberValue) { value = n.stringValue }
            if value == nil, ["TRKN", "DISK"].contains(key), let d = try? await item.load(.dataValue), d.count >= 6 {
                let b = [UInt8](d)
                let n = Int(b[2]) << 8 | Int(b[3]), total = Int(b[4]) << 8 | Int(b[5])
                value = total > 0 ? "\(n)/\(total)" : "\(n)"
            }
            tags.put(normalized, value)
        }
        return tags
    }

    private static func normalizedKey(_ key: String) -> String {
        switch key.uppercased() {
        case "TIT2", "TT2", "©NAM", "TITLE": "title"
        case "TPE1", "TP1", "©ART", "ARTIST": "artist"
        case "TALB", "TAL", "©ALB", "ALBUM": "album"
        case "TPE2", "TP2", "AART", "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": "albumartist"
        case "TCON", "TCO", "©GEN", "GENRE": "genre"
        case "TRCK", "TRK", "TRKN", "TRACKNUMBER", "TRACK": "track"
        case "TPOS", "TPA", "DISK", "DISCNUMBER", "DISC": "disc"
        case "TYER", "TYE", "TDRC", "TDOR", "©DAY", "DATE", "YEAR": "date"
        case "USLT", "ULT", "©LYR", "LYRICS", "UNSYNCEDLYRICS", "UNSYNCED LYRICS": "lyrics"
        case "CUESHEET": "cuesheet"
        case let k where k.hasPrefix("LYRICS"): "lyrics"
        default: key.lowercased()
        }
    }

    private static func cleanGenre(_ g: String) -> String {
        // "(17)" "(17)Rock" のような ID3v1 番号表記を整える
        let stripped = g.replacingOccurrences(of: #"^\(\d+\)"#, with: "", options: .regularExpression)
        return stripped.nilIfBlank ?? g
    }

    private static func leadingInt(_ s: String) -> Int? {
        Int(s.prefix { $0.isNumber })
    }

    private static func leadingDouble(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let r = t.range(of: #"^[+-]?\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(t[r])
    }

    // MARK: - アートワーク

    static func artwork(for track: Track) async -> NSImage? {
        if let data = await artworkData(track.url), let img = NSImage(data: data) { return img }
        if let folder = track.folderArtURL, let img = NSImage(contentsOf: folder) { return img }
        return nil
    }

    static func artworkData(_ url: URL) async -> Data? {
        if (try? AVAudioFile(forReading: url)) != nil {
            if let d = await avTags(url, wantArtwork: true).artwork { return d }
            if let d = flacPicture(url) { return d }
        }
        return await FFmpeg.extractCover(url)
    }

    /// FLAC の METADATA_BLOCK_PICTURE を直接読む (AVFoundation は FLAC の画像を返さないため)
    static func flacPicture(_ url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        func read(_ n: Int) -> [UInt8]? {
            guard let d = try? h.read(upToCount: n), d.count == n else { return nil }
            return [UInt8](d)
        }
        func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) << 24 | Int(b[o + 1]) << 16 | Int(b[o + 2]) << 8 | Int(b[o + 3]) }

        guard var head = read(4) else { return nil }
        if head[0...2] == [0x49, 0x44, 0x33] { // ID3v2 が前置されている
            guard let rest = read(6) else { return nil }
            let size = Int(rest[2]) << 21 | Int(rest[3]) << 14 | Int(rest[4]) << 7 | Int(rest[5])
            try? h.seek(toOffset: UInt64(10 + size))
            guard let h2 = read(4) else { return nil }
            head = h2
        }
        guard head == [0x66, 0x4C, 0x61, 0x43] else { return nil } // "fLaC"

        var fallback: Data?
        while let bh = read(4) {
            let last = bh[0] & 0x80 != 0, type = bh[0] & 0x7F
            let len = Int(bh[1]) << 16 | Int(bh[2]) << 8 | Int(bh[3])
            if type == 6, let b = read(len), b.count >= 32 {
                let picType = u32(b, 0)
                var o = 4
                o += 4 + u32(b, o) // mime
                o += 4 + u32(b, o) // description
                o += 16
                guard o + 4 <= b.count else { break }
                let dlen = u32(b, o)
                o += 4
                guard o + dlen <= b.count else { break }
                let data = Data(b[o..<(o + dlen)])
                if picType == 3 { return data }
                if fallback == nil { fallback = data }
            } else {
                guard let off = try? h.offset() else { break }
                try? h.seek(toOffset: off + UInt64(len))
            }
            if last { break }
        }
        return fallback
    }

    // MARK: - 歌詞

    static func embeddedLyrics(_ url: URL) async -> String? {
        if (try? AVAudioFile(forReading: url)) != nil {
            return await avTags(url, wantArtwork: false)["lyrics"]
        }
        guard FFmpeg.isAvailable, let probe = try? await FFmpeg.probe(url) else { return nil }
        return probe.tags.first { normalizedKey($0.key) == "lyrics" }?.value
    }
}
