
// ---- 边缘处理（export.swift 和 companions.swift 共用，构建时拼接进去） ----
// 可分离的最小值滤波：把不透明区域往里收 r 像素
func minFilter(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
    var tmp = a, out = a
    for y in 0..<h { for x in 0..<w { var m: Float = 1; for k in max(0, x - r)...min(w - 1, x + r) { m = min(m, a[y * w + k]) }; tmp[y * w + x] = m } }
    for y in 0..<h { for x in 0..<w { var m: Float = 1; for k in max(0, y - r)...min(h - 1, y + r) { m = min(m, tmp[k * w + x]) }; out[y * w + x] = m } }
    return out
}
// 可分离的均值模糊：让收边后的轮廓保持柔和
func boxBlur(_ a: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
    var tmp = a, out = a
    for y in 0..<h { for x in 0..<w { var s: Float = 0; var n: Float = 0; for k in max(0, x - r)...min(w - 1, x + r) { s += a[y * w + k]; n += 1 }; tmp[y * w + x] = s / n } }
    for y in 0..<h { for x in 0..<w { var s: Float = 0; var n: Float = 0; for k in max(0, y - r)...min(h - 1, y + r) { s += tmp[k * w + x]; n += 1 }; out[y * w + x] = s / n } }
    return out
}
