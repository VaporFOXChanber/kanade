// VU メーターの目盛り板 (アプリの針と同じ幾何: 支点 = (W/2, 1.2H)、目盛り半径 0.9H、振れ幅 ±44°)
//   swift art/make-vu-face.swift art/textures/vu-face.png
import AppKit

let out = CommandLine.arguments[1]
let W = 1680.0, H = 1000.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
// 左上原点に
ctx.translateBy(x: 0, y: H)
ctx.scaleBy(x: 1, y: -1)

// 紙の地色と、下から照らすバックライトのむら
let cream = CGColor(red: 0.97, green: 0.92, blue: 0.78, alpha: 1)
ctx.setFillColor(cream)
ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [CGColor(red: 1, green: 0.95, blue: 0.8, alpha: 1), CGColor(red: 0.86, green: 0.76, blue: 0.56, alpha: 1)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: W / 2, y: H * 0.95), startRadius: 0,
                       endCenter: CGPoint(x: W / 2, y: H * 0.95), endRadius: H * 1.25, options: [.drawsAfterEndLocation])

let pivot = CGPoint(x: W / 2, y: H * 1.2)
let rs = H * 0.9
let sweep = 44.0 * .pi / 180
func pt(_ f: Double, _ r: Double) -> CGPoint {
    let a = sweep * (2 * f - 1)
    return CGPoint(x: pivot.x + r * sin(a), y: pivot.y - r * cos(a))
}
func frac(_ db: Double) -> Double { pow(10, (db - 3) / 20) }
let ink = CGColor(red: 0.08, green: 0.07, blue: 0.06, alpha: 1)
let red = CGColor(red: 0.78, green: 0.13, blue: 0.1, alpha: 1)

func arc(_ f0: Double, _ f1: Double, _ r: Double, _ width: Double, _ color: CGColor) {
    ctx.setStrokeColor(color)
    ctx.setLineWidth(width)
    ctx.setLineCap(.butt)
    for i in 0...120 {
        let p = pt(f0 + (f1 - f0) * Double(i) / 120, r)
        i == 0 ? ctx.move(to: p) : ctx.addLine(to: p)
    }
    ctx.strokePath()
}
arc(frac(-20), frac(0), rs, 5, ink)
arc(frac(0), 1.0, rs + 10, 26, red)
// 下側の細い % 目盛り
arc(frac(-20), 1.0, rs - 70, 3, ink)

func label(_ s: String, at p: CGPoint, size: Double, color: CGColor, weight: NSFont.Weight = .semibold, serif: Bool = false) {
    let font = serif ? NSFont(name: "Didot-Bold", size: size)! : NSFont.systemFont(ofSize: size, weight: weight)
    let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: color)!])
    let sz = a.size()
    // 反転した座標系でも正しく描けるように一時的に戻す
    ctx.saveGState()
    ctx.translateBy(x: p.x, y: p.y)
    ctx.scaleBy(x: 1, y: -1)
    a.draw(at: CGPoint(x: -sz.width / 2, y: -sz.height / 2))
    ctx.restoreGState()
}

for db in [-20.0, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3] {
    let f = frac(db)
    ctx.setStrokeColor(db > 0 ? red : ink)
    ctx.setLineWidth(6)
    ctx.move(to: pt(f, rs))
    ctx.addLine(to: pt(f, rs + 60))
    ctx.strokePath()
    label(db > 0 ? "+\(Int(db))" : "\(Int(abs(db)))", at: pt(f, rs + 118), size: 64, color: db > 0 ? red : ink)
}
// 小目盛り
for i in 0...20 {
    let f = frac(-20) + (1 - frac(-20)) * Double(i) / 20
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(3)
    ctx.move(to: pt(f, rs - 70))
    ctx.addLine(to: pt(f, rs - 45))
    ctx.strokePath()
}
label("VU", at: CGPoint(x: W / 2, y: H * 0.56), size: 150, color: ink, serif: true)
label("KANADE", at: CGPoint(x: W / 2, y: H * 0.7), size: 38, color: CGColor(red: 0.3, green: 0.27, blue: 0.22, alpha: 1), weight: .bold)
label("−", at: CGPoint(x: W * 0.12, y: H * 0.18), size: 70, color: ink)
label("+", at: CGPoint(x: W * 0.88, y: H * 0.18), size: 70, color: red)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
