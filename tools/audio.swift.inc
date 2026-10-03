// ---- 声音处理（scene.swift 和 swing.swift 共用，构建时拼接进去） ----
/// 把整段声音的平均响度调到 targetDB，太响的地方用软限幅压住，避免爆音
func normalizeAudio(_ src: URL, _ dst: URL, targetDB: Double = -13) {
    let inFile = try! AVAudioFile(forReading: src)
    let fmt = inFile.processingFormat
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(inFile.length))!
    try! inFile.read(into: buf)
    let channels = Int(fmt.channelCount), n = Int(buf.frameLength)
    var sum = 0.0
    for c in 0..<channels { let d = buf.floatChannelData![c]; for i in 0..<n { sum += Double(d[i] * d[i]) } }
    let rms = (sum / Double(max(1, n * channels))).squareRoot()
    let gain = Float(pow(10, targetDB / 20) / max(rms, 1e-6))
    for c in 0..<channels {
        let d = buf.floatChannelData![c]
        for i in 0..<n {
            let y = d[i] * gain, ay = abs(y)
            d[i] = ay > 0.7 ? (y > 0 ? 1 : -1) * (0.7 + 0.29 * tanh((ay - 0.7) / 0.29)) : y
        }
    }
    try? FileManager.default.removeItem(at: dst)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: fmt.sampleRate,
                                   AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: 160_000]
    let out = try! AVAudioFile(forWriting: dst, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try! out.write(from: buf)
    print(String(format: "声音：原来平均 %.0f dB，放大 %.1f 倍", 20 * log10(max(rms, 1e-9)), gain))
}

/// 变速不变调：用系统自带的「时间伸缩」把声音加快 rate 倍，音高不变（不会变成尖嗓子）
func speedAudio(_ src: URL, _ dst: URL, rate: Float) {
    let file = try! AVAudioFile(forReading: src)
    let fmt = file.processingFormat
    let engine = AVAudioEngine(), player = AVAudioPlayerNode(), stretch = AVAudioUnitTimePitch()
    stretch.rate = rate
    engine.attach(player)
    engine.attach(stretch)
    engine.connect(player, to: stretch, format: fmt)
    engine.connect(stretch, to: engine.mainMixerNode, format: fmt)
    try! engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
    try! engine.start()
    player.scheduleFile(file, at: nil)
    player.play()
    let total = AVAudioFramePosition(Double(file.length) / Double(rate))
    let out = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    let all = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: AVAudioFrameCount(total + 4096))!
    while engine.manualRenderingSampleTime < total {
        let n = AVAudioFrameCount(min(4096, total - engine.manualRenderingSampleTime))
        guard (try? engine.renderOffline(n, to: out)) == .success else { break }
        for c in 0..<Int(fmt.channelCount) {
            (all.floatChannelData![c] + Int(all.frameLength)).update(from: out.floatChannelData![c], count: Int(out.frameLength))
        }
        all.frameLength += out.frameLength
    }
    engine.stop()
    try? FileManager.default.removeItem(at: dst)
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: fmt.sampleRate,
                                   AVNumberOfChannelsKey: fmt.channelCount, AVEncoderBitRateKey: 160_000]
    let w = try! AVAudioFile(forWriting: dst, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    try! w.write(from: all)
}
