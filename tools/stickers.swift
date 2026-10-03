import AppKit
import Vision
import CoreImage

// 把表情包照片抠成带白边的贴纸
// 用法：stickers <照片> <输出目录> <输出高度>
// 输出 frames/000.png（只有一帧的「动画」，和视频素材同一个格式）+ mask.bin
// 她被照片底边切掉的话（半身照），底边不加白边，桌宠会贴着屏幕底边「冒出来」

let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let outDir = URL(fileURLWithPath: args[2])
let outHeight = Double(args[3])!
let W = src.width, H = src.height

// MARK: 抠图

let handler = VNImageRequestHandler(cgImage: src)
let req = VNGenerateForegroundInstanceMaskRequest()
try! handler.perform([req])
let obs = req.results!.first!
let maskPB = try! obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
var alpha = [Float](repeating: 0, count: W * H)
CVPixelBufferLockBaseAddress(maskPB, .readOnly)
do {
    let bpr = CVPixelBufferGetBytesPerRow(maskPB), base = CVPixelBufferGetBaseAddress(maskPB)!
    let isFloat = CVPixelBufferGetPixelFormatType(maskPB) == kCVPixelFormatType_OneComponent32Float
    for y in 0..<H {
        let row = base + y * bpr
        for x in 0..<W { alpha[y * W + x] = isFloat ? row.assumingMemoryBound(to: Float.self)[x] : Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255 }
    }
}
CVPixelBufferUnlockBaseAddress(maskPB, .readOnly)
// 往里收两像素再柔化：去掉背景色透出来的一圈杂边
alpha = boxBlur(minFilter(alpha, W, H, 2), W, H, 1)

var minX = W, maxX = 0, minY = H, maxY = 0
for y in 0..<H { for x in 0..<W where alpha[y * W + x] > 0.5 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
let bust = maxY >= H - 8
if bust { maxY = H - 1 }
print("\(args[1]) → \(bust ? "半身" : "全身")，范围 x \(minX)...\(maxX) y \(minY)...\(maxY)")

// MARK: 缩放到输出尺寸，留出白边的位置

let scale = outHeight / Double(maxY - minY + 1)
let border = Int((outHeight * 0.016).rounded())     // 白边粗细
let bodyW = Int(Double(maxX - minX + 1) * scale), bodyH = Int(outHeight)
let fw = bodyW + border * 2 + 2, fh = bodyH + border + 1 + (bust ? 0 : border + 1)
let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

func render(_ img: CIImage) -> [UInt8] {
    // 照片里身体所在的范围 → 输出画布上留了白边之后的位置
    let placed = img
        .cropped(to: CGRect(x: minX, y: H - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1))
        .transformed(by: CGAffineTransform(translationX: CGFloat(-minX), y: CGFloat(-(H - 1 - maxY))))
        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        .transformed(by: CGAffineTransform(translationX: CGFloat(border + 1), y: CGFloat(fh - bodyH - border - 1)))
    var px = [UInt8](repeating: 0, count: fw * fh * 4)
    ci.render(placed, toBitmap: &px, rowBytes: fw * 4, bounds: CGRect(x: 0, y: 0, width: fw, height: fh), format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return px
}
var maskImg = [UInt8](repeating: 0, count: W * H * 4)
for i in 0..<(W * H) { let v = UInt8(alpha[i] * 255); maskImg[i * 4] = v; maskImg[i * 4 + 1] = v; maskImg[i * 4 + 2] = v; maskImg[i * 4 + 3] = 255 }
let maskCG = CGContext(data: &maskImg, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
let color = render(CIImage(cgImage: src))
let body = render(CIImage(cgImage: maskCG)).enumerated().compactMap { $0.offset % 4 == 0 ? Float($0.element) / 255 : nil }

// MARK: 白边：身体往外扩一圈

var outline = [Float](repeating: 0, count: fw * fh)
let r = Float(border)
var offsets: [(Int, Int, Float)] = []
for dy in -border - 1...border + 1 { for dx in -border - 1...border + 1 {
    let d = hypot(Float(dx), Float(dy))
    if d <= r + 1 { offsets.append((dx, dy, min(1, r + 1 - d))) }    // 最外一圈半透明，边缘不起锯齿
} }
for y in 0..<fh { for x in 0..<fw {
    let b = body[y * fw + x]
    guard b > 0.5 else { continue }
    for (dx, dy, w) in offsets {
        let qx = x + dx, qy = y + dy
        guard qx >= 0, qx < fw, qy >= 0, qy < fh else { continue }
        outline[qy * fw + qx] = max(outline[qy * fw + qx], w)
    }
} }

var px = [UInt8](repeating: 0, count: fw * fh * 4)
for i in 0..<(fw * fh) {
    let a = body[i], o = outline[i]
    let outA = a + o * (1 - a)
    guard outA > 0.004 else { continue }
    for c in 0..<3 { px[i * 4 + c] = UInt8(min(255, Float(color[i * 4 + c]) * a + 255 * o * (1 - a))) }
    px[i * 4 + 3] = UInt8(outA * 255)
}

let framesDir = outDir.appendingPathComponent("frames")
try? FileManager.default.removeItem(at: outDir)
try! FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
let ctx = CGContext(data: &px, width: fw, height: fh, bitsPerComponent: 8, bytesPerRow: fw * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: framesDir.appendingPathComponent("000.png"))

let ms = 4, mw = fw / ms, mh = fh / ms
var mask = Data()
for v in [UInt32(mw), UInt32(mh), UInt32(1)] { withUnsafeBytes(of: v.littleEndian) { mask.append(contentsOf: $0) } }
for y in 0..<mh { for x in 0..<mw {
    var best: UInt8 = 0
    for dy in 0..<ms { for dx in 0..<ms { best = max(best, px[((y * ms + dy) * fw + x * ms + dx) * 4 + 3]) } }
    mask.append(best)
} }
try! mask.write(to: outDir.appendingPathComponent("mask.bin"))
print("贴纸 \(fw)x\(fh) 已写入 \(outDir.path)")
