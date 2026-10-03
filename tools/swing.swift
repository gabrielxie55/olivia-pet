import AVFoundation
import AppKit
import Vision
import CoreImage
import simd

// 把荡秋千视频做成透明背景的逐帧动画
// 原视频是手持拍的天空背景：先把每一帧对齐到同一个机位（防抖），
// 再用所有帧的中位数算出一张「没有人的空背景」，每一帧和空背景对比，变了的地方就是她和秋千链子
// 用法：swing <视频> <输出目录>，输出 frames/*.png、mask.bin、audio.m4a

let args = CommandLine.arguments
let videoURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let refIndex = 75            // 2.5 秒处她荡出了画面，用这一帧当对齐基准
let asset = AVURLAsset(url: videoURL)

func wait(_ body: @escaping () async throws -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { try await body(); sem.signal() }
    sem.wait()
}

// MARK: 读帧

var buffers: [CVPixelBuffer] = []
wait {
    let track = try await asset.loadTracks(withMediaType: .video)[0]
    let reader = try AVAssetReader(asset: asset)
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    out.alwaysCopiesSampleData = true
    reader.add(out)
    reader.startReading()
    while let sb = out.copyNextSampleBuffer() {
        if let pb = CMSampleBufferGetImageBuffer(sb) { buffers.append(pb) }
    }
}
let W = CVPixelBufferGetWidth(buffers[0]), H = CVPixelBufferGetHeight(buffers[0])
let n = buffers.count
print("读到 \(n) 帧，\(W)x\(H)")

// MARK: 防抖：每一帧都对齐到基准帧

let ci = CIContext(options: [.workingColorSpace: NSNull()])
var frames: [[UInt8]] = []          // RGBA，第一行是画面顶部
// 先算出每一帧四个角对齐后的位置（Vision 的坐标原点在左下）
var corners: [[CGPoint]] = buffers.map { pb in
    let req = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: pb)
    try! VNImageRequestHandler(cvPixelBuffer: buffers[refIndex]).perform([req])
    let m = (req.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform ?? matrix_identity_float3x3
    return [(0, H), (W, H), (0, 0), (W, 0)].map { (x: Int, y: Int) -> CGPoint in
        let v = m * SIMD3<Float>(Float(x), Float(y), 1)
        return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }
}
// 个别帧（她离镜头很近、占了大半个画面时）会对齐失败、突然跳一下：和前后几帧差太多的，换成前后几帧的中位数
let raw = corners
for i in 0..<n {
    let window = raw[max(0, i - 4)...min(n - 1, i + 4)]
    var median: [CGPoint] = []
    var outlier = false
    for c in 0..<4 {
        let xs = window.map { $0[c].x }.sorted(), ys = window.map { $0[c].y }.sorted()
        let mp = CGPoint(x: xs[xs.count / 2], y: ys[ys.count / 2])
        median.append(mp)
        if abs(raw[i][c].x - mp.x) > 5 || abs(raw[i][c].y - mp.y) > 5 { outlier = true }
    }
    if outlier { corners[i] = median; print("第 \(i) 帧对齐跳了，已修正") }
}
var cropMinX: CGFloat = 0, cropMaxX = CGFloat(W), cropMinY: CGFloat = 0, cropMaxY = CGFloat(H)
for (pb, q) in zip(buffers, corners) {
    let (tl, tr, bl, br) = (q[0], q[1], q[2], q[3])
    // 所有帧都有画面的区域，最后只保留这一块，免得边上出现黑边
    cropMinX = max(cropMinX, tl.x, bl.x); cropMaxX = min(cropMaxX, tr.x, br.x)
    cropMinY = max(cropMinY, bl.y, br.y); cropMaxY = min(cropMaxY, tl.y, tr.y)
    let f = CIFilter(name: "CIPerspectiveTransform")!
    f.setValue(CIImage(cvPixelBuffer: pb), forKey: kCIInputImageKey)
    f.setValue(CIVector(cgPoint: tl), forKey: "inputTopLeft")
    f.setValue(CIVector(cgPoint: tr), forKey: "inputTopRight")
    f.setValue(CIVector(cgPoint: bl), forKey: "inputBottomLeft")
    f.setValue(CIVector(cgPoint: br), forKey: "inputBottomRight")
    var d = [UInt8](repeating: 0, count: W * H * 4)
    ci.render(f.outputImage!, toBitmap: &d, rowBytes: W * 4, bounds: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8, colorSpace: nil)
    frames.append(d)
}
// CoreImage 渲染出来的第一行是画面顶部，换算成「从顶部数」的行号
let x0 = Int(ceil(cropMinX)) + 1, x1 = Int(floor(cropMaxX)) - 1
let y0 = H - Int(floor(cropMaxY)) + 1, y1 = H - Int(ceil(cropMinY)) - 1
let cw = x1 - x0, chh = y1 - y0
print("防抖后保留区域 x \(x0)..<\(x1) y \(y0)..<\(y1)（\(cw)x\(chh)）")

// MARK: 空背景：每个像素取所有帧的中位数

var plate = [Float](repeating: 0, count: cw * chh * 3)
do {
    var vals = [UInt8](repeating: 0, count: n)
    for y in 0..<chh { for x in 0..<cw { for c in 0..<3 {
        let i = ((y + y0) * W + (x + x0)) * 4 + c
        for k in 0..<n { vals[k] = frames[k][i] }
        vals.sort()
        plate[(y * cw + x) * 3 + c] = Float(vals[n / 2])
    } } }
}

// 调试：输出空背景和「哪里动过」的叠加图，用来找秋千链子挂在横梁上的位置
if ProcessInfo.processInfo.environment["SWING_DEBUG"] != nil {
    var p = [UInt8](repeating: 255, count: cw * chh * 4), mx = [Float](repeating: 0, count: cw * chh)
    for i in 0..<(cw * chh) { for c in 0..<3 { p[i * 4 + c] = UInt8(plate[i * 3 + c]) } }
    for k in stride(from: 0, to: n, by: 2) { for y in 0..<chh { for x in 0..<cw {
        let i = ((y + y0) * W + (x + x0)) * 4, j = (y * cw + x) * 3
        var d2: Float = 0
        for c in 0..<3 { let dd = Float(frames[k][i + c]) - plate[j + c]; d2 += dd * dd }
        mx[y * cw + x] = max(mx[y * cw + x], d2.squareRoot())
    } } }
    var q = [UInt8](repeating: 255, count: cw * chh * 4)
    for i in 0..<(cw * chh) { let v = UInt8(min(255, mx[i] * 3)); q[i * 4] = v; q[i * 4 + 1] = v; q[i * 4 + 2] = v }
    for (name, var buf) in [("plate", p), ("moved", q)] {
        let ctx = CGContext(data: &buf, width: cw, height: chh, bitsPerComponent: 8, bytesPerRow: cw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/swing_\(name).png"))
    }
    exit(0)
}

// MARK: 秋千架：从空背景里把横梁、立柱和挂钩抠出来，做成一张不动的底图

/// 0~1：越像蓝天越接近 0
func notSky(_ r: Float, _ g: Float, _ b: Float) -> Float { min(1, max(0, (40 - (b - r)) / 25)) }
/// 0~1：越像背光的树越接近 0
func notTree(_ lum: Float) -> Float { min(1, max(0, (lum - 22) / 25)) }
func plateRGB(_ x: Int, _ y: Int) -> (Float, Float, Float) { let j = (y * cw + x) * 3; return (plate[j], plate[j + 1], plate[j + 2]) }
func rigKey(_ x: Int, _ y: Int) -> Float {
    let (r, g, b) = plateRGB(x, y)
    return min(notSky(r, g, b), notTree(0.3 * r + 0.59 * g + 0.11 * b))
}
/// 一组数在 ±r 范围内取中位数（-1 表示这里没找到，跳过）
func medianSmooth(_ v: [Float], _ r: Int) -> [Float] {
    v.indices.map { i in
        let w = v[max(0, i - r)...min(v.count - 1, i + r)].filter { $0 >= 0 }.sorted()
        return w.isEmpty ? -1 : w[w.count / 2]
    }
}
/// 在 lo...hi 里找最长的一段「是秋千架」的像素，返回中心和半宽
func longestRun(_ lo: Int, _ hi: Int, _ key: (Int) -> Float) -> (Float, Float)? {
    var best = (len: 0, start: 0), run = 0
    for i in lo...hi {
        if key(i) > 0.5 { run += 1; if run > best.len { best = (run, i - run + 1) } } else { run = 0 }
    }
    return best.len >= 3 ? (Float(best.start) + Float(best.len - 1) / 2, Float(best.len) / 2) : nil
}

// 她那架秋千的两个挂钩（裁切后的坐标，y 从顶部算），从「哪里动过」的叠加图里量出来的
let hooks: [(x: Float, y: Float)] = [(121, 362), (184, 318)]
// 画面最上面一截只有横梁伸出去的那头，输出时裁掉，这样她在桌面上能显得大一些
let topCut = 150
var rigAlpha = [Float](repeating: 0, count: cw * chh)
do {
    // 横梁：斜着从左下到右上，每一列在大致位置上下找
    var center = [Float](repeating: -1, count: cw), half = [Float](repeating: -1, count: cw)
    for x in 0..<cw {
        let guess = Int(437 - 0.8128 * Float(x))
        if let (c, h) = longestRun(max(0, guess - 45), min(chh - 1, guess + 45), { rigKey(x, $0) }) { center[x] = c; half[x] = h }
    }
    center = medianSmooth(center, 6); half = medianSmooth(half, 6)
    for x in 0..<cw where center[x] >= 0 {
        let h = min(max(half[x], 3), 12) + 2
        for y in max(0, Int(center[x] - h))...min(chh - 1, Int(center[x] + h)) {
            let fade = min(1, max(0, Float(y - topCut) / 50))    // 横梁伸出画面的那一头慢慢淡掉
            rigAlpha[y * cw + x] = rigKey(x, y) * fade
        }
    }
    // 立柱：从横梁往下一直到底，每一行在大致位置左右找
    var pc = [Float](repeating: -1, count: chh), ph = [Float](repeating: -1, count: chh)
    for y in 390..<chh {
        let guess = Int(67 - 0.112 * Float(y - 420))
        if let (c, h) = longestRun(max(0, guess - 10), min(cw - 1, guess + 10), { rigKey($0, y) }) { pc[y] = c; ph[y] = h }
    }
    pc = medianSmooth(pc, 8); ph = medianSmooth(ph, 8)
    for y in 390..<chh where pc[y] >= 0 {
        let h = min(max(ph[y], 2.5), 5) + 1.5
        for x in max(0, Int(pc[y] - h))...min(cw - 1, Int(pc[y] + h)) { rigAlpha[y * cw + x] = max(rigAlpha[y * cw + x], rigKey(x, y)) }
    }
    // 挂钩比横梁粗一圈，单独补上
    for hk in hooks {
        for y in Int(hk.y) - 14...Int(hk.y) + 8 { for x in Int(hk.x) - 12...Int(hk.x) + 12 where hypot(Float(x) - hk.x, Float(y) - hk.y + 4) < 12 {
            rigAlpha[y * cw + x] = max(rigAlpha[y * cw + x], rigKey(x, y))
        } }
    }
    rigAlpha = boxBlur(rigAlpha, cw, chh, 1).enumerated().map { min($1, rigAlpha[$0] > 0 ? 1 : $1) }
}

func writeRGBA(_ full: [UInt8], _ url: URL) {
    var px = Array(full[(topCut * cw * 4)...])
    let ctx = CGContext(data: &px, width: cw, height: chh - topCut, bitsPerComponent: 8, bytesPerRow: cw * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: url)
}

do {
    var px = [UInt8](repeating: 0, count: cw * chh * 4)
    for i in 0..<(cw * chh) where rigAlpha[i] > 0.02 {
        let a = rigAlpha[i]
        let (r, g, b) = (plate[i * 3], plate[i * 3 + 1], plate[i * 3 + 2])
        // 半透明的边缘混进了天空的蓝色，往灰色拉一拉
        let lum = 0.3 * r + 0.59 * g + 0.11 * b, k = (1 - a) * 0.8
        for (c, v) in [r, g, b].enumerated() { px[i * 4 + c] = UInt8((v + (lum - v) * k) * a) }
        px[i * 4 + 3] = UInt8(a * 255)
    }
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    writeRGBA(px, outDir.appendingPathComponent("rig.png"))
}

// MARK: 逐帧抠图

/// 只留下她：最大的一块是她，离她很近的小块（头发、手脚）也留着，其他零碎（防抖没对齐的横梁边、树梢）都去掉
func keepHer(_ a: inout [Float]) {
    var label = [Int32](repeating: 0, count: a.count)
    var comps: [(members: [Int], box: (Int, Int, Int, Int))] = []
    var stack: [Int] = []
    for start in a.indices where a[start] > 0.2 && label[start] == 0 {
        var members: [Int] = []
        var box = (Int.max, Int.max, Int.min, Int.min)
        stack.append(start); label[start] = Int32(comps.count + 1)
        while let p = stack.popLast() {
            members.append(p)
            let px = p % cw, py = p / cw
            box = (min(box.0, px), min(box.1, py), max(box.2, px), max(box.3, py))
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let qx = px + dx, qy = py + dy
                guard qx >= 0, qx < cw, qy >= 0, qy < chh else { continue }
                let q = qy * cw + qx
                if label[q] == 0 && a[q] > 0.2 { label[q] = Int32(comps.count + 1); stack.append(q) }
            } }
        }
        comps.append((members, box))
    }
    guard let main = comps.max(by: { $0.members.count < $1.members.count }), main.members.count >= 150 else {
        a = [Float](repeating: 0, count: a.count)    // 她不在画面里
        return
    }
    let m = 30, mb = main.box
    var keep = [Bool](repeating: false, count: a.count)
    for c in comps where c.members.count >= 30 {
        let b = c.box
        if b.2 >= mb.0 - m && b.0 <= mb.2 + m && b.3 >= mb.1 - m && b.1 <= mb.3 + m { for p in c.members { keep[p] = true } }
    }
    // 半透明的边：只留紧挨着保留下来的实心像素的
    var out = [Float](repeating: 0, count: a.count)
    for i in a.indices where a[i] > 0 {
        if keep[i] { out[i] = a[i]; continue }
        guard a[i] <= 0.2 else { continue }
        let px = i % cw, py = i / cw
        search: for dy in -2...2 { for dx in -2...2 {
            let qx = px + dx, qy = py + dy
            if qx >= 0, qx < cw, qy >= 0, qy < chh, keep[qy * cw + qx] { out[i] = a[i]; break search }
        } }
    }
    a = out
}

/// 从挂钩往外打一圈射线，找哪个方向上一路都有「动过」的细线：那就是链子，一直到碰到她的身体或者出画面为止
func findChain(hook: (x: Float, y: Float), diff: [Float], body: [Float],
               from lo: Float = -20, to hi: Float = 200, minScore: Float = 12) -> (angle: Float, length: Float)? {
    var best: (score: Float, angle: Float, length: Float)?
    for deg in stride(from: lo, through: hi, by: 0.5) {
        if deg > 129 && deg < 153 { continue }      // 顺着横梁的方向不算
        let t = deg * .pi / 180, dx = cos(t), dy = sin(t)
        var sum: Float = 0, count = 0
        var length: Float = 0
        var r: Float = 14
        while true {
            let x = Int(hook.x + dx * r), y = Int(hook.y + dy * r)
            if x < 1 || x >= cw - 1 || y < 1 || y >= chh - 1 { length = r; break }
            if body[y * cw + x] > 0.5 { length = r; break }
            // 链子很细，左右各多看一个像素
            sum += max(diff[y * cw + x], diff[(y + Int(dx.rounded())) * cw + x - Int(dy.rounded())], diff[(y - Int(dx.rounded())) * cw + x + Int(dy.rounded())])
            count += 1
            r += 1
        }
        guard count >= 25 else { continue }
        let score = sum / Float(count)
        if score > minScore && score > (best?.score ?? 0) { best = (score, t, length) }
    }
    return best.map { ($0.angle, $0.length) }
}

// 空背景里本来就有边缘的地方（树梢、横梁、电线），防抖差一两个像素就会「看起来动了」：这些地方要差得更多才算是她
var plateEdge = [Float](repeating: 0, count: cw * chh)
for y in 1..<(chh - 1) { for x in 1..<(cw - 1) {
    var g: Float = 0
    for c in 0..<3 {
        let gx = plate[(y * cw + x + 1) * 3 + c] - plate[(y * cw + x - 1) * 3 + c]
        let gy = plate[((y + 1) * cw + x) * 3 + c] - plate[((y - 1) * cw + x) * 3 + c]
        g = max(g, abs(gx) + abs(gy))
    }
    plateEdge[y * cw + x] = g
} }
plateEdge = boxBlur(plateEdge, cw, chh, 1)

// 背景是深色树林的地方，差值法分不清她的深色头发和树叶，这里改用 Vision 的「主体识别」来补
var treeWeight = [Float](repeating: 0, count: cw * chh)
for i in treeWeight.indices {
    let lum = 0.3 * plate[i * 3] + 0.59 * plate[i * 3 + 1] + 0.11 * plate[i * 3 + 2]
    treeWeight[i] = min(1, max(0, (90 - lum) / 30))
}

/// Vision 识别出来的主体里，和她（差值法找到的身体）重叠的那几个，合成一张 alpha
func subjectMask(_ k: Int, her: [Float]) -> [Float] {
    var out = [Float](repeating: 0, count: cw * chh)
    var px = frames[k]
    let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let handler = VNImageRequestHandler(cgImage: ctx.makeImage()!)
    let req = VNGenerateForegroundInstanceMaskRequest()
    guard (try? handler.perform([req])) != nil, let obs = req.results?.first else { return out }
    for inst in obs.allInstances {
        guard let pb = try? obs.generateScaledMaskForImage(forInstances: [inst], from: handler) else { continue }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let bpr = CVPixelBufferGetBytesPerRow(pb), base = CVPixelBufferGetBaseAddress(pb)!
        let isFloat = CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_OneComponent32Float
        func m(_ x: Int, _ y: Int) -> Float {
            let row = base + (y + y0) * bpr
            return isFloat ? row.assumingMemoryBound(to: Float.self)[x + x0] : Float(row.assumingMemoryBound(to: UInt8.self)[x + x0]) / 255
        }
        var area = 0, overlap = 0
        for y in 0..<chh { for x in 0..<cw where m(x, y) > 0.5 {
            area += 1
            if her[y * cw + x] > 0.5 { overlap += 1 }
        } }
        guard area > 0, Float(overlap) > 0.25 * Float(area) else { continue }
        for y in 0..<chh { for x in 0..<cw { out[y * cw + x] = max(out[y * cw + x], m(x, y)) } }
    }
    return out
}

var herFrames: [[Float]] = []      // 每帧她的 alpha
var chains: [[(angle: Float, length: Float)?]] = []
for k in 0..<n {
    var alpha = [Float](repeating: 0, count: cw * chh), diff = alpha
    for y in 0..<chh { for x in 0..<cw {
        let i = ((y + y0) * W + (x + x0)) * 4, j = (y * cw + x) * 3
        var d2: Float = 0
        for c in 0..<3 { let dd = Float(frames[k][i + c]) - plate[j + c]; d2 += dd * dd }
        let d = max(0, d2.squareRoot() - 0.6 * plateEdge[y * cw + x])
        diff[y * cw + x] = d
        let t = min(1, max(0, (d - 20) / 30))
        alpha[y * cw + x] = t * t * (3 - 2 * t)
    } }
    keepHer(&alpha)
    if alpha.contains(where: { $0 > 0.5 }) {
        let subject = subjectMask(k, her: alpha)
        for i in alpha.indices where treeWeight[i] > 0 { alpha[i] = max(alpha[i], subject[i] * treeWeight[i]) }
    }
    alpha = boxBlur(alpha, cw, chh, 1)
    herFrames.append(alpha)
    var found = hooks.map { findChain(hook: $0, diff: diff, body: alpha) }
    /// 从挂钩朝某个点一直走，碰到她的身体或者出了画面就停
    func march(_ h: (x: Float, y: Float), toward t: (x: Float, y: Float)) -> (angle: Float, length: Float) {
        let angle = atan2(t.y - h.y, t.x - h.x), limit = hypot(t.x - h.x, t.y - h.y) + 15
        var r: Float = 14
        while r < limit {
            let x = Int(h.x + cos(angle) * r), y = Int(h.y + sin(angle) * r)
            if x < 1 || x >= cw - 1 || y < 1 || y >= chh - 1 || alpha[y * cw + x] > 0.5 { break }
            r += 1
        }
        return (angle, r)
    }
    // 只找到一根时：另一根也连到差不多的位置（她两只手抓着链子，离得很近），先在那个方向附近放宽标准找，找不到就直接连过去
    for (h, other) in [(0, 1), (1, 0)] where found[h] == nil {
        guard let o = found[other] else { continue }
        let end = (x: hooks[other].x + cos(o.angle) * o.length, y: hooks[other].y + sin(o.angle) * o.length)
        let deg = atan2(end.y - hooks[h].y, end.x - hooks[h].x) * 180 / .pi
        found[h] = findChain(hook: hooks[h], diff: diff, body: alpha, from: deg - 8, to: deg + 8, minScore: 7) ?? march(hooks[h], toward: end)
    }
    // 一根都没找到但她在画面里：两根都连到她身上离挂钩最近的地方
    if found.allSatisfy({ $0 == nil }) {
        for h in hooks.indices {
            var best: (d: Float, x: Float, y: Float)?
            for i in alpha.indices where alpha[i] > 0.5 {
                let x = Float(i % cw), y = Float(i / cw), d = hypot(x - hooks[h].x, y - hooks[h].y)
                if d < (best?.d ?? .infinity) { best = (d, x, y) }
            }
            if let b = best { found[h] = march(hooks[h], toward: (b.x, b.y)) }
        }
    }
    chains.append(found)
}

// 链子的角度前后各看一帧取中位数，免得某一帧找歪了抖一下
for h in hooks.indices {
    let raw = chains.map { $0[h] }
    for k in 0..<n {
        let near = raw[max(0, k - 1)...min(n - 1, k + 1)].compactMap { $0 }
        guard raw[k] != nil, near.count >= 2 else { chains[k][h] = near.count >= 2 ? nil : raw[k]; continue }
        let angles = near.map(\.angle).sorted(), lengths = near.map(\.length).sorted()
        chains[k][h] = (angles[angles.count / 2], lengths[lengths.count / 2])
    }
}

let framesDir = outDir.appendingPathComponent("frames")
try? FileManager.default.removeItem(at: framesDir)
try! FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
var found = 0
for k in 0..<n {
    // 先画链子（在她身后），再把她叠上去
    var px = [UInt8](repeating: 0, count: cw * chh * 4)
    let ctx = CGContext(data: &px, width: cw, height: chh, bitsPerComponent: 8, bytesPerRow: cw * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(chh)); ctx.scaleBy(x: 1, y: -1)     // 改成 y 从顶部算
    ctx.setLineCap(.round)
    for (h, chain) in zip(hooks, chains[k]) {
        guard let chain else { continue }
        found += 1
        let end = CGPoint(x: CGFloat(h.x + cos(chain.angle) * (chain.length + 5)), y: CGFloat(h.y + sin(chain.angle) * (chain.length + 5)))
        let start = CGPoint(x: CGFloat(h.x), y: CGFloat(h.y))
        ctx.setStrokeColor(CGColor(srgbRed: 0.33, green: 0.33, blue: 0.35, alpha: 1)); ctx.setLineWidth(2.2)
        ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
        ctx.setStrokeColor(CGColor(srgbRed: 0.7, green: 0.7, blue: 0.72, alpha: 0.7)); ctx.setLineWidth(0.8)
        ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
    }
    let alpha = herFrames[k]
    for y in 0..<chh { for x in 0..<cw {
        let p = y * cw + x, a = alpha[p]
        guard a > 0.02 else { continue }
        // 边缘去背景色：已知背景是什么颜色，就能把半透明边缘里混进去的天空蓝减掉
        let i = ((y + y0) * W + (x + x0)) * 4, j = p * 3
        for c in 0..<3 {
            let fg = min(255, max(0, (Float(frames[k][i + c]) - (1 - a) * plate[j + c]) / a))
            px[p * 4 + c] = UInt8(fg * a + Float(px[p * 4 + c]) * (1 - a))
        }
        px[p * 4 + 3] = UInt8(a * 255 + Float(px[p * 4 + 3]) * (1 - a))
    } }
    writeRGBA(px, framesDir.appendingPathComponent(String(format: "%03d.png", k)))
}
print("帧已写入 \(framesDir.path)，其中找到链子 \(found) 根次")

// MARK: 声音

let rawAudio = outDir.appendingPathComponent("raw.m4a"), audioURL = outDir.appendingPathComponent("audio.m4a")
try? FileManager.default.removeItem(at: rawAudio)
wait {
    let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)!
    try await export.export(to: rawAudio, as: .m4a)
}
normalizeAudio(rawAudio, audioURL)      // 音量和其他名场面统一
try? FileManager.default.removeItem(at: rawAudio)
print("声音已写入 \(audioURL.path)")
