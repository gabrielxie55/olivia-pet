import AppKit
import ImageIO
// 生成 README 顶部的预览图：几张表情包贴纸站成一排 + 标题
let out = CommandLine.arguments[1]
let W: CGFloat = 1600, H: CGFloat = 900
func img(_ p: String) -> CGImage {
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
NSGradient(starting: NSColor(srgbRed: 0.93, green: 0.88, blue: 1, alpha: 1), ending: NSColor(srgbRed: 1, green: 0.9, blue: 0.95, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// 贴纸：名字、显示高度（和桌宠里的比例差不多）
let floorY: CGFloat = 70
let stickers: [(String, CGFloat)] = [("meme1", 560), ("meme4", 470), ("cute3", 420), ("cute4", 500), ("meme3", 400), ("cute1", 300)]
let items = stickers.map { name, h -> (CGImage, CGFloat, CGFloat) in
    let i = img("assets/\(name)/frames/000.png")
    return (i, h * CGFloat(i.width) / CGFloat(i.height), h)
}
let gap: CGFloat = -18
let raw = items.map(\.1).reduce(0, +) + gap * CGFloat(items.count - 1)
let k = min(1, (W - 100) / raw)        // 排不下就整体缩小
var x = (W - raw * k) / 2
for (i, w, h) in items {
    ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: CGColor(gray: 0, alpha: 0.18))
    ctx.draw(i, in: CGRect(x: x, y: floorY, width: w * k, height: h * k))
    x += (w + gap) * k
}
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// 标题
let size: CGFloat = 78
let font = NSFont.systemFont(ofSize: size, weight: .black).fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? NSFont.boldSystemFont(ofSize: size)
let text = "Olivia 桌宠"
let tw = NSAttributedString(string: text, attributes: [.font: font]).size().width
let at = NSPoint(x: W / 2 - tw / 2, y: H - 150)
NSAttributedString(string: text, attributes: [.font: font, .strokeColor: NSColor(srgbRed: 0.35, green: 0.15, blue: 0.5, alpha: 1), .strokeWidth: 24]).draw(at: at)
NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white]).draw(at: at)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
