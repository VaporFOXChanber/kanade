import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Kanade

/// 確認用のフォルダを作る。パスの末尾が画像なら指定の大きさの画像を、それ以外は空のファイルを置く
private func makeTree(_ files: [String: (Int, Int)?]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kanade-art-\(UUID().uuidString)")
    for (path, size) in files {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let (width, height) = size {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let image = try #require(context.makeImage())
            let type = url.pathExtension == "png" ? UTType.png : UTType.jpeg
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        } else {
            try Data().write(to: url)
        }
    }
    return root
}

private func found(_ root: URL, _ audio: String) -> String? {
    ArtworkFinder.clearCache()
    guard let url = ArtworkFinder.find(for: root.appendingPathComponent(audio)) else { return nil }
    return String(url.path.dropFirst(root.path.count + 1))
}

@Suite("作品のフォルダとアートワーク探し", .serialized)
struct ArtworkFinderTests {
    @Test("名前から作品番号を取り出す", arguments: [
        ("RJ01234567 タイトル", "RJ01234567"), ("[rj123456] 作品", "RJ123456"), ("作品_VJ012345", "VJ012345"),
        ("RJ1234567", nil), ("PROJ123456", nil), ("タイトルだけ", nil),
    ] as [(String, String?)])
    func workCodes(name: String, code: String?) {
        #expect(ArtworkFinder.workCode(inName: name) == code)
    }

    @Test("作品番号は、ファイル名か上のフォルダ名から近い順に探す")
    func workCodeFromPath() {
        #expect(ArtworkFinder.workCode(for: URL(fileURLWithPath: "/lib/RJ01234567 作品/mp3/本編/01.mp3")) == "RJ01234567")
        #expect(ArtworkFinder.workCode(for: URL(fileURLWithPath: "/lib/RJ111111/x/RJ222222_01.mp3")) == "RJ222222")
        #expect(ArtworkFinder.workCode(for: URL(fileURLWithPath: "/lib/作品/01.mp3")) == nil)
    }

    @Test("作品の一部を表すフォルダ名を見分ける", arguments: [
        ("mp3", true), ("WAV", true), ("mp3版", true), ("WAV（SEなし）", true), ("01_本編", true), ("Disc 2", true),
        ("24bit_96kHz", true), ("おまけ", true), ("音声", true), ("SE有り", true), ("ハイレゾ FLAC", true),
        ("同人音声", false), ("【耳かき音声】ゆったり", false), ("2023", false), ("Abbey Road", false), ("耳かき", false),
    ])
    func partFolders(name: String, isPart: Bool) {
        #expect(ArtworkFinder.isPartFolder(name) == isPart)
    }

    @Test("作品のフォルダ: 作品番号のあるフォルダまで、なければ「mp3」「本編」のようなフォルダだけをさかのぼる")
    func workFolders() {
        func folder(_ path: String) -> String { ArtworkFinder.workFolder(for: URL(fileURLWithPath: path)).path }
        #expect(folder("/lib/x/RJ01234567 作品/タイトル/パート1/01.mp3") == "/lib/x/RJ01234567 作品")
        #expect(folder("/lib/x/作品/mp3/本編/01.mp3") == "/lib/x/作品")
        #expect(folder("/lib/x/アーティスト/アルバム/01.mp3") == "/lib/x/アーティスト/アルバム")
        #expect(folder("/lib/x/作品/01.mp3") == "/lib/x/作品")
        // ホームや「ミュージック」の直下までは、さかのぼらない
        let music = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        #expect(folder(music.appendingPathComponent("mp3/01.mp3").path) == music.appendingPathComponent("mp3").path)
    }

    @Test("音源が「mp3」フォルダにある作品: 作品のフォルダ直下のジャケットを選ぶ")
    func picksJacketInWorkFolder() throws {
        let root = try makeTree([
            "RJ01234567 作品/mp3/01.mp3": nil, "RJ01234567 作品/wav/01.wav": nil,
            "RJ01234567 作品/ジャケット.jpg": (800, 800), "RJ01234567 作品/画像/イラスト1.png": (1000, 1000),
            "RJ01234567 作品/台本/台本.png": (800, 1100), "RJ01234567 作品/readme.txt": nil,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(found(root, "RJ01234567 作品/mp3/01.mp3") == "RJ01234567 作品/ジャケット.jpg")
        #expect(found(root, "RJ01234567 作品/wav/01.wav") == "RJ01234567 作品/ジャケット.jpg")
    }

    @Test("それらしい名前の画像がなければ、画像のフォルダの中から選ぶ (台本より絵を優先)")
    func picksFromImageFolder() throws {
        let root = try makeTree([
            "作品/01_本編/01.mp3": nil, "作品/台本/台本1.png": (800, 1100),
            "作品/イラスト/a.png": (1000, 1000), "作品/イラスト/b.png": (1000, 1000),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(found(root, "作品/01_本編/01.mp3") == "作品/イラスト/a.png")
    }

    @Test("同じフォルダの cover を最優先し、文字なし版や細長い画像は避ける")
    func prefersCoverAndAvoidsOddImages() throws {
        let album = try makeTree([
            "album/01.mp3": nil, "album/back.jpg": (800, 800), "album/cover.jpg": (800, 800), "album/scans/01.jpg": (800, 800),
        ])
        defer { try? FileManager.default.removeItem(at: album) }
        #expect(found(album, "album/01.mp3") == "album/cover.jpg")

        let variants = try makeTree([
            "作品/mp3/01.mp3": nil, "作品/ジャケット_文字なし.png": (800, 800), "作品/ジャケット.png": (800, 800),
        ])
        defer { try? FileManager.default.removeItem(at: variants) }
        #expect(found(variants, "作品/mp3/01.mp3") == "作品/ジャケット.png")

        let banner = try makeTree([
            "作品/mp3/01.mp3": nil, "作品/main_banner.png": (1200, 200), "作品/絵.png": (900, 900), "作品/icon.png": (64, 64),
        ])
        defer { try? FileManager.default.removeItem(at: banner) }
        #expect(found(banner, "作品/mp3/01.mp3") == "作品/絵.png")
    }

    @Test("ほかの作品やほかのアルバムの画像は使わない")
    func ignoresOtherWorks() throws {
        let root = try makeTree([
            "lib/作品A/01.mp3": nil, "lib/作品B/01.mp3": nil, "lib/作品B/cover.jpg": (800, 800),
            "lib/アーティスト/アルバム1/01.mp3": nil, "lib/アーティスト/アルバム2/01.mp3": nil, "lib/アーティスト/アルバム2/cover.jpg": (800, 800),
            "lib/まとめ/loose.mp3": nil, "lib/まとめ/別の作品/01.mp3": nil, "lib/まとめ/別の作品/cover.jpg": (800, 800),
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(found(root, "lib/作品A/01.mp3") == nil)
        #expect(found(root, "lib/アーティスト/アルバム1/01.mp3") == nil)
        #expect(found(root, "lib/まとめ/loose.mp3") == nil)
        #expect(found(root, "lib/作品B/01.mp3") == "lib/作品B/cover.jpg")
    }

    @Test("手動で指定するアートワークの範囲: 作品のフォルダごと。ばらの曲が並ぶフォルダではアルバム名でも分ける")
    func workKeys() {
        func track(_ path: String, album: String? = nil) -> Track {
            var t = Track(url: URL(fileURLWithPath: path))
            t.meta.album = album
            return t
        }
        // 同じ作品なら、形式の違うフォルダでも、タグの有無が違っても同じ
        #expect(ArtworkFinder.workKey(for: track("/lib/x/RJ123456/mp3/01.mp3", album: "作品"))
            == ArtworkFinder.workKey(for: track("/lib/x/RJ123456/wav/01.wav")))
        #expect(ArtworkFinder.workKey(for: track("/lib/x/作品/mp3/01.mp3")) == ArtworkFinder.workKey(for: track("/lib/x/作品/本編/02.mp3")))
        // 1 つのフォルダに別々のアルバムの曲が並んでいるとき
        #expect(ArtworkFinder.workKey(for: track("/lib/x/まとめ/a.mp3", album: "A")) != ArtworkFinder.workKey(for: track("/lib/x/まとめ/b.mp3", album: "B")))
        #expect(ArtworkFinder.workKey(for: track("/lib/x/作品A/01.mp3")) != ArtworkFinder.workKey(for: track("/lib/x/作品B/01.mp3")))
    }
}

@Suite("DLsite の作品画像")
struct DLsiteArtworkTests {
    @Test("作品情報から画像の URL を取り出す")
    func imageURLFromInfo() throws {
        let info = #"{"RJ299717":{"site_id":"home","work_name":"x","work_image":"\/\/img.dlsite.jp\/modpub\/images2\/work\/doujin\/RJ300000\/RJ299717_img_main.jpg"}}"#
        #expect(DLsiteArtwork.imageURL(fromInfo: Data(info.utf8), code: "RJ299717")?.absoluteString
            == "https://img.dlsite.jp/modpub/images2/work/doujin/RJ300000/RJ299717_img_main.jpg")
    }

    @Test("画像のない作品、見つからない作品、よそのサーバーを指す応答は使わない")
    func rejectsUnusableInfo() {
        let noImage = #"{"RJ01100000":{"work_image":"\/\/www.dlsite.com\/images\/web\/home\/no_img_main.gif"}}"#
        #expect(DLsiteArtwork.imageURL(fromInfo: Data(noImage.utf8), code: "RJ01100000") == nil)
        #expect(DLsiteArtwork.imageURL(fromInfo: Data("[]".utf8), code: "RJ01000001") == nil)
        let elsewhere = #"{"RJ123456":{"work_image":"https:\/\/example.com\/a.jpg"}}"#
        #expect(DLsiteArtwork.imageURL(fromInfo: Data(elsewhere.utf8), code: "RJ123456") == nil)
        let other = #"{"RJ999999":{"work_image":"\/\/img.dlsite.jp\/a.jpg"}}"#
        #expect(DLsiteArtwork.imageURL(fromInfo: Data(other.utf8), code: "RJ123456") == nil)
    }

    @Test("番号から組み立てる URL: フォルダは 1000 単位に切り上げる", arguments: [
        ("RJ299717", "doujin/RJ300000/RJ299717_img_main.jpg"),
        ("RJ01234567", "doujin/RJ01235000/RJ01234567_img_main.jpg"),
        ("RJ01234000", "doujin/RJ01234000/RJ01234000_img_main.jpg"),
        ("VJ012345", "professional/VJ013000/VJ012345_img_main.jpg"),
    ])
    func fallbackURL(code: String, tail: String) {
        #expect(DLsiteArtwork.fallbackImageURL(code: code)?.absoluteString == "https://img.dlsite.jp/modpub/images2/work/" + tail)
    }
}
