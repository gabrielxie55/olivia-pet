import AVFoundation
// 名场面的声音再加工：音量统一，需要的话变速（画面在桌宠里按同样的倍数加快播放）
// 用法：audiofix <素材目录> [倍速]
// 会改写 <素材目录>/audio.m4a，并把倍速写进 meta.json（第一次运行时把原声备份成 audio_original.m4a，以后都从原声重新做）
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let rate = CommandLine.arguments.count > 2 ? Float(CommandLine.arguments[2])! : 1
let audio = dir.appendingPathComponent("audio.m4a"), original = dir.appendingPathComponent("audio_original.m4a")
if !FileManager.default.fileExists(atPath: original.path) { try! FileManager.default.copyItem(at: audio, to: original) }
let tmp = dir.appendingPathComponent("tmp.m4a")
if rate != 1 {
    speedAudio(original, tmp, rate: rate)
    normalizeAudio(tmp, audio)
    try? FileManager.default.removeItem(at: tmp)
} else {
    normalizeAudio(original, audio)
}
let metaURL = dir.appendingPathComponent("meta.json")
if var meta = (try? Data(contentsOf: metaURL)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) {
    meta["speed"] = Double(rate)
    try! JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: metaURL)
}
print("\(dir.lastPathComponent)：\(rate) 倍速")
