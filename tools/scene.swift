import AVFoundation
import AppKit
import Vision
import CoreImage

// 把一整段名场面视频做成透明背景的逐帧动画（不剪短，按 30fps 输出）
// - 用 Vision 的「主体识别」逐帧找出画面里的主体，跟踪她本人：同一个镜头里跟着上一帧走，镜头切换后按「像不像她」重新找
// - 镜头远近不一样时，按脸的大小把她缩放到同样大小；全身镜头脚踩地面，半身镜头被切断的那条线贴着地面
// - 可选：把原视频的字幕单独抠出来（--subs），或者把字幕直接留在她身上（--keep-captions）
//
// 用法：scene <视频> <输出目录> [选项]
//   --crop x,y,w,h          只看画面里这一块（去掉黑边、字幕条），y 从顶部算
//   --subs x,y,w,h          字幕条的位置：字幕单独抠出来，放在她脚下
//   --keep-captions y       她身上的字幕框（黑底字幕）也算她的一部分，只找这条线以下的（按 --crop 后的比例算）
//   --with-props            和她挨在一起的东西（比如话筒架）也留着
//   --exclude x0,y0,x1,y1@a-b 第 a 到 b 帧这块区域不要（按 --crop 后的比例算）
//   --freeze-from n         第 n 帧起定格
//   --raw-from n            第 n 帧起直接放原画面（不抠图，四周淡出）
//   --patch x0,y0,x1,y1     用正下方的画面盖住这块（去水印）
//   --max-height px         输出画布最高多少像素（默认 820）
// 输出：frames/*.heic、mask.bin、audio.m4a、meta.json（画布大小、镜头切换点、字幕）

let args = CommandLine.arguments
let videoURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
func opt(_ name: String) -> String? { args.firstIndex(of: name).map { args[$0 + 1] } }
func rect(_ s: String) -> CGRect { let v = s.split(separator: ",").map { Double($0)! }; return CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) }
let withProps = args.contains("--with-props")
let captionLine = opt("--keep-captions").map { Double($0)! }
let subsRect = opt("--subs").map(rect)
let exclude: (CGRect, ClosedRange<Int>)? = opt("--exclude").map { s in
    let p = s.split(separator: "@"), v = p[0].split(separator: ",").map { Double($0)! }
    let f = p[1].split(separator: "-").map { Int($0)! }
    return (CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]), f[0]...(f.count > 1 ? f[1] : Int.max))
}
// --freeze-from n：第 n 帧起画面定格在前一帧（VMA 砸玻璃之后是一片碎玻璃，桌宠上改成「屏幕被砸裂」的特效）
let freezeFrom = opt("--freeze-from").map { Int($0)! }
// --raw-from n：第 n 帧起不抠图，直接放原画面（四周柔和地淡出），比如 VMA 最后那段碎玻璃特写
let rawFrom = opt("--raw-from").map { Int($0)! }
// --patch x0,y0,x1,y1：用正下方同样大小的一块盖住这里（去掉压在她身上的水印），按 --crop 后的比例算
let patch = opt("--patch").map { s -> CGRect in let v = s.split(separator: ",").map { Double($0)! }; return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1]) }
let maxHeight = Double(opt("--max-height") ?? "820")!
let outFPS = 30.0

let asset = AVURLAsset(url: videoURL)
func wait(_ body: @escaping () async throws -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { try await body(); sem.signal() }
    sem.wait()
}
var displaySize = CGSize.zero, duration = 0.0
wait {
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let size = try await track.load(.naturalSize), t = try await track.load(.preferredTransform)
    let r = CGRect(origin: .zero, size: size).applying(t)
    displaySize = CGSize(width: abs(r.width), height: abs(r.height))
    duration = try await asset.load(.duration).seconds
}
let crop = opt("--crop").map(rect) ?? CGRect(origin: .zero, size: displaySize)
let cropW = Int(crop.width), cropH = Int(crop.height)
let frameCount = Int(duration * outFPS)
let workScale = min(1, 900 / Double(max(cropW, cropH)))
let workW = Int(Double(cropW) * workScale), workH = Int(Double(cropH) * workScale)
let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
print("视频 \(Int(displaySize.width))x\(Int(displaySize.height))，\(String(format: "%.2f", duration)) 秒 → 输出 \(frameCount) 帧")

/// 按 30fps 依次读出整段视频（已经转正方向），每个输出帧交给 body：(输出帧号, 原视频帧号, 画面)
func eachFrame(_ body: (Int, Int, CIImage) -> Void) {
    var reader: AVAssetReader!
    var output: AVAssetReaderVideoCompositionOutput!
    wait {
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let comp = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
        reader = try AVAssetReader(asset: asset)
        output = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = comp
        reader.add(output)
        reader.startReading()
    }
    var k = 0, source = -1
    var pending: (CVPixelBuffer, Double)?
    func emit(_ pb: CVPixelBuffer, until limit: Double) {
        while k < frameCount && Double(k) / outFPS < limit {
            body(k, source, CIImage(cvPixelBuffer: pb))
            k += 1
        }
    }
    while let sb = output.copyNextSampleBuffer() {
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
        let t = CMSampleBufferGetPresentationTimeStamp(sb).seconds
        if let (prev, pt) = pending { emit(prev, until: (pt + t) / 2) }     // 离哪一帧近就用哪一帧
        source += 1
        pending = (pb, t)
    }
    if let (prev, _) = pending { emit(prev, until: .infinity) }
}

/// 视频画面（CoreImage 坐标，原点在左下）→ 裁好的区域，原点挪到裁切框左下角
func cropped(_ img: CIImage) -> CIImage {
    let c = img.cropped(to: CGRect(x: crop.minX, y: displaySize.height - crop.maxY, width: crop.width, height: crop.height))
        .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -(displaySize.height - crop.maxY)))
    guard let p = patch else { return c }
    // CoreImage 坐标：y 从底部算，「正下方」就是 y 更小的那一块
    let r = CGRect(x: p.minX * crop.width, y: (1 - p.maxY) * crop.height, width: p.width * crop.width, height: p.height * crop.height)
    let below = c.cropped(to: r.offsetBy(dx: 0, dy: -r.height)).transformed(by: CGAffineTransform(translationX: 0, y: r.height))
    return below.composited(over: c)
}

func render(_ img: CIImage, _ w: Int, _ h: Int) -> [UInt8] {
    var px = [UInt8](repeating: 0, count: w * h * 4)
    ci.render(img, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: sRGB)
    return px
}

// MARK: 第一遍：逐帧找她

struct FrameInfo {
    var mask: [UInt8] = []                 // 工作分辨率下的 alpha
    var present = false
    var box = CGRect.zero                  // 她在裁切区域里的范围（像素，y 从顶部算）
    var face: CGFloat?                     // 脸的高度（像素）
    var cx: CGFloat = 0                    // 身体重心的 x
    var lumaCut = false                    // 和上一帧比，画面整个变了（镜头切换）
    var thumb: [Float] = []                // 亮度归一化的缩略图（判断渐变转场用）
}
var info = [FrameInfo](repeating: FrameInfo(), count: frameCount)
var prevLabelsMask: [Bool]?                // 上一帧她在 Vision 低清标签图上的位置
var appearance: [Float]?                   // 她的颜色分布（镜头切换后靠这个认人）
var prevThumb: [Float]?
var cache: (source: Int, info: FrameInfo)?

/// 一块区域的颜色分布：RGB 各分 4 档，共 64 格
func histogram(_ px: [UInt8], _ w: Int, _ pixels: [Int]) -> [Float] {
    var h = [Float](repeating: 0, count: 64)
    for p in pixels { h[Int(px[p * 4]) / 64 * 16 + Int(px[p * 4 + 1]) / 64 * 4 + Int(px[p * 4 + 2]) / 64] += 1 }
    let s = max(1, h.reduce(0, +))
    return h.map { $0 / s }
}
func similarity(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).map { min($0, $1) }.reduce(0, +) }

eachFrame { k, source, full in
    if let f = freezeFrom, k >= f { return }
    if let f = rawFrom, k >= f { return }
    if let c = cache, c.source == source { info[k] = c.info; info[k].lumaCut = false; return }
    var fi = FrameInfo()
    let img = cropped(full).transformed(by: CGAffineTransform(scaleX: workScale, y: workScale))
    let px = render(img, workW, workH)

    // 镜头切换：亮度归一化后的缩略图差别很大（舞台灯闪不算）
    var thumb = [Float](repeating: 0, count: 32 * 32)
    for ty in 0..<32 { for tx in 0..<32 {
        let p = ((ty * workH / 32) * workW + tx * workW / 32) * 4
        thumb[ty * 32 + tx] = Float(px[p]) + Float(px[p + 1]) + Float(px[p + 2])
    } }
    let mean = thumb.reduce(0, +) / Float(thumb.count)
    let sd = max(1, (thumb.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(thumb.count)).squareRoot())
    thumb = thumb.map { ($0 - mean) / sd }
    if let pt = prevThumb { fi.lumaCut = zip(thumb, pt).map { abs($0 - $1) }.reduce(0, +) / Float(thumb.count) > 0.6 }
    prevThumb = thumb
    fi.thumb = thumb

    let handler = VNImageRequestHandler(ciImage: img)
    let req = VNGenerateForegroundInstanceMaskRequest()
    let faceReq = VNDetectFaceRectanglesRequest()
    let textReq = VNDetectTextRectanglesRequest()
    let peopleReq = VNGeneratePersonInstanceMaskRequest()
    try? handler.perform(captionLine != nil ? [req, faceReq, textReq, peopleReq] : [req, faceReq, peopleReq])
    defer { info[k] = fi; cache = (source, fi) }
    guard let obs = req.results?.first, !obs.allInstances.isEmpty else { prevLabelsMask = nil; return }

    // Vision 的低清标签图：每个像素是 0（背景）或第几个主体
    let lm = obs.instanceMask
    CVPixelBufferLockBaseAddress(lm, .readOnly)
    let lw = CVPixelBufferGetWidth(lm), lh = CVPixelBufferGetHeight(lm), lbpr = CVPixelBufferGetBytesPerRow(lm)
    let lbase = CVPixelBufferGetBaseAddress(lm)!.assumingMemoryBound(to: UInt8.self)
    var labels = [UInt8](repeating: 0, count: lw * lh)
    for y in 0..<lh { for x in 0..<lw { labels[y * lw + x] = lbase[y * lbpr + x] } }
    CVPixelBufferUnlockBaseAddress(lm, .readOnly)

    let faces = (faceReq.results ?? []).map { f -> CGRect in
        let b = f.boundingBox
        return CGRect(x: b.minX * Double(lw), y: (1 - b.maxY) * Double(lh), width: b.width * Double(lw), height: b.height * Double(lh))
    }
    var members: [Int: [Int]] = [:]
    for p in labels.indices where labels[p] > 0 { members[Int(labels[p]), default: []].append(p) }
    func workPixels(_ ps: [Int]) -> [Int] { ps.map { p in (p / lw * workH / lh) * workW + (p % lw) * workW / lw } }

    var chosen: [Int] = []
    let overlap = members.mapValues { ps in prevLabelsMask.map { m in ps.filter { m.count == labels.count && m[$0] }.count } ?? 0 }
    // 舞台灯一闪也会被当成换镜头，所以只要和上一帧重叠够多，就还是跟着上一帧走
    if let best = overlap.max(by: { $0.value < $1.value }), best.value > 0,
       !fi.lumaCut || Double(best.value) > 0.3 * Double(members[best.key]!.count) {
        // 同一个镜头里：和上一帧重叠最多的那个；她被拆成几块时，和上一帧重叠超过一半的块也算她
        chosen = [best.key] + overlap.filter { $0.key != best.key && Double($0.value) > 0.5 * Double(members[$0.key]!.count) }.map(\.key)
    } else {
        // 新镜头：又大、又靠近中间、有脸、颜色像她的那个
        let total = Double(lw * lh)
        let key = members.max { a, b in
            func score(_ e: (key: Int, value: [Int])) -> Double {
                let n = Double(e.value.count)
                let cx = e.value.map { Double($0 % lw) }.reduce(0, +) / n / Double(lw)
                let hasFace = faces.contains { f in e.value.contains { p in f.contains(CGPoint(x: p % lw, y: p / lw)) } }
                let look = appearance.map { Double(similarity($0, histogram(px, workW, workPixels(e.value)))) } ?? 0.5
                return (n / total).squareRoot() * (1 - abs(cx - 0.5)) * (hasFace ? 2 : 1) * (0.3 + look)
            }
            return score(a) < score(b)
        }!.key
        chosen = [key]
    }
    if withProps {
        // 和她挨在一起的东西（话筒、话筒架）也算
        let mine = Set(chosen.flatMap { members[$0]! })
        for (key, ps) in members where !chosen.contains(key) {
            if ps.contains(where: { p in [-2, 2, -2 * lw, 2 * lw].contains { d in mine.contains(p + d) } }) { chosen.append(key) }
        }
    }
    prevLabelsMask = labels.map { chosen.contains(Int($0)) }

    guard let pb = try? obs.generateScaledMaskForImage(forInstances: IndexSet(chosen), from: handler) else { return }
    let maskPx = render(CIImage(cvPixelBuffer: pb), workW, workH)
    var mask = [UInt8](repeating: 0, count: workW * workH)
    for p in mask.indices { mask[p] = maskPx[p * 4] }
    // 伴舞贴着她站时，「主体识别」会把两个人当成一块：用「分人识别」找出别人，从她身上减掉
    if let people = peopleReq.results?.first, people.allInstances.count >= 2 {
        func personMask(_ i: Int) -> [UInt8]? {
            guard let pb = try? people.generateScaledMaskForImage(forInstances: IndexSet(integer: i), from: handler) else { return nil }
            let px = render(CIImage(cvPixelBuffer: pb), workW, workH)
            return (0..<(workW * workH)).map { px[$0 * 4] }
        }
        let masks = people.allInstances.compactMap { i in personMask(i) }
        // 她是脸落在谁身上的那个人；认不出脸就不动
        if let face = faces.max(by: { $0.height < $1.height }) {
            let c = (x: min(workW - 1, Int(face.midX * Double(workW) / Double(lw))), y: min(workH - 1, Int(face.midY * Double(workH) / Double(lh))))
            if let mine = masks.firstIndex(where: { $0[c.y * workW + c.x] > 128 }) {
                for (i, other) in masks.enumerated() where i != mine {
                    for p in mask.indices where other[p] > 100 && masks[mine][p] < 100 {
                        mask[p] = UInt8(Float(mask[p]) * (1 - Float(other[p]) / 255))
                    }
                }
            }
        }
    }
    if let line = captionLine {
        // 她身上的黑底字幕框：找到的每一行字往外扩一圈，整块算进来
        for t in textReq.results ?? [] {
            let b = t.boundingBox
            guard 1 - b.maxY > line else { continue }
            let pad = b.height * 0.35
            let x0 = Int(max(0, b.minX - pad * 0.6) * Double(workW)), x1 = Int(min(1, b.maxX + pad * 0.6) * Double(workW))
            let y0 = Int(max(0, 1 - b.maxY - pad) * Double(workH)), y1 = Int(min(1, 1 - b.minY + pad) * Double(workH))
            for y in y0..<y1 { for x in x0..<x1 { mask[y * workW + x] = 255 } }
        }
    }
    if let (r, frames) = exclude, frames.contains(k) {
        for y in Int(r.minY * Double(workH))..<Int(r.maxY * Double(workH)) { for x in Int(r.minX * Double(workW))..<Int(r.maxX * Double(workW)) { mask[y * workW + x] = 0 } }
    }

    var minX = workW, maxX = 0, minY = workH, maxY = 0, sx = 0.0, n = 0
    var mine: [Int] = []
    for y in 0..<workH { for x in 0..<workW where mask[y * workW + x] > 128 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y); sx += Double(x); n += 1
        mine.append(y * workW + x)
    } }
    guard n > 200 else { return }
    fi.mask = mask
    fi.present = true
    let inv = 1 / workScale
    fi.box = CGRect(x: Double(minX) * inv, y: Double(minY) * inv, width: Double(maxX - minX + 1) * inv, height: Double(maxY - minY + 1) * inv)
    fi.cx = sx / Double(n) * inv
    // 她的脸：和她重叠的人脸里最大的那张
    let herFaces = faces.filter { f in
        let c = CGPoint(x: f.midX * Double(workW) / Double(lw), y: f.midY * Double(workH) / Double(lh))
        return mask[min(workH - 1, Int(c.y)) * workW + min(workW - 1, Int(c.x))] > 128
    }
    if let f = herFaces.max(by: { $0.height < $1.height }) { fi.face = f.height * Double(workH) / Double(lh) * inv }
    let h = histogram(px, workW, mine)
    appearance = appearance.map { a in zip(a, h).map { $0 * 0.9 + $1 * 0.1 } } ?? h
    if k % 60 == 0 { print("第 \(k) 帧：\(members.count) 个主体，脸 \(fi.face.map { String(format: "%.0f", $0) } ?? "无")") }
}

// MARK: 分镜头，算每一帧怎么缩放、放在哪

/// 镜头切换：画面整个变了，或者她的大小、位置突然跳了
var segStart = [Bool](repeating: false, count: frameCount)
segStart[0] = true
var lastPresent: FrameInfo?
for k in 0..<frameCount {
    let f = info[k]
    if f.present, let p = lastPresent {
        // 舞台灯一闪画面也会整个变：所以画面变了、而且她的大小或位置也跟着变了，才算真的换镜头
        let sizeRatio = max(f.box.height / p.box.height, p.box.height / f.box.height)
        let shift = abs(f.cx - p.cx) / Double(cropW)
        let faceRatio = f.face.flatMap { a in p.face.map { b in max(a / b, b / a) } } ?? 1
        if f.lumaCut && (sizeRatio > 1.15 || shift > 0.06 || faceRatio > 1.2) { segStart[k] = true }
        // 画面没怎么变，但她突然变大变小、跳到别处，也是换了镜头
        if sizeRatio > 1.6 || shift > 0.25 || faceRatio > 1.45 { segStart[k] = true }
    } else if f.lumaCut && f.present {
        segStart[k] = true
    }
    if f.present { lastPresent = f }
}
// 渐变转场：一帧一帧看都变得不多，但隔十帧一比，画面全变了、她的大小也差很多
var k2 = 10
while k2 < frameCount {
    let a = info[k2], b = info[k2 - 10]
    if a.present, b.present, !a.thumb.isEmpty, !b.thumb.isEmpty, !segStart[(k2 - 10)...k2].contains(true) {
        let d = zip(a.thumb, b.thumb).map { abs($0 - $1) }.reduce(0, +) / Float(a.thumb.count)
        let ratio = max(a.box.height / b.box.height, b.box.height / a.box.height)
        if d > 0.6 && ratio > 1.5 { segStart[k2 - 5] = true; k2 += 10; continue }
    }
    k2 += 1
}
var segments: [Range<Int>] = []
var s0 = 0
for k in 1..<frameCount where segStart[k] { segments.append(s0..<k); s0 = k }
segments.append(s0..<frameCount)

// MARK: 个别帧突然抠丢（转场的中间、识别失灵）：沿用前一帧

var hold = [Bool](repeating: false, count: frameCount)
// 面积按实心像素数算（转场时只剩一层淡淡的残影，外框可能还很大，但实心的没几个）
let solid: [Double] = info.map { f in f.present ? Double(f.mask.filter { $0 > 128 }.count) : 0 }
var prevMedian = 0.0
for range in segments {
    let typical = median(range.map { solid[$0] }.filter { $0 > 0 }) ?? 0
    if range.count < 24 && prevMedian > 0 && typical < 0.35 * prevMedian {
        // 转场那一小段整段都是残影
        for k in range where k > 0 { hold[k] = true }
        continue
    }
    // 镜头中间突然掉下去的几帧
    for k in range where k > 0 && solid[k] < 0.35 * typical { hold[k] = true }
    prevMedian = typical
}
if let fz = freezeFrom { for k in fz..<frameCount { hold[k] = false } }
if let rf = rawFrom { for k in rf..<frameCount { hold[k] = false } }
for k in 1..<frameCount where hold[k] { info[k].present = false }
print("沿用前一帧的有 \(hold.filter { $0 }.count) 帧")

func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }
let bottomEdge = Double(cropH) - 3 / workScale

// 每帧的相对缩放 r = 1/脸高：同一个镜头里取中位数、整个镜头用同一个值
// （脸转个角度、认出来的框就会大小不一，逐帧缩放的话她会忽大忽小；镜头本身推近拉远则原样保留）
var r = [Double](repeating: 0, count: frameCount)
struct Seg { var range: Range<Int>; var bust: Bool; var cx: Double; var base: Double; var hasFace: Bool }
var segs: [Seg] = []
for range in segments {
    let present = range.filter { info[$0].present }
    let bust = Double(present.filter { info[$0].box.maxY >= bottomEdge }.count) > 0.7 * Double(present.count)
    let cx = median(present.map { info[$0].cx }) ?? Double(cropW) / 2
    let base = bust ? Double(cropH) : (median(present.map { info[$0].box.maxY }) ?? Double(cropH))
    let faces = range.compactMap { info[$0].face.map(Double.init) }
    let hasFace = faces.count >= max(1, present.count / 4)
    if hasFace { let v = 1 / median(faces)!; for k in range { r[k] = v } }
    segs.append(Seg(range: range, bust: bust, cx: cx, base: base, hasFace: hasFace))
}
// 一张脸都没认出来的镜头（甩头、仰头、背对镜头）：多半还是同一个机位，沿用前一个镜头的大小（开头就没脸的用后一个）
for (i, s) in segs.enumerated() where !s.hasFace {
    let donor = segs[..<i].last(where: { $0.hasFace }) ?? segs[(i + 1)...].first(where: { $0.hasFace })
    let v = donor.map { r[$0.range.lowerBound] } ?? 1 / Double(cropH / 6)
    for k in s.range { r[k] = v }
}

// 画布：最常见的脸高保持原分辨率，算出所有帧需要多大的画布
var F = 1 / median(segs.flatMap { s in s.range.filter { info[$0].present }.map { r[$0] } })!
func layout() -> (w: Int, h: Int) {
    var tops: [Double] = [], halfWidths: [Double] = []
    for s in segs { for k in s.range where info[k].present {
        let sc = F * r[k], b = info[k].box
        tops.append((s.base - b.minY) * sc)
        halfWidths.append(max(s.cx - b.minX, b.maxX - s.cx) * sc)
    } }
    tops.sort(); halfWidths.sort()
    let h = tops[min(tops.count - 1, tops.count * 99 / 100)] * 1.03
    let w = min(halfWidths[halfWidths.count * 95 / 100] * 2 * 1.04, h * 1.6)
    return (Int(w.rounded(.up)), Int(h.rounded(.up)))
}
var (CW, CH) = layout()
// 脸部特写按脸的大小缩放会变成底下冒出一个小脑袋，太小了：露出来的部分至少占画布一半高
// （只管真正的特写，也就是脸占了露出部分的四分之一以上；远景里跪下、弯腰变矮是正常的）
for s in segs where s.hasFace && s.bust {
    let present = s.range.filter { info[$0].present }
    let ratios = present.compactMap { k in info[k].face.map { Double($0) / (s.base - info[k].box.minY) } }
    guard let faceShare = median(ratios), faceShare > 0.25,
          let vis = median(present.map { (s.base - info[$0].box.minY) * F * r[$0] }), vis < 0.5 * Double(CH) else { continue }
    let boost = 0.5 * Double(CH) / vis
    for k in s.range { r[k] *= boost }
}
(CW, CH) = layout()
if Double(CH) > maxHeight { F *= maxHeight / Double(CH); (CW, CH) = layout() }
print("分成 \(segs.count) 个镜头（\(segs.map { $0.bust ? "半身" : "全身" }.joined(separator: " "))），画布 \(CW)x\(CH)")

/// 第 k 帧：裁切区域（CoreImage 坐标）→ 画布
func transform(_ k: Int, _ s: Seg) -> CGAffineTransform {
    let sc = F * r[k]
    // 底边：半身镜头是画面底边，全身镜头是脚底（CoreImage 坐标里 y = 裁切高度 - 从顶部算的 y）
    let baseCI = Double(cropH) - s.base
    return CGAffineTransform(translationX: -s.cx, y: -baseCI).concatenating(CGAffineTransform(scaleX: sc, y: sc))
        .concatenating(CGAffineTransform(translationX: Double(CW) / 2, y: 0))
}

// MARK: 第二遍：上色、收边、写文件

let framesDir = outDir.appendingPathComponent("frames")
try? FileManager.default.removeItem(at: outDir)
try! FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
let ms = 4, mw = CW / ms, mh = CH / ms
var maskData = Data()
for v in [UInt32(mw), UInt32(mh), UInt32(frameCount)] { withUnsafeBytes(of: v.littleEndian) { maskData.append(contentsOf: $0) } }
let segOf: [Seg] = (0..<frameCount).map { k in segs.first { $0.range.contains(k) }! }

eachFrame { k, _, full in
    if (freezeFrom.map { k >= $0 } ?? false) || hold[k] {
        let from = hold[k] ? k - 1 : freezeFrom! - 1
        try? FileManager.default.copyItem(at: framesDir.appendingPathComponent(String(format: "%03d.heic", from)),
                                          to: framesDir.appendingPathComponent(String(format: "%03d.heic", k)))
        maskData.append(contentsOf: maskData.suffix(mw * mh))
        return
    }
    let s = segOf[k], f = info[k]
    var a = [Float](repeating: 0, count: CW * CH)
    var color = [UInt8](repeating: 0, count: CW * CH * 4)
    if let rf = rawFrom, k >= rf {
        // 原画面：按画布高度铺满、左右居中，四周 8% 慢慢淡出，像一块玻璃浮在桌面上
        let sc = Double(CH) / Double(cropH), w = Double(cropW) * sc, x0 = (Double(CW) - w) / 2
        color = render(cropped(full).transformed(by: CGAffineTransform(scaleX: sc, y: sc).concatenating(CGAffineTransform(translationX: x0, y: 0))), CW, CH)
        let fx = w * 0.08, fy = Double(CH) * 0.08
        for y in 0..<CH { for x in 0..<CW {
            let dx = min(Double(x) - x0, x0 + w - Double(x)), dy = min(Double(y), Double(CH - 1 - y))
            guard dx > 0 else { continue }
            let t = min(1, dx / fx) * min(1, dy / fy)
            a[y * CW + x] = Float(t * t * (3 - 2 * t))
        } }
    } else if f.present {
        let t = transform(k, s)
        color = render(cropped(full).transformed(by: t), CW, CH)
        var gray = [UInt8](repeating: 0, count: workW * workH * 4)
        for p in 0..<(workW * workH) { gray[p * 4] = f.mask[p]; gray[p * 4 + 3] = 255 }
        let maskCG = CGContext(data: &gray, width: workW, height: workH, bitsPerComponent: 8, bytesPerRow: workW * 4, space: sRGB,
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
        let maskImg = CIImage(cgImage: maskCG).transformed(by: CGAffineTransform(scaleX: 1 / workScale, y: 1 / workScale).concatenating(t))
        let m = render(maskImg.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.6]).cropped(to: CGRect(x: 0, y: 0, width: CW, height: CH)), CW, CH)
        for p in 0..<(CW * CH) { a[p] = Float(m[p * 4]) / 255 }
        a = boxBlur(minFilter(a, CW, CH, 1), CW, CH, 1)
        if s.bust {
            // 半身镜头的底边是被画面切断的，不收边，免得底下出现一条缝
            for x in 0..<CW { for y in (CH - 3)..<CH { a[y * CW + x] = max(a[y * CW + x], a[(CH - 4) * CW + x]) } }
        }
    }
    var px = [UInt8](repeating: 0, count: CW * CH * 4)
    for p in 0..<(CW * CH) where a[p] > 0.01 {
        for c in 0..<3 { px[p * 4 + c] = UInt8(Float(color[p * 4 + c]) * a[p]) }
        px[p * 4 + 3] = UInt8(a[p] * 255)
    }
    let ctx = CGContext(data: &px, width: CW, height: CH, bitsPerComponent: 8, bytesPerRow: CW * 4, space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // HEIC 能带透明通道，体积只有 PNG 的十分之一
    let dest = CGImageDestinationCreateWithURL(framesDir.appendingPathComponent(String(format: "%03d.heic", k)) as CFURL, "public.heic" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
    CGImageDestinationFinalize(dest)
    var m = [UInt8](repeating: 0, count: mw * mh)
    for y in 0..<mh { for x in 0..<mw {
        var best: Float = 0
        for dy in 0..<ms { for dx in 0..<ms { best = max(best, a[(y * ms + dy) * CW + x * ms + dx]) } }
        m[y * mw + x] = UInt8(best * 255)
    } }
    maskData.append(contentsOf: m)
}
try! maskData.write(to: outDir.appendingPathComponent("mask.bin"))
print("帧已写入 \(framesDir.path)")

// MARK: 字幕：只抠字本身（亮色、而且在一句字幕显示的这段时间里不动的像素），再描一圈深色边

var subs: [[String: Int]] = []
var subIndex = [Int](repeating: -1, count: frameCount)
if let band = subsRect {
    let subScale = F * median((0..<frameCount).filter { info[$0].present }.map { r[$0] })!
    let bw = Int(band.width * subScale), bh = Int(band.height * subScale)
    let subsDir = outDir.appendingPathComponent("subs")
    try! FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
    // 先把每一帧的字幕条（缩放后的像素）和字的范围都记下来
    var bandPx = [[UInt8]](repeating: [], count: frameCount)
    var bandBox = [CGRect?](repeating: nil, count: frameCount)
    eachFrame { k, _, full in
        let raw = full.cropped(to: CGRect(x: band.minX, y: displaySize.height - band.maxY, width: band.width, height: band.height))
            .transformed(by: CGAffineTransform(translationX: -band.minX, y: -(displaySize.height - band.maxY)))
        bandPx[k] = render(raw.transformed(by: CGAffineTransform(scaleX: subScale, y: subScale)), bw, bh)
        // 用原始清晰度找字，小字才找得到
        let req = VNDetectTextRectanglesRequest()
        try? VNImageRequestHandler(ciImage: raw).perform([req])
        let boxes = (req.results ?? []).map { b in
            CGRect(x: b.boundingBox.minX * Double(bw), y: (1 - b.boundingBox.maxY) * Double(bh), width: b.boundingBox.width * Double(bw), height: b.boundingBox.height * Double(bh))
        }
        bandBox[k] = boxes.first.map { boxes.dropFirst().reduce($0) { $0.union($1) } }
    }
    /// 一句字幕：字的范围差不多的连续几帧（中间偶尔没认出字的几帧也算进来）
    func same(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b), u = a.union(b)
        return !i.isNull && i.width * i.height >= 0.6 * u.width * u.height
    }
    var k = 0
    while k < frameCount {
        guard let first = bandBox[k] else { k += 1; continue }
        var members = [k], end = k, miss = 0, j = k + 1
        while j < frameCount, miss <= 5 {
            if let b = bandBox[j] {
                if !same(b, first) { break }
                members.append(j); end = j; miss = 0
            } else { miss += 1 }
            j += 1
        }
        k = end + 1
        guard members.count >= 6 else { continue }
        let union = members.compactMap { bandBox[$0] }.reduce(first) { $0.union($1) }
        let x0 = max(0, Int(union.minX) - 40), x1 = min(bw, Int(union.maxX) + 40), y0 = max(0, Int(union.minY) - 6), y1 = min(bh, Int(union.maxY) + 6)
        let w = x1 - x0, h = y1 - y0
        guard w > 4, h > 4 else { continue }
        let frames = members.map { bandPx[$0] }
        var text = [Float](repeating: 0, count: w * h)
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for y in 0..<h { for x in 0..<w {
            let p = ((y + y0) * bw + x + x0) * 4
            let med = (0..<3).map { c in frames.map { Int($0[p + c]) }.sorted()[frames.count / 2] }
            let lums = frames.map { Float($0[p]) * 0.3 + Float($0[p + 1]) * 0.59 + Float($0[p + 2]) * 0.11 }.sorted()
            let lum = lums[lums.count / 2]
            let mad = lums.map { abs($0 - lum) }.sorted()[lums.count / 2]
            let bright = min(1, max(0, (lum - 150) / 40))
            // 字是白色或粉色（蓝 ≥ 绿），背景的地板、墙、皮肤偏黄偏橙（蓝 < 绿）
            let notOrange = min(1, max(0, Float(med[2] - med[0] + 90) / 40))
            let notBeige = min(1, max(0, Float(med[2] - med[1] + 26) / 10))
            let steady = min(1, max(0, (18 - mad) / 10))
            text[y * w + x] = bright * notOrange * notBeige * steady
            for c in 0..<3 { rgb[(y * w + x) * 3 + c] = UInt8(med[c]) }
        } }
        // 深色描边：字往外扩两像素
        var outline = [Float](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w where text[y * w + x] > 0.3 {
            for dy in -2...2 { for dx in -2...2 where dx * dx + dy * dy <= 5 {
                let qx = x + dx, qy = y + dy
                if qx >= 0, qx < w, qy >= 0, qy < h { outline[qy * w + qx] = max(outline[qy * w + qx], text[y * w + x]) }
            } }
        } }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let t = text[i], o = outline[i] * 0.75, alpha = t + o * (1 - t)
            guard alpha > 0.01 else { continue }
            for c in 0..<3 { px[i * 4 + c] = UInt8(Float(rgb[i * 3 + c]) * t + 25 * o * (1 - t)) }
            px[i * 4 + 3] = UInt8(alpha * 255)
        }
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let index = subs.count
        try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
            .write(to: subsDir.appendingPathComponent(String(format: "%02d.png", index)))
        subs.append(["w": w, "h": h, "x": x0 - bw / 2, "y": bh - y1])   // 相对字幕条底边中点的位置
        for f in members.first!...members.last! { subIndex[f] = index }
    }
    // 字有时候一两帧认不出来，字幕会一闪一闪：两句之间不到 1 秒的空档，前一半接着显示上一句、后一半提前显示下一句
    var runs: [(index: Int, start: Int, end: Int)] = []
    for f in 0..<frameCount where subIndex[f] >= 0 {
        if let last = runs.last, last.index == subIndex[f], last.end == f - 1 { runs[runs.count - 1].end = f } else { runs.append((subIndex[f], f, f)) }
    }
    for (a, b) in zip(runs, runs.dropFirst()) where b.start - a.end - 1 <= 30 {
        let mid = (a.end + b.start) / 2
        for f in (a.end + 1)..<b.start { subIndex[f] = f <= mid ? a.index : b.index }
    }
    if let first = runs.first, first.start <= 15 { for f in 0..<first.start { subIndex[f] = first.index } }
    if let last = runs.last, frameCount - 1 - last.end <= 45 { for f in (last.end + 1)..<frameCount { subIndex[f] = last.index } }
    print("字幕 \(subs.count) 句")
}

// MARK: 声音：整段导出，音量统一调到差不多响

let rawAudio = outDir.appendingPathComponent("raw.m4a"), audioURL = outDir.appendingPathComponent("audio.m4a")
wait {
    let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)!
    export.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: Double(frameCount) / outFPS, preferredTimescale: 600))
    try await export.export(to: rawAudio, as: .m4a)
}
normalizeAudio(rawAudio, audioURL)
try? FileManager.default.removeItem(at: rawAudio)

let meta: [String: Any] = [
    "width": CW, "height": CH, "fps": outFPS, "frames": frameCount,
    "cuts": segs.map(\.range.lowerBound).filter { $0 > 0 },
    "subs": subs, "subIndex": subIndex, "freezeFrom": freezeFrom ?? -1, "rawFrom": rawFrom ?? -1,
]
try! JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: outDir.appendingPathComponent("meta.json"))
print("完成：\(outDir.path)")
