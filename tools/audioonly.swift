import AVFoundation
// 只要一段视频的声音：导出成 <输出目录>/audio.m4a（音量统一），画面不要
// 用法：audioonly <视频> <输出目录>
let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
let dir = URL(fileURLWithPath: CommandLine.arguments[2])
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let raw = dir.appendingPathComponent("raw.m4a")
let sem = DispatchSemaphore(value: 0)
Task {
    let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A)!
    try await export.export(to: raw, as: .m4a)
    sem.signal()
}
sem.wait()
normalizeAudio(raw, dir.appendingPathComponent("audio.m4a"))
try? FileManager.default.removeItem(at: raw)
try! JSONSerialization.data(withJSONObject: ["speed": 1.0], options: []).write(to: dir.appendingPathComponent("meta.json"))
print("声音已写入 \(dir.path)")
