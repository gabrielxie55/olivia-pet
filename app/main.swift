import AppKit
import AVFoundation
import ImageIO

// Olivia Rodrigo 桌宠
// 平时是一张表情包贴纸，闲着会在屏幕底部走来走去
// 头顶一排按钮：换表情包、三个名场面（荡秋千、Good 4 U 发疯、全美婊砸蛋糕）、散步、竖屏录制
// 拖动可以挪位置，右键调大小、开关声音、录屏背景、退出

let fps = 30.0
let debug = CommandLine.arguments.contains("--debug")

// 作者署名：按钮条右下角的小水印、第一次打开时的招呼、右键菜单第一行都用这里
let authorName = "盖比Gabe"
/// 点署名打开的地方：小红书主页链接（没有的话先用小红书搜索昵称）
let authorURL = URL(string: "https://www.xiaohongshu.com/search_result?keyword=" + authorName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!
/// 调试用：--volume 0.01 让测试时几乎听不见
let volumeScale = CommandLine.arguments.firstIndex(of: "--volume").flatMap { Float(CommandLine.arguments[$0 + 1]) } ?? 1

// MARK: - 素材

/// 一段逐帧动画：透明 PNG 序列 + 可选的低清 alpha 遮罩（判断鼠标是不是点在她身上）
final class Sprite {
    let frameURLs: [URL]
    let pixelSize: CGSize
    private let mask: [UInt8]
    private let maskW: Int, maskH: Int
    var count: Int { frameURLs.count }
    var aspect: CGFloat { pixelSize.width / pixelSize.height }

    init(dir: URL) {
        frameURLs = (try! FileManager.default.contentsOfDirectory(at: dir.appendingPathComponent("frames"), includingPropertiesForKeys: nil))
            .filter { ["png", "heic"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("mask.bin")) {
            let bytes = [UInt8](data)
            func u32(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
            maskW = u32(0); maskH = u32(4)
            mask = Array(bytes[12...])
        } else {
            maskW = 0; maskH = 0; mask = []
        }
        let src = CGImageSourceCreateWithURL(frameURLs[0] as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        pixelSize = CGSize(width: props[kCGImagePropertyPixelWidth] as! Int, height: props[kCGImagePropertyPixelHeight] as! Int)
    }

    func image(_ i: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(frameURLs[min(i, count - 1)] as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// u、v 是 0~1 的归一化坐标，v 从顶部算起
    func alpha(frame: Int, u: CGFloat, v: CGFloat) -> UInt8 {
        guard maskW > 0, u >= 0, u < 1, v >= 0, v < 1 else { return 0 }
        return mask[(frame % count) * maskW * maskH + Int(v * CGFloat(maskH)) * maskW + Int(u * CGFloat(maskW))]
    }
}

/// 表情包贴纸：bust 表示半身照，底边是被照片切断的，贴着地面「冒出来」
struct Meme {
    let sprite: Sprite
    let image: CGImage
    let bust: Bool
    let heightFactor: CGFloat     // 相对于基准高度显示多高
}

/// 名场面：一段带声音的逐帧动画
struct Scene {
    let sprite: Sprite
    let rig: CGImage?             // 不动的布景（秋千架），垫在她下面
    let audio: URL
    let heightFactor: CGFloat     // 原地演出的名场面：画布相对于基准高度显示多高
    var corner = false            // 秋千：靠在屏幕左下角演，她从屏幕边荡进来再荡出去
    var shake = false             // Good 4 U：跟着音乐的音量震屏
    var cuts: Set<Int> = []       // 原视频换镜头的帧：轻轻「弹」一下
    var subs: [(image: CGImage, rect: CGRect)] = []   // 字幕图，rect 是画布像素坐标（左下角为原点）
    var subIndex: [Int] = []      // 每一帧显示第几句字幕，-1 是没有
    var freezeFrom: Int?          // 这一帧起画面是定格的（抠图工具写在 meta.json 里）
    var crackAt: Int?             // VMA：这一帧开始屏幕被砸裂
    var speed = 1.0               // 倍速：太长的名场面加快播放（声音已经按同样倍数做好了）
    var singer = false            // 只有声音的名场面：她用一张表情包站着跟着唱，演多久按声音的长短

    /// 只有声音的名场面：拿一张表情包当画面
    init(singer sprite: Sprite, audio: URL, heightFactor: CGFloat) {
        self.sprite = sprite
        self.audio = audio
        self.rig = nil
        self.heightFactor = heightFactor
        singer = true
    }

    /// 读取素材目录里的 meta.json（抠图工具输出的画布信息、换镜头的位置、字幕）
    init(dir: URL, heightFactor: CGFloat, rig: CGImage? = nil) {
        sprite = Sprite(dir: dir)
        audio = dir.appendingPathComponent("audio.m4a")
        self.rig = rig
        self.heightFactor = heightFactor
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        cuts = Set(meta["cuts"] as? [Int] ?? [])
        subIndex = meta["subIndex"] as? [Int] ?? []
        if let freeze = meta["freezeFrom"] as? Int, freeze > 0 { freezeFrom = freeze }
        speed = meta["speed"] as? Double ?? 1
        let canvasW = CGFloat(meta["width"] as? Int ?? Int(sprite.pixelSize.width))
        for (i, sub) in (meta["subs"] as? [[String: Int]] ?? []).enumerated() {
            let url = dir.appendingPathComponent(String(format: "subs/%02d.png", i))
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            // 字幕条底边中点放在画布底部中间，稍微抬高一点
            let r = CGRect(x: canvasW / 2 + CGFloat(sub["x"]!), y: CGFloat(sub["y"]!) + sprite.pixelSize.height * 0.03,
                           width: CGFloat(sub["w"]!), height: CGFloat(sub["h"]!))
            subs.append((img, r))
        }
    }
}

/// 所有名场面
enum SceneID: String, CaseIterable {
    case swing, g4u, aab, aab2, vma, vmalive, drama, thanku

    var title: String {
        switch self {
        case .swing: return "荡秋千"
        case .g4u: return "Good 4 U 火烧房间"
        case .aab: return "全美婊 1：砸蛋糕"
        case .aab2: return "全美婊 2：坐在桌上唱"
        case .vma: return "VMA 砸玻璃"
        case .vmalive: return "VMA 现场 Good 4 U"
        case .drama: return "抓马抓马"
        case .thanku: return "思念棉夫"
        }
    }
    /// 「发疯」按钮里的系列
    static let crazy: [SceneID] = [.g4u, .aab, .aab2, .vma]
}

// MARK: - 按钮

enum Action: Int, CaseIterable {
    case meme, cute, swing, crazy, drama, thanku, walk, portrait

    var label: String { ["搞笑娅娅", "萌娅娅", "荡秋千", "发疯", "抓马抓马", "思念棉夫", "散步", "竖屏"][rawValue] }
    var symbol: String { ["face.smiling", "sparkles", "figure.play", "flame.fill", "music.mic", "heart.fill", "figure.walk", "rectangle.portrait"][rawValue] }
    var color: NSColor { [NSColor.systemPink, .systemIndigo, .systemGreen, .systemOrange, .systemYellow, .systemPurple, .systemBlue, .systemTeal][rawValue] }
    var iconColor: NSColor { self == .drama ? NSColor(white: 0.15, alpha: 1) : .white }   // 黄底配深色图标才看得清
}

/// 头顶的一排按钮：彩色圆点 + 图标 + 小字，打开状态的按钮外面有一圈白边
final class ButtonBar: NSView {
    static let circle: CGFloat = 20, cell: CGFloat = 40, pad: CGFloat = 5, labelH: CGFloat = 11, creditH: CGFloat = 11
    static let size = NSSize(width: cell * CGFloat(Action.allCases.count) + pad * 2, height: pad + circle + 2 + labelH + creditH + pad - 1)
    /// 最下面一行小字署名，点一下打开作者主页
    static let credit = "小红书 @\(authorName) 制作"
    var onCredit: () -> Void = {}

    var isActive: (Action) -> Bool = { _ in false }
    var onPress: (Action) -> Void = { _ in }
    private var pressed: Action?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func circleRect(_ a: Action) -> NSRect {
        let s = ButtonBar.self
        return NSRect(x: s.pad + CGFloat(a.rawValue) * s.cell + (s.cell - s.circle) / 2, y: bounds.height - s.pad - s.circle, width: s.circle, height: s.circle)
    }

    func action(at p: NSPoint) -> Action? {
        guard p.y >= ButtonBar.creditH else { return nil }      // 最下面一行是署名，不算按钮
        return Action.allCases.first { NSRect(x: ButtonBar.pad + CGFloat($0.rawValue) * ButtonBar.cell, y: 0, width: ButtonBar.cell, height: bounds.height).contains(p) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.08, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        let labelFont = NSFont.systemFont(ofSize: 8.5, weight: .semibold)
        for a in Action.allCases {
            let r = circleRect(a)
            let on = isActive(a)
            (pressed == a ? a.color.shadow(withLevel: 0.3)! : a.color).setFill()
            NSBezierPath(ovalIn: r).fill()
            if on {
                NSColor.white.setStroke()
                let ring = NSBezierPath(ovalIn: r.insetBy(dx: -1.5, dy: -1.5))
                ring.lineWidth = 1.8
                ring.stroke()
            }
            let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .bold).applying(.init(paletteColors: [a.iconColor]))
            if let icon = NSImage(systemSymbolName: a.symbol, accessibilityDescription: a.label)?.withSymbolConfiguration(config) {
                let s = icon.size
                icon.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
            let text = NSAttributedString(string: a.label, attributes: [
                .font: labelFont,
                .foregroundColor: NSColor.white.withAlphaComponent(on ? 1 : 0.8),
            ])
            let ts = text.size()
            text.draw(at: NSPoint(x: r.midX - ts.width / 2, y: r.minY - 2 - ts.height))
        }
        // 右下角的署名小字：半透明，录屏的时候也会带上
        let credit = NSAttributedString(string: ButtonBar.credit, attributes: [
            .font: NSFont.systemFont(ofSize: 7.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ])
        let cs = credit.size()
        credit.draw(at: NSPoint(x: bounds.width - ButtonBar.pad - 4 - cs.width, y: 3))
    }

    func creditRect() -> NSRect { NSRect(x: bounds.width * 0.55, y: 0, width: bounds.width * 0.45, height: ButtonBar.creditH + 2) }

    override func mouseDown(with e: NSEvent) {
        pressed = action(at: convert(e.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if pressed == nil && creditRect().contains(p) { onCredit() }
        let a = action(at: p)
        if let a, a == pressed { onPress(a) }
        pressed = nil
        needsDisplay = true
    }
}

/// 录屏背景：一整块铺满屏幕，右键可以呼出桌宠菜单把它关掉
final class BackdropView: NSView {
    weak var pet: Pet?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func rightMouseDown(with e: NSEvent) { pet?.showMenu(e, in: self) }
}

/// 她右下角的「唱 Good 4 U」小按钮：紫粉渐变的胶囊 + 话筒图标
final class SingButton: NSView {
    static let size = NSSize(width: 104, height: 26)
    var onPress: () -> Void = {}
    var title = "唱 Good 4 U", symbol = "music.mic"
    var colors = (top: NSColor(srgbRed: 0.72, green: 0.4, blue: 1, alpha: 1), bottom: NSColor(srgbRed: 1, green: 0.35, blue: 0.65, alpha: 1))
    private var pressed = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let pill = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()
        let (top, bottom) = colors
        NSGradient(starting: pressed ? top.shadow(withLevel: 0.25)! : top, ending: pressed ? bottom.shadow(withLevel: 0.25)! : bottom)!.draw(in: pill, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        pill.lineWidth = 1.5
        pill.stroke()
        let font = NSFont.systemFont(ofSize: 11.5, weight: .heavy)
        let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: NSColor.white])
        let ts = text.size()
        var iconW: CGFloat = 0
        let config = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .bold).applying(.init(paletteColors: [.white]))
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        if let icon { iconW = icon.size.width + 4 }
        let x0 = r.midX - (iconW + ts.width) / 2
        if let icon { icon.draw(in: NSRect(x: x0, y: r.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)) }
        text.draw(at: NSPoint(x: x0 + iconW, y: r.midY - ts.height / 2))
    }

    override func mouseDown(with e: NSEvent) { pressed = true; needsDisplay = true }

    override func mouseUp(with e: NSEvent) {
        if pressed && bounds.contains(convert(e.locationInWindow, from: nil)) { onPress() }
        pressed = false
        needsDisplay = true
    }
}

final class PetView: NSView {
    weak var pet: Pet?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with e: NSEvent) { pet?.mouseDown() }
    override func mouseDragged(with e: NSEvent) { pet?.mouseDragged() }
    override func mouseUp(with e: NSEvent) { pet?.mouseUp() }
    override func rightMouseDown(with e: NSEvent) { pet?.showMenu(e, in: self) }
}

/// 透明、不挡鼠标、浮在最上层的面板：名场面和特效都画在这种面板上
func overlayPanel(_ frame: NSRect) -> NSPanel {
    let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.ignoresMouseEvents = true
    p.hidesOnDeactivate = false
    p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
    v.wantsLayer = true
    p.contentView = v
    p.setFrame(frame, display: false)
    return p
}

// MARK: - 桌宠

final class Pet: NSObject {
    let memes: [Meme]
    let scenes: [SceneID: Scene]
    let window: NSPanel
    let view = PetView()
    let bar = ButtonBar()
    let singButton = SingButton()
    /// 演名场面时脚边的「停止」按钮（单独一个小面板，浮在名场面上面）
    let stopButton = SingButton()
    let stopPanel: NSPanel
    let idleLayer = CALayer()       // 呼吸、走路摇摆
    let stickerLayer = CALayer()    // 点一下「弹一弹」，和上面那层分开，动画才不会互相打架

    var memeIndex: Int
    /// 临时表情：被拎起来、被摸、睡着的时候，借用别的表情包当「表情」，过一会儿换回你选的那张
    var expression: Int?
    var expressionUntil = 0.0
    var meme: Meme { memes[expression ?? memeIndex] }
    var sizeIndex: Int
    var walkEnabled: Bool
    var portraitOnly: Bool
    var soundOn: Bool

    // 散步：休息一会儿、走一会儿，交替进行
    var walking = false
    var walkDir: CGFloat = 0
    var walkPhaseEnd = CACurrentMediaTime() + 3
    var walkPos: NSPoint?       // 走路时的精确位置：窗口坐标会被取整，每步都从窗口读的话会越走越偏

    // 正在演的名场面
    struct Playing {
        let id: SceneID
        let scene: Scene
        let panel: NSPanel
        let stage: CALayer
        let frameLayer: CALayer
        let subLayer: CALayer
        let player: AVAudioPlayer?
        let start: Double
        let origin: NSPoint     // 面板原本的位置（震屏时在这附近抖）
        var shown = -1
        var shownSub = -1
        var duration = 0.0      // 跟着唱的名场面：演多久（声音的长短）
        var level: CGFloat = 0  // 跟着唱：平滑过的音量
        var lastNote = 0.0
    }
    var playing: Playing?
    var crack: NSPanel?             // VMA：被砸裂的屏幕

    var lastTick = CACurrentMediaTime()
    var dragStart: NSPoint?, dragAnchorStart = NSPoint.zero, dragged = false
    var dragTrail: [(t: Double, p: NSPoint)] = []     // 最近 0.15 秒鼠标走过的点，松手时算甩出去的速度
    var dangle: CGFloat = 0, dangleVel: CGFloat = 0     // 被拎着时像钟摆一样晃

    // 重力：松手会掉下来，扔出去会飞、撞墙、摔地上；能站在窗口顶上
    struct Motion { var pos: NSPoint; var vel: CGVector; var fallStartY: CGFloat }
    var motion: Motion?
    struct Perch { let id: Int; var frame: CGRect }     // 她站着的那个窗口（屏幕坐标，左下角为原点）
    var perch: Perch?
    var gravityOn: Bool
    /// 被你轻轻放在半空：就待在那里，不掉下去、不散步、不跳窗口
    var pinned: Bool
    var lastSupportCheck = 0.0
    var windowCache: [(id: Int, frame: CGRect)] = []
    var windowCacheTime = -1.0

    // 摸头、连点
    var rub = (lastX: CGFloat(0), dir: 0, travel: CGFloat(0), strokes: [Double](), lastHeart: 0.0)
    var clickTimes: [Double] = []
    var lastSay = 0.0
    // 鼠标靠近：往鼠标那边歪；刚靠近时跳一下、冒个感叹号
    var lean: CGFloat = 0
    var mouseNear = false
    var lastNotice = 0.0
    var fakeMouse: NSPoint?       // 调试用：假装鼠标在这里（自动测试摸头、靠近，不动你真正的鼠标）
    var mouse: NSPoint { fakeMouse ?? NSEvent.mouseLocation }

    // 自己找事做、睡觉
    var nextIdleAct = CACurrentMediaTime() + 20
    var autoScene: Int                                    // 自己演名场面：0 不演，1 偶尔，2 经常
    var nextAutoScene = 0.0
    var sleepOn: Bool
    var asleep = false
    var lastIdleCheck = 0.0, lastZ = 0.0
    var sleepAfter: Double = 180
    let fx: NSPanel                                       // 头顶的特效层：小爱心、Zzz、对话框

    static let sizes: [(String, CGFloat)] = [("小", 200), ("中", 280), ("大", 380)]   // 全身贴纸显示多高（pt）
    static let swingHeights: [CGFloat] = [0.62, 0.8, 0.95]                          // 秋千占屏幕高度的比例
    var base: CGFloat { Pet.sizes[sizeIndex].1 }

    // 布局：贴纸底边贴着窗口底边（= 地面），按钮条在头顶
    let pad: CGFloat = 10, barGap: CGFloat = 6
    var stickerSize: CGSize { let h = base * meme.heightFactor; return CGSize(width: h * meme.sprite.aspect, height: h) }
    var windowSize: CGSize { CGSize(width: max(stickerSize.width + (SingButton.size.width - 12) * 2 + 4, ButtonBar.size.width + pad * 2), height: stickerSize.height + barGap + ButtonBar.size.height + 2) }
    /// 「唱 Good 4 U」按钮：放在她右脚边，只和身体边缘重叠一点点，不挡住她
    var singRect: CGRect {
        let r = stickerRect, size = SingButton.size
        return CGRect(x: min(r.maxX - 12, windowSize.width - size.width - 2), y: 6, width: size.width, height: size.height)
    }
    var stickerRect: CGRect { CGRect(x: (windowSize.width - stickerSize.width) / 2, y: 0, width: stickerSize.width, height: stickerSize.height) }
    var barRect: CGRect {
        if home != nil { return CGRect(origin: CGPoint(x: 2, y: 2), size: ButtonBar.size) }
        return CGRect(x: (windowSize.width - ButtonBar.size.width) / 2, y: stickerSize.height + barGap, width: ButtonBar.size.width, height: ButtonBar.size.height)
    }
    /// 演名场面时按钮条会挪开，免得挡住画面；这时她「家」的位置记在这里
    var home: NSPoint?
    /// 她脚下的中点（屏幕坐标）
    var anchor: NSPoint { home ?? NSPoint(x: window.frame.midX, y: window.frame.minY) }

    init(assets: URL) {
        func load(_ name: String) -> Sprite { Sprite(dir: assets.appendingPathComponent(name)) }
        // 搞笑娅娅 4 张 + 萌娅娅 5 张；萌娅娅都是自拍大头，按脸的大小定显示高度，免得脸忽大忽小
        memes = [("meme1", false, 1.0), ("meme2", true, 0.88), ("meme3", true, 0.8), ("meme4", true, 0.95),
                 ("cute1", true, 0.62), ("cute2", true, 0.66), ("cute3", true, 0.86), ("cute4", true, 1.0), ("cute5", true, 0.62)].map { name, bust, h in
            let s = load(name)
            return Meme(sprite: s, image: s.image(0)!, bust: bust, heightFactor: h)
        }
        let rigURL = assets.appendingPathComponent("swing/rig.png")
        let rig = CGImageSourceCreateWithURL(rigURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        func scene(_ id: SceneID, _ h: CGFloat) -> Scene { Scene(dir: assets.appendingPathComponent(id.rawValue), heightFactor: h, rig: id == .swing ? rig : nil) }
        var swing = scene(.swing, 0)
        swing.corner = true
        // 画布显示多高（相对基准高度）：按画面里她的脸大概多大来定，远景多的大一些，特写多的小一些
        var g4u = scene(.g4u, 1.3)
        g4u.shake = true
        var vma = scene(.vma, 1.3)
        vma.crackAt = vma.freezeFrom      // 她一拳挥过来、画面定格的那一刻屏幕裂开
        scenes = [
            .swing: swing, .g4u: g4u,
            .aab: scene(.aab, 1.35), .aab2: scene(.aab2, 1.3), .vma: vma,
            .drama: scene(.drama, 1.0), .thanku: scene(.thanku, 0.75),
            // VMA 现场：只要声音，画面用默认那张（紫红色印花全身照）跟着唱
            .vmalive: Scene(singer: memes[0].sprite, audio: assets.appendingPathComponent("vmalive/audio.m4a"), heightFactor: memes[0].heightFactor),
        ]
        let d = UserDefaults.standard
        sizeIndex = min(max(d.object(forKey: "size") as? Int ?? 1, 0), Pet.sizes.count - 1)
        memeIndex = min(max(d.integer(forKey: "meme"), 0), memes.count - 1)
        walkEnabled = d.object(forKey: "walk") as? Bool ?? true
        portraitOnly = d.object(forKey: "portrait") as? Bool ?? false
        soundOn = d.object(forKey: "sound") as? Bool ?? true
        gravityOn = d.object(forKey: "gravity") as? Bool ?? true
        pinned = d.bool(forKey: "pinned")
        autoScene = d.object(forKey: "autoScene") as? Int ?? 1
        sleepOn = d.object(forKey: "sleep") as? Bool ?? true
        fx = overlayPanel(NSRect(x: 0, y: 0, width: 760, height: 380))
        stopPanel = overlayPanel(NSRect(origin: .zero, size: SingButton.size))
        stopPanel.ignoresMouseEvents = false
        stopPanel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)
        fx.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 2)   // 比她和按钮条高一层，爱心、对话框不会被挡

        // 不抢焦点的浮动面板：点她或按钮时，你正在用的 app 不会失去焦点
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.contentView = view
        view.pet = self
        view.wantsLayer = true
        idleLayer.anchorPoint = CGPoint(x: 0.5, y: 0)      // 以脚底为轴呼吸、摇摆
        stickerLayer.anchorPoint = CGPoint(x: 0.5, y: 0)
        stickerLayer.contentsGravity = .resize
        stickerLayer.shadowOpacity = 0.28
        stickerLayer.shadowRadius = 3
        stickerLayer.shadowOffset = CGSize(width: 0, height: -1)
        idleLayer.addSublayer(stickerLayer)
        view.layer!.addSublayer(idleLayer)
        bar.isActive = { [unowned self] in self.isActive($0) }
        bar.onPress = { [unowned self] in self.trigger($0) }
        bar.onCredit = { NSWorkspace.shared.open(authorURL) }
        view.addSubview(bar)
        singButton.onPress = { [unowned self] in self.play(.vmalive); if debug { self.log("按下「唱 Good 4 U」") } }
        view.addSubview(singButton)
        stopButton.title = "停止"
        stopButton.symbol = "stop.fill"
        stopButton.colors = (NSColor(srgbRed: 1, green: 0.42, blue: 0.4, alpha: 1), NSColor(srgbRed: 0.85, green: 0.15, blue: 0.25, alpha: 1))
        stopButton.frame = NSRect(origin: .zero, size: SingButton.size)
        stopButton.onPress = { [unowned self] in self.endScene(); if debug { self.log("按下「停止」") } }
        stopPanel.contentView = stopButton

        // 恢复上次的位置（以脚底中点为准），不在任何屏幕上就放到右下角
        var anchor = NSPoint(x: d.double(forKey: "anchorX"), y: d.double(forKey: "anchorY"))
        if d.object(forKey: "anchorX") == nil || !NSScreen.screens.contains(where: { $0.frame.contains(anchor) }) {
            let vf = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            anchor = NSPoint(x: vf.maxX - 200, y: vf.minY)
        }
        layout(anchor: anchor)
        window.orderFrontRegardless()
        fx.orderFrontRegardless()
        scheduleAutoScene()
        // 第一次打开：自我介绍一下是谁做的（只说一次）
        if !d.bool(forKey: "greeted") {
            d.set(true, forKey: "greeted")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.say("我是小红书 @\(authorName) 做的桌宠～\n关注他解锁更多歌手桌宠", force: true, seconds: 6)
            }
        }

        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
    }

    func layout(anchor: NSPoint) {
        if home != nil {
            // 按钮条挪开着（正在演名场面）：只记下新的家，等演完再摆回去
            home = anchor
            return
        }
        let size = windowSize
        window.setFrame(NSRect(x: anchor.x - size.width / 2, y: anchor.y, width: size.width, height: size.height), display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = stickerRect
        idleLayer.bounds = CGRect(origin: .zero, size: r.size)
        idleLayer.position = CGPoint(x: r.midX, y: r.minY)
        stickerLayer.bounds = idleLayer.bounds
        stickerLayer.position = CGPoint(x: r.width / 2, y: 0)
        stickerLayer.contents = meme.image
        CATransaction.commit()
        bar.frame = barRect
        singButton.frame = singRect
        singButton.isHidden = false
        singButton.needsDisplay = true
    }

    func move(anchor a: NSPoint) {
        window.setFrameOrigin(NSPoint(x: a.x - window.frame.width / 2, y: a.y))
    }

    func savePosition() {
        UserDefaults.standard.set(Double(anchor.x), forKey: "anchorX")
        UserDefaults.standard.set(Double(anchor.y), forKey: "anchorY")
        UserDefaults.standard.set(pinned, forKey: "pinned")
    }

    // MARK: 按钮对应的动作

    func isActive(_ a: Action) -> Bool {
        switch a {
        case .meme, .cute: return false
        case .swing: return playing?.id == .swing
        case .crazy: return playing.map { SceneID.crazy.contains($0.id) } ?? false
        case .drama: return playing?.id == .drama
        case .thanku: return playing?.id == .thanku
        case .walk: return walkEnabled
        case .portrait: return portraitOnly
        }
    }

    func trigger(_ a: Action) {
        switch a {
        case .meme:
            nextMeme(series: 0)
        case .cute:
            nextMeme(series: 1)
        case .swing: play(.swing)
        case .drama: play(.drama)
        case .thanku: play(.thanku)
        case .crazy:
            showCrazyMenu()
        case .walk:
            walkEnabled.toggle()
            UserDefaults.standard.set(walkEnabled, forKey: "walk")
            restWalk()
        case .portrait:
            portraitOnly.toggle()
            UserDefaults.standard.set(portraitOnly, forKey: "portrait")
            if portraitOnly { moveIntoPlayArea() }
        }
        bar.needsDisplay = true
        if debug { log("按下「\(a.label)」") }
    }

    /// 演的过程中再按同一个：提前收场；按别的名场面：直接换过去
    func play(_ id: SceneID) {
        let same = playing?.id == id
        if playing != nil { endScene() }
        if !same { startScene(id) }
        bar.needsDisplay = true
    }

    /// 「发疯」按钮：弹出一个小菜单选发哪种疯
    func showCrazyMenu() {
        let menu = NSMenu()
        if let p = playing, SceneID.crazy.contains(p.id) {
            let stop = NSMenuItem(title: "停（正在演：\(p.id.title)）", action: #selector(stopFromMenu), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            menu.addItem(.separator())
        }
        for id in SceneID.crazy {
            let item = NSMenuItem(title: id.title, action: #selector(playFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id.rawValue
            item.state = playing?.id == id ? .on : .off
            menu.addItem(item)
        }
        let random = NSMenuItem(title: "随机来一个", action: #selector(playFromMenu(_:)), keyEquivalent: "")
        random.target = self
        menu.addItem(.separator())
        menu.addItem(random)
        let r = bar.circleRect(.crazy)
        menu.popUp(positioning: nil, at: NSPoint(x: r.minX, y: r.minY - 14), in: bar)
    }

    @objc func playFromMenu(_ item: NSMenuItem) {
        let id = (item.representedObject as? String).flatMap(SceneID.init(rawValue:))
            ?? SceneID.crazy.filter { $0 != playing?.id }.randomElement()!
        if playing != nil { endScene() }
        startScene(id)
        bar.needsDisplay = true
    }

    @objc func stopFromMenu() {
        endScene()
    }

    func log(_ what: String) {
        print(what, "→ 表情包:\(memeIndex + 1) 名场面:\(playing?.id.title ?? "无") 散步开关:\(walkEnabled) 正在走:\(walking) 位置:(\(Int(anchor.x)),\(Int(anchor.y)))")
        fflush(stdout)
    }

    /// 两个表情包系列：搞笑娅娅、萌娅娅（memes 里的下标范围）
    static let series = [0..<4, 4..<9]
    var lastInSeries: [Int: Int] = [:]

    /// 换下一张表情包：「噗」一下变身；从另一个系列切过来时，接着上次看到的那张
    func nextMeme(series s: Int) {
        let center = NSPoint(x: anchor.x, y: anchor.y + stickerSize.height / 2)
        expression = nil
        let r = Pet.series[s]
        if r.contains(memeIndex) {
            memeIndex = r.lowerBound + (memeIndex - r.lowerBound + 1) % r.count
        } else {
            memeIndex = lastInSeries[s] ?? r.lowerBound
        }
        lastInSeries[s] = memeIndex
        UserDefaults.standard.set(memeIndex, forKey: "meme")
        let a = walkPos ?? anchor
        layout(anchor: a)
        guard playing == nil else { return }
        burst(at: center, radius: max(stickerSize.width, stickerSize.height) * 0.7)
        popIn()
    }

    // MARK: 每帧更新

    @objc func tick() {
        let now = CACurrentMediaTime(), dt = min(now - lastTick, 0.1)
        lastTick = now
        updateMotion(dt: dt)
        if now - lastSupportCheck > 0.15 { lastSupportCheck = now; checkSupport() }
        updateWalk(now: now, dt: dt)
        updateScene(now: now)
        updateHold(dt: dt)
        updateIdle(now: now)
        updateSleep(now: now)
        // 临时表情到点了，换回你选的那张
        if expression != nil, now > expressionUntil, !asleep, !(dragStart != nil && dragged), motion == nil { show(face: nil) }
        if asleep, now - lastZ > 1.3 { lastZ = now; spawnZ() }

        // 平时轻轻地呼吸（睡着了呼吸又慢又深）；走路时一摇一摆，全身照还会一蹦一蹦
        // 被拎着时以头顶为轴像钟摆一样晃；飞在空中时往飞的方向歪
        let depth: CGFloat = asleep ? 1.8 : 1
        let breathe = sin(now * 2 * .pi / (asleep ? 4.5 : 2.8))
        var t = CGAffineTransform.identity
        let h = stickerSize.height
        if dragStart != nil && dragged {
            t = CGAffineTransform(translationX: 0, y: h).rotated(by: dangle).translatedBy(x: 0, y: -h)
        } else if let m = motion {
            t = t.rotated(by: max(-0.5, min(0.5, -m.vel.dx * 0.00035)))
        } else if walking {
            let step = now * .pi * 3
            if !meme.bust { t = t.translatedBy(x: 0, y: abs(sin(step)) * 8 * base / 280) }
            t = t.rotated(by: sin(step) * (meme.bust ? 0.035 : 0.06))
        }
        if !(dragStart != nil && dragged) && motion == nil { t = t.rotated(by: lean) }
        t = t.scaledBy(x: 1 - 0.006 * breathe * depth, y: 1 + 0.012 * breathe * depth)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        idleLayer.setAffineTransform(t)
        CATransaction.commit()

        updateClickThrough()
        updatePetting(now: now)
        updateNotice(now: now, dt: dt)
        positionFX()
    }

    /// 鼠标在透明区域时让点击穿透到下面的窗口，只有在她身上或按钮条上才归桌宠
    func updateClickThrough() {
        guard dragStart == nil else { return }
        let p = NSEvent.mouseLocation, f = window.frame
        let interactive = isInteractive(CGPoint(x: p.x - f.minX, y: p.y - f.minY))
        if window.ignoresMouseEvents == interactive {
            window.ignoresMouseEvents = !interactive
        }
    }

    /// local 是窗口内坐标（左下角为原点）
    func isInteractive(_ local: CGPoint) -> Bool {
        if barRect.contains(local) { return true }
        if home != nil { return false }
        if !singButton.isHidden && singRect.contains(local) { return true }
        if playing != nil || stickerLayer.isHidden { return false }   // 演名场面时贴纸不在家，原地只剩按钮
        return hitSticker(local)
    }

    /// 这一点是不是在她身上（贴纸不透明的地方）
    func hitSticker(_ local: CGPoint) -> Bool {
        let r = stickerRect
        return meme.sprite.alpha(frame: 0, u: (local.x - r.minX) / r.width, v: (r.maxY - local.y) / r.height) > 60
    }

    // MARK: 表情、对话框、头顶特效

    /// 借来当「表情」的几张表情包（memes 里的下标）
    enum Face {
        static let surprised = 3    // 紫色那张，张着嘴「哦？」：被拎起来
        static let happy = 4        // 额头贴 ORGANIC 笑：被摸、你回来了
        static let annoyed = 5      // 戴耳机撇嘴：被戳烦了
        static let crazy = 6        // 吐舌头瞪眼：摔晕了、要发疯了
        static let sleepy = 8       // 毛线帽眯眼：睡着了
    }

    static let idleLines = ["今天也要发疯吗", "思念棉夫中…", "好无聊，来摸摸我", "在忙？我等你", "drivers license 考了吗",
                            "给我点个赞再走", "我是表情包本包", "今天的我也很酸", "要不要听我唱歌"]

    /// 换个表情；seconds 之后自动换回你选的那张（不传就一直保持，直到别的事情改掉它）
    func show(face: Int?, for seconds: Double = .infinity) {
        let now = CACurrentMediaTime()
        if face == expression {
            if face != nil { expressionUntil = max(expressionUntil, now + seconds) }
            return
        }
        expression = face
        expressionUntil = now + seconds
        layout(anchor: walkPos ?? motion?.pos ?? anchor)
        guard playing == nil, home == nil else { return }
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.85, 1.06, 1]
        pop.duration = 0.22
        stickerLayer.add(pop, forKey: "face")
    }

    var fxRoot: CALayer { fx.contentView!.layer! }
    /// 正在显示的对话框：她换表情、身体变大变小时跟着挪
    var bubble: (layer: CALayer, text: String, onLeft: Bool)?

    /// 特效层跟着她走：面板中线对着她，底边在她身体中间，她的头顶在面板里 0.55 倍身高的位置
    func positionFX() {
        let a = motion?.pos ?? anchor, h = stickerSize.height
        let o = NSPoint(x: (a.x - fx.frame.width / 2).rounded(), y: (a.y + h * 0.45).rounded())
        if fx.frame.origin != o { fx.setFrameOrigin(o) }
        placeBubble()
    }
    var headTop: CGFloat { stickerSize.height * 0.55 }

    /// 头旁边冒一个白色对话框，2 秒多后消失；force 为 false 时 3 秒内只说一句，免得太吵
    func say(_ text: String, force: Bool = false, seconds: Double = 2.4) {
        let now = CACurrentMediaTime()
        guard force || now - lastSay > 3, playing == nil else { return }
        lastSay = now
        fxRoot.sublayers?.filter { $0.name == "bubble" }.forEach { $0.removeFromSuperlayer() }
        let l = CALayer()
        l.name = "bubble"
        bubble = (l, text, false)
        placeBubble(force: true)
        fxRoot.addSublayer(l)
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.5, 1.08, 1]
        pop.duration = 0.25
        l.add(pop, forKey: "pop")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.bubble?.layer === l { self?.bubble = nil }
            CATransaction.begin()
            CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 0.3
            l.add(fade, forKey: "fade")
            l.opacity = 0
            CATransaction.commit()
        }
    }

    /// 对话框放在她脸旁边、按钮条下面：默认在右边，右边放不下（靠近屏幕右边）就放左边
    func placeBubble(force: Bool = false) {
        guard let b = bubble else { return }
        let screen = fx.screen ?? window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let center = fx.frame.width / 2, half = stickerSize.width / 2
        let widthGuess = b.layer.bounds.width > 0 ? b.layer.bounds.width : 120
        let onLeft = fx.frame.minX + center + half - 8 + widthGuess > screen.visibleFrame.maxX - 4
        if force || onLeft != b.onLeft {
            let (img, size) = bubbleImage(b.text, tailOnRight: onLeft)
            b.layer.contents = img
            b.layer.bounds = CGRect(origin: .zero, size: size)
            bubble?.onLeft = onLeft
        }
        let size = b.layer.bounds.size
        let x = onLeft ? center - half + 8 - size.width : center + half - 8
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        b.layer.position = CGPoint(x: x + size.width / 2, y: headTop - stickerSize.height * 0.3 + size.height / 2)
        CATransaction.commit()
    }

    /// 对话框图片：白底圆角 + 底下一个小尖角指向她（她在对话框左边时尖角在左下，在右边时尖角在右下）
    func bubbleImage(_ text: String, tailOnRight: Bool) -> (CGImage, CGSize) {
        let base = NSFont.systemFont(ofSize: 13, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 13) } ?? base
        let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1)])
        let ts = str.size(), pad: CGFloat = 9, tail: CGFloat = 7
        let size = CGSize(width: ceil(ts.width + pad * 2), height: ceil(ts.height + pad * 1.2 + tail))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let body = NSBezierPath(roundedRect: NSRect(x: 1, y: tail, width: size.width - 2, height: size.height - tail - 1), xRadius: 10, yRadius: 10)
        let point = NSBezierPath()
        let tx: (CGFloat) -> CGFloat = { tailOnRight ? size.width - $0 : $0 }
        point.move(to: NSPoint(x: tx(12), y: tail + 2))
        point.line(to: NSPoint(x: tx(4), y: 0))
        point.line(to: NSPoint(x: tx(24), y: tail + 2))
        point.close()
        NSColor.white.setFill()
        body.fill()
        point.fill()
        NSColor(white: 0, alpha: 0.15).setStroke()
        body.lineWidth = 1
        body.stroke()
        str.draw(at: NSPoint(x: pad, y: tail + pad * 0.5))
        NSGraphicsContext.restoreGraphicsState()
        return (rep.cgImage!, size)
    }

    /// 一个往上飘的小符号（爱心、Z），从 start 飘到 start + drift，边飘边变大、变淡
    func float(_ text: String, size: CGFloat, color: NSColor, from start: CGPoint, drift: CGVector, duration: Double) {
        let l = CATextLayer()
        l.string = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .heavy), .foregroundColor: color])
        l.contentsScale = 2
        l.alignmentMode = .center
        l.bounds = CGRect(x: 0, y: 0, width: size * 1.6, height: size * 1.4)
        l.position = start
        l.shadowOpacity = 0.35
        l.shadowRadius = 2
        l.shadowOffset = CGSize(width: 0, height: -1)
        l.opacity = 0
        fxRoot.addSublayer(l)
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = start
        move.toValue = CGPoint(x: start.x + drift.dx, y: start.y + drift.dy)
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 1.15
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.6, 1]
        let g = CAAnimationGroup()
        g.animations = [move, grow, fade]
        g.duration = duration
        l.add(g, forKey: "float")
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { l.removeFromSuperlayer() }
    }

    func spawnHeart() {
        let w = stickerSize.width
        let colors: [NSColor] = [.systemPink, .systemRed, NSColor(srgbRed: 1, green: 0.45, blue: 0.7, alpha: 1)]
        float("♥", size: .random(in: 16...26), color: colors.randomElement()!,
              from: CGPoint(x: fx.frame.width / 2 + .random(in: -0.25...0.25) * w, y: headTop - stickerSize.height * 0.12),
              drift: CGVector(dx: .random(in: -30...30), dy: .random(in: 80...130)), duration: 1.2)
    }

    func spawnZ() {
        float("Z", size: .random(in: 15...24), color: .white,
              from: CGPoint(x: fx.frame.width / 2 + stickerSize.width * 0.2, y: headTop - 6),
              drift: CGVector(dx: .random(in: 25...50), dy: .random(in: 60...90)), duration: 2.4)
    }

    // MARK: 拎起来、扔出去

    func beginHold() {
        motion = nil
        perch = nil
        restWalk()
        dangle = 0
        dangleVel = 0
        show(face: Face.surprised)
        say(["放我下来！", "啊啊啊", "干嘛干嘛", "我恐高！"].randomElement()!)
    }

    /// 被拎着时：鼠标往右甩，她的身子往左荡，像钟摆一样晃
    func updateHold(dt: Double) {
        guard dragStart != nil && dragged else { dangle = 0; dangleVel = 0; return }
        var vx: CGFloat = 0
        if let a = dragTrail.first, let b = dragTrail.last, b.t - a.t > 0.01 { vx = (b.p.x - a.p.x) / CGFloat(b.t - a.t) }
        let target = max(-0.7, min(0.7, -vx * 0.0006))
        let dt = CGFloat(dt)
        dangleVel += (-(dangle - target) * 60 - dangleVel * 5) * dt
        dangle += dangleVel * dt
    }

    /// 松手：用力甩出去就飞（交给重力）；轻轻放下就停在放的位置，离地面很近的话落到地面上站好
    func endHold() {
        var v = CGVector.zero
        if let a = dragTrail.first, let b = dragTrail.last, b.t - a.t > 0.01, CACurrentMediaTime() - b.t < 0.1 {
            v = CGVector(dx: (b.p.x - a.p.x) / CGFloat(b.t - a.t), dy: (b.p.y - a.p.y) / CGFloat(b.t - a.t))
            let speed = hypot(v.dx, v.dy)
            if speed > 2500 { v = CGVector(dx: v.dx / speed * 2500, dy: v.dy / speed * 2500) }
        }
        let a = anchor
        guard gravityOn else {
            pinned = false
            savePosition()
            show(face: nil)
            return
        }
        if hypot(v.dx, v.dy) > 700 {
            pinned = false
            motion = Motion(pos: a, vel: v, fallStartY: a.y)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(a) } ?? NSScreen.main ?? NSScreen.screens[0]
        let s = surfaceBelow(x: a.x, top: a.y + 0.5, screen: screen)
        if a.y - s.y < 40 {
            pinned = false
            motion = Motion(pos: a, vel: .zero, fallStartY: a.y)      // 离地面很近：轻轻落下去站好
        } else {
            pinned = true
            perch = nil
            savePosition()
            show(face: nil)
            bump(horizontal: false)
        }
    }

    // MARK: 戳她

    /// 戳一两下弹一弹；连戳三四下她不耐烦；两秒多里戳满五下，她就发疯给你看
    func clicked() {
        let now = CACurrentMediaTime()
        clickTimes = clickTimes.filter { now - $0 < 2.5 } + [now]
        boing()
        switch clickTimes.count {
        case 3, 4:
            show(face: Face.annoyed, for: 2.5)
            say(["干嘛！", "别戳了", "又戳我？", "手好欠哦"].randomElement()!, force: true)
        case 5...:
            clickTimes = []
            show(face: Face.crazy, for: 1.2)
            say("你惹到我了！", force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                guard let self, self.playing == nil else { return }
                self.play(SceneID.crazy.randomElement()!)
            }
        default:
            break
        }
    }

    // MARK: 摸头

    /// 鼠标在她上半身来回蹭（不按键），左右蹭两下就开始冒爱心、换成开心的表情
    /// 范围是她上半身的大致外框，左右各放宽一点：不要求鼠标一直压在她身上，细长的全身照也好摸
    var petZone: CGRect {
        let f = window.frame, r = stickerRect.offsetBy(dx: f.minX, dy: f.minY)
        return CGRect(x: r.minX - 14, y: r.minY + r.height * 0.45, width: r.width + 28, height: r.height * 0.55 + 12)
    }

    func updatePetting(now: Double) {
        let p = mouse
        let over = playing == nil && home == nil && dragStart == nil && motion == nil && !stickerLayer.isHidden
            && (fakeMouse != nil || NSEvent.pressedMouseButtons == 0) && petZone.contains(p)
        guard over else { rub.strokes = []; rub.travel = 0; rub.dir = 0; rub.lastX = p.x; return }
        let dx = p.x - rub.lastX
        rub.lastX = p.x
        guard abs(dx) > 0.3 else { return }
        let dir = dx > 0 ? 1 : -1
        if dir != rub.dir {
            if rub.travel > 6 { rub.strokes.append(now) }
            rub.dir = dir
            rub.travel = 0
        }
        rub.travel += abs(dx)
        rub.strokes.removeAll { now - $0 > 1.5 }
        guard rub.strokes.count >= 2 else { return }
        if asleep { wakeUp(); return }
        if walking { restWalk() }
        if now - rub.lastHeart > 0.18 { rub.lastHeart = now; spawnHeart() }
        if expression != Face.happy { say(["好舒服～", "再摸一下", "嘿嘿", "头发要乱了啦"].randomElement()!, force: true) }
        show(face: Face.happy, for: 2.5)
    }

    // MARK: 鼠标靠近

    /// 鼠标靠近她：身体往鼠标那边歪；刚靠过来的时候跳一下、头上冒「！」，偶尔搭句话；在散步的话停下来看你
    func updateNotice(now: Double, dt: Double) {
        var target: CGFloat = 0
        let calm = playing == nil && home == nil && dragStart == nil && motion == nil && !asleep && !stickerLayer.isHidden
        if calm {
            let p = mouse, f = window.frame, r = stickerRect.offsetBy(dx: f.minX, dy: f.minY)
            let c = CGPoint(x: r.midX, y: r.minY + r.height * 0.7)
            let dx = p.x - c.x, d = hypot(dx, p.y - c.y)
            let reach = max(r.width, r.height) * 0.5 + 150
            let near = d < reach
            let onHer = r.insetBy(dx: -14, dy: -14).contains(p)
            if near && !onHer {
                let closeness = 1 - d / reach
                target = -(dx / max(d, 1)) * 0.15 * (0.4 + 0.6 * closeness)   // 往右边歪是顺时针，角度为负
            }
            if near && !mouseNear && now - lastNotice > 5 {
                lastNotice = now
                notice()
            }
            mouseNear = near
        } else {
            mouseNear = false
        }
        lean += (target - lean) * min(1, CGFloat(dt) * 6)
    }

    func notice() {
        if walking { restWalk(); walkPhaseEnd = CACurrentMediaTime() + 4 }
        let jump = CAKeyframeAnimation(keyPath: "transform.translation.y")
        jump.values = [0, 12, 0]
        jump.keyTimes = [0, 0.4, 1]
        jump.duration = 0.3
        stickerLayer.add(jump, forKey: "notice")
        float("!", size: 26, color: .systemYellow, from: CGPoint(x: fx.frame.width / 2, y: headTop + 4),
              drift: CGVector(dx: 0, dy: 28), duration: 0.9)
        if Double.random(in: 0...1) < 0.35 { say(["嗯？", "看我干嘛", "嗨～", "你要摸我吗", "被我发现了"].randomElement()!) }
    }

    // MARK: 重力

    static let gravity: CGFloat = 2600

    func updateMotion(dt: Double) {
        guard var m = motion, playing == nil else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(m.pos) } ?? window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame, half = stickerSize.width / 2, h = stickerSize.height, dt = CGFloat(dt)
        m.vel.dy -= Pet.gravity * dt
        let prevY = m.pos.y
        m.pos.x += m.vel.dx * dt
        m.pos.y += m.vel.dy * dt
        m.fallStartY = max(m.fallStartY, m.pos.y)
        // 撞到屏幕边：弹回来，压扁一下
        if m.pos.x < v.minX + half { m.pos.x = v.minX + half; if m.vel.dx < -250 { bump(horizontal: true) }; m.vel.dx = abs(m.vel.dx) * 0.55 }
        if m.pos.x > v.maxX - half { m.pos.x = v.maxX - half; if m.vel.dx > 250 { bump(horizontal: true) }; m.vel.dx = -abs(m.vel.dx) * 0.55 }
        if m.pos.y + h > v.maxY { m.pos.y = v.maxY - h; if m.vel.dy > 250 { bump(horizontal: false) }; m.vel.dy = -abs(m.vel.dy) * 0.4 }
        // 往下掉的时候穿过了能站的地方（窗口顶边或者屏幕底部）：摔得重就弹一下，不重就站住
        if m.vel.dy <= 0 {
            let s = surfaceBelow(x: m.pos.x, top: prevY + 0.5, screen: screen)
            if m.pos.y <= s.y {
                m.pos.y = s.y
                if m.vel.dy < -1000 {
                    m.vel.dy = -m.vel.dy * 0.32
                    m.vel.dx *= 0.7
                    bump(horizontal: false)
                } else {
                    motion = nil
                    move(anchor: m.pos)
                    land(on: s.perch, drop: m.fallStartY - m.pos.y)
                    return
                }
            }
        }
        motion = m
        move(anchor: m.pos)
    }

    func land(on p: Perch?, drop: CGFloat) {
        perch = p
        pinned = false
        restWalk()
        savePosition()
        bump(horizontal: false)
        if drop > 260 {
            show(face: Face.crazy, for: 2.2)
            say(["哎哟", "头好晕", "摔死我了", "屁股好痛"].randomElement()!, force: true)
        } else {
            show(face: nil)
        }
    }

    /// 撞墙、落地：身体压扁一下再弹回来，配一声「啵」
    func bump(horizontal: Bool) {
        let a = CAKeyframeAnimation(keyPath: "transform")
        let (sx, sy): (CGFloat, CGFloat) = horizontal ? (0.8, 1.12) : (1.18, 0.78)
        a.values = [CATransform3DIdentity, CATransform3DMakeScale(sx, sy, 1), CATransform3DMakeScale(2 - sx * 0.97, 2 - sy * 0.97, 1), CATransform3DIdentity]
        a.keyTimes = [0, 0.3, 0.65, 1]
        a.duration = 0.25
        stickerLayer.add(a, forKey: "bump")
        sound("Pop", 0.35)
    }

    func startFall(from a: NSPoint) {
        walking = false
        walkDir = 0
        walkPos = nil
        motion = Motion(pos: a, vel: .zero, fallStartY: a.y)
    }

    /// 每隔一会儿看看脚下：站着的窗口被挪了、关了、被挡住了就掉下去；悬在半空也掉下去
    func checkSupport() {
        guard gravityOn, !pinned, motion == nil, dragStart == nil, playing == nil, home == nil else { return }
        let a = walkPos ?? anchor
        let screen = NSScreen.screens.first { $0.frame.contains(a) } ?? NSScreen.main ?? NSScreen.screens[0]
        let s = surfaceBelow(x: a.x, top: a.y + 0.5, screen: screen)
        if let p = perch {
            let w = windows().first { $0.id == p.id }
            let same = w.map { abs($0.frame.minX - p.frame.minX) < 1 && abs($0.frame.maxY - p.frame.maxY) < 1 && abs($0.frame.width - p.frame.width) < 1 } ?? false
            if same && s.perch?.id == p.id { return }
            perch = nil
            startFall(from: a)
            if w != nil { say(["哇！", "地震了？", "别挪我的窗！"].randomElement()!, force: true) }
            return
        }
        if a.y > s.y + 1 {
            startFall(from: a)
        } else if a.y < s.y - 1 && s.perch == nil {
            move(anchor: NSPoint(x: a.x, y: s.y))      // 陷到 Dock 后面去了：站回地面上
        } else if let p = s.perch {
            perch = p
        }
    }

    /// x 这个位置、不高于 top 的地方里，最高的那个能站的面：没被挡住的窗口顶边，或者屏幕底部（Dock 上面）
    func surfaceBelow(x: CGFloat, top: CGFloat, screen: NSScreen) -> (y: CGFloat, perch: Perch?) {
        var best: (y: CGFloat, perch: Perch?) = (screen.visibleFrame.minY, nil)
        let ws = windows()
        for (i, w) in ws.enumerated() {
            let f = w.frame
            guard f.minX + 10 <= x, x <= f.maxX - 10, f.maxY <= top, f.maxY > best.y,
                  f.maxY < screen.visibleFrame.maxY - 60, screen.frame.contains(CGPoint(x: x, y: f.maxY - 1)) else { continue }
            // 顶边这一点被前面的窗口盖住了，或者正上方紧挨着前面的窗口：站不了
            let covered = ws[..<i].contains { $0.frame.contains(CGPoint(x: x, y: f.maxY - 3)) || $0.frame.contains(CGPoint(x: x, y: f.maxY + 8)) }
            if !covered { best = (f.maxY, Perch(id: w.id, frame: f)) }
        }
        return best
    }

    /// 屏幕上别的 app 的普通窗口（从前到后），换算成左下角为原点的屏幕坐标；0.12 秒内重复问直接用上次的
    func windows() -> [(id: Int, frame: CGRect)] {
        let now = CACurrentMediaTime()
        if now - windowCacheTime < 0.12 { return windowCache }
        windowCacheTime = now
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            windowCache = []
            return []
        }
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        let primaryH = NSScreen.screens[0].frame.height
        windowCache = list.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.2,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b),
                  r.width >= 160, r.height >= 100,
                  let id = w[kCGWindowNumber as String] as? Int else { return nil }
            return (id, CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height))
        }
        return windowCache
    }

    // MARK: 自己找事做

    var idleEvery: Double = 35

    func scheduleAutoScene() {
        nextAutoScene = CACurrentMediaTime() + (autoScene == 2 ? .random(in: 240...360) : .random(in: 720...1080))
    }

    func updateIdle(now: Double) {
        guard playing == nil, motion == nil, dragStart == nil, !asleep, home == nil else { return }
        if autoScene > 0, now >= nextAutoScene {
            scheduleAutoScene()
            say("看我表演！", force: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self, self.playing == nil, !self.asleep else { return }
                self.play(SceneID.allCases.randomElement()!)
            }
            return
        }
        guard now >= nextIdleAct else { return }
        nextIdleAct = now + .random(in: idleEvery * 0.7...idleEvery * 1.4)
        // 你正在摸她或者鼠标停在她身上，就不打扰
        if mouseNear { return }
        var acts: [(weight: Int, run: () -> Void)] = [
            (2, { [unowned self] in self.say(Pet.idleLines.randomElement()!) }),
            (2, { [unowned self] in self.makeFace() }),
            (1, { [unowned self] in self.turnAround() }),
            (1, { [unowned self] in self.hop() }),
        ]
        if gravityOn && !pinned {
            if let target = jumpTarget() { acts.append((4, { [unowned self] in self.jump(to: target) })) }
            if perch != nil { acts.append((2, { [unowned self] in self.jumpDown() })) }
        }
        var pick = Int.random(in: 0..<acts.map(\.weight).reduce(0, +))
        for a in acts {
            if pick < a.weight { a.run(); break }
            pick -= a.weight
        }
    }

    /// 做个鬼脸：随便换成另一张表情包几秒
    func makeFace() {
        let others = memes.indices.filter { $0 != memeIndex && $0 != Face.sleepy }
        show(face: others.randomElement()!, for: 3)
    }

    /// 转个身：左右翻过去再翻回来
    func turnAround() {
        let flip = CAKeyframeAnimation(keyPath: "transform.scale.x")
        flip.values = [1, -1, -1, 1]
        flip.keyTimes = [0, 0.2, 0.8, 1]
        flip.duration = 1.4
        stickerLayer.add(flip, forKey: "flip")
    }

    /// 原地蹦两下
    func hop() {
        let jump = CAKeyframeAnimation(keyPath: "transform.translation.y")
        jump.values = [0, 24, 0, 14, 0]
        jump.keyTimes = [0, 0.25, 0.5, 0.75, 1]
        jump.duration = 0.75
        stickerLayer.add(jump, forKey: "hop")
        sound("Pop", 0.2)
    }

    /// 附近有比她高、够得着的窗口顶边，就挑一个跳上去
    func jumpTarget() -> NSPoint? {
        let a = anchor
        let screen = NSScreen.screens.first { $0.frame.contains(a) } ?? NSScreen.main ?? NSScreen.screens[0]
        let area = playArea(on: screen)
        let spots = windows().compactMap { w -> NSPoint? in
            let f = w.frame
            guard f.maxY > a.y + 40, f.maxY < a.y + 520, f.maxY + stickerSize.height < screen.visibleFrame.maxY - 10 else { return nil }
            let x = min(max(a.x + .random(in: -60...60), f.minX + 40), f.maxX - 40)
            guard abs(x - a.x) < 450, area.contains(CGPoint(x: x, y: f.maxY)) else { return nil }
            guard surfaceBelow(x: x, top: f.maxY + 0.5, screen: screen).perch?.id == w.id else { return nil }
            return NSPoint(x: x, y: f.maxY)
        }
        return spots.randomElement()
    }

    /// 抛物线跳到目标点：先算出正好落在那里的起跳速度，后面交给重力
    func jump(to t: NSPoint) {
        let a = anchor, g = Pet.gravity
        let apex = max(t.y, a.y) + 70
        let vy = (2 * g * (apex - a.y)).squareRoot()
        let time = vy / g + (2 * (apex - t.y) / g).squareRoot()
        perch = nil
        walking = false
        walkDir = 0
        walkPos = nil
        bump(horizontal: false)
        say(["嘿咻", "上去看看", "我要站高高"].randomElement()!)
        motion = Motion(pos: a, vel: CGVector(dx: (t.x - a.x) / time, dy: vy), fallStartY: a.y)
    }

    /// 从窗口上跳下去
    func jumpDown() {
        let a = anchor
        perch = nil
        walking = false
        walkDir = 0
        walkPos = nil
        motion = Motion(pos: a, vel: CGVector(dx: (Bool.random() ? 1 : -1) * 280, dy: 520), fallStartY: a.y)
    }

    // MARK: 睡觉

    func updateSleep(now: Double) {
        guard now - lastIdleCheck > 1 else { return }
        lastIdleCheck = now
        // 离上一次动鼠标、按键盘过了多久（不需要额外权限）
        let types: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel, .leftMouseDragged]
        let idle = types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
        if asleep {
            if idle < 2 { wakeUp() }
        } else if sleepOn, idle > sleepAfter, playing == nil, motion == nil, dragStart == nil {
            fallAsleep()
        }
    }

    func fallAsleep() {
        asleep = true
        restWalk()
        show(face: Face.sleepy)
    }

    func wakeUp() {
        guard asleep else { return }
        asleep = false
        show(face: Face.happy, for: 3)
        say(["你回来啦！", "嗯…我没睡", "早呀", "等你好久了"].randomElement()!, force: true)
        // 伸个懒腰
        let stretch = CAKeyframeAnimation(keyPath: "transform.scale.y")
        stretch.values = [1, 1.12, 0.95, 1]
        stretch.keyTimes = [0, 0.4, 0.75, 1]
        stretch.duration = 0.8
        stickerLayer.add(stretch, forKey: "stretch")
        nextIdleAct = CACurrentMediaTime() + idleEvery
    }

    // MARK: 散步

    func restWalk() {
        walking = false
        walkDir = 0
        walkPos = nil
        walkPhaseEnd = CACurrentMediaTime() + 3
    }

    func updateWalk(now: Double, dt: Double) {
        guard walkEnabled, playing == nil, dragStart == nil, motion == nil, !asleep, !(gravityOn && pinned) else {
            if walking { restWalk() }
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let area = playArea(on: screen)
        var minX = max(vf.minX, area.minX), maxX = min(vf.maxX, area.maxX)
        // 站在窗口上时，只在窗口顶边上来回走
        if let p = perch { minX = max(minX, p.frame.minX + 12); maxX = min(maxX, p.frame.maxX - 12) }
        let ground = perch?.frame.maxY ?? vf.minY
        let edge = min(200, (maxX - minX) / 4)
        var a = walkPos ?? anchor
        if now >= walkPhaseEnd {
            if walkDir == 0 {
                // 休息完了开始走：靠近边缘就往回走，否则随机选方向
                walkDir = a.x < minX + edge ? 1 : a.x > maxX - edge ? -1 : (Bool.random() ? 1 : -1)
                walkPhaseEnd = now + Double.random(in: 4...8)
            } else {
                walkDir = 0
                walkPhaseEnd = now + Double.random(in: 2...5)
                savePosition()
            }
        }
        walking = walkDir != 0
        guard walking else { return }
        if !gravityOn && a.y > ground + 0.5 {
            a.y = max(ground, a.y - 500 * dt)   // 关了重力：被拖到半空的话，先慢慢落回地面再走
        } else {
            a.x += walkDir * 75 * base / 280 * dt
            let half = perch == nil ? stickerSize.width / 2 : 0     // 在窗口上：脚还在窗口范围里就行
            if a.x < minX + half { a.x = minX + half; walkDir = 1 }
            if a.x > maxX - half { a.x = maxX - half; walkDir = -1 }
        }
        walkPos = a
        move(anchor: a)
    }

    // MARK: 竖屏区域

    /// 能活动的范围：平时是整块屏幕，打开「竖屏」后只在屏幕最右边一块 9:16 的竖条里
    func playArea(on screen: NSScreen) -> CGRect {
        let f = screen.frame
        guard portraitOnly else { return f }
        let w = min(f.width, f.height * 9 / 16)
        return CGRect(x: f.maxX - w, y: f.minY, width: w, height: f.height)
    }

    /// 打开竖屏时，把她挪到竖条正中间
    func moveIntoPlayArea() {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let area = playArea(on: screen)
        restWalk()
        if let h = home { home = NSPoint(x: area.midX, y: h.y); savePosition(); return }
        let origin = NSPoint(x: area.midX - window.frame.width / 2, y: anchor.y)
        window.setFrame(NSRect(origin: origin, size: window.frame.size), display: true, animate: true)
        savePosition()
    }

    // MARK: 演名场面时把按钮条挪开

    /// 按钮条挪到名场面画面外面：优先放正上方，上面没地方就放左边或右边（和画面顶部对齐）
    func parkBar(beside scene: CGRect) {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame, size = ButtonBar.size, gap: CGFloat = 6
        var origin: NSPoint
        if scene.maxY + gap + size.height <= v.maxY {
            origin = NSPoint(x: min(max(scene.midX - size.width / 2, v.minX), v.maxX - size.width), y: scene.maxY + gap)
        } else {
            let y = min(max(scene.maxY - size.height, v.minY), v.maxY - size.height)
            if scene.minX - gap - size.width >= v.minX {
                origin = NSPoint(x: scene.minX - gap - size.width, y: y)
            } else if scene.maxX + gap + size.width <= v.maxX {
                origin = NSPoint(x: scene.maxX + gap, y: y)
            } else {
                origin = NSPoint(x: scene.minX + gap, y: scene.maxY - size.height - gap)   // 实在没地方，就放在画面左上角
            }
        }
        if home == nil { home = NSPoint(x: window.frame.midX, y: window.frame.minY) }
        singButton.isHidden = true
        window.setFrame(NSRect(x: origin.x - 2, y: origin.y - 2, width: size.width + 4, height: size.height + 4), display: true)
        bar.frame = barRect
    }

    /// 演完了：按钮条回到她头顶
    func unparkBar() {
        guard let h = home else { return }
        home = nil
        layout(anchor: h)
    }

    // MARK: 名场面

    /// 名场面面板在屏幕上的位置（frame）和画布在面板里的位置（canvas）
    func sceneGeometry(_ scene: Scene) -> (frame: CGRect, canvas: CGRect) {
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let area = playArea(on: screen)
        if scene.corner {
            // 秋千就在她现在站的地方：秋千架立在她脚下，她从左边荡进来、往右荡
            // 原视频里她会荡出画面左边，这一侧做了渐隐（见 startScene），不会突然被切掉
            let ground = screen.visibleFrame.minY
            let h = min((screen.frame.maxY - ground) * Pet.swingHeights[sizeIndex], screen.frame.maxY - anchor.y), w = h * scene.sprite.aspect
            let x = min(max(anchor.x - w * 0.42, area.minX), area.maxX - w)
            let frame = CGRect(x: x, y: anchor.y, width: w, height: h).integral
            return (frame, CGRect(origin: .zero, size: frame.size))
        }
        // 原地演：脚底（或者半身的底边）站在她现在的位置，左右不出屏幕；字幕比她宽的话面板也跟着加宽
        let h = base * scene.heightFactor, w = h * scene.sprite.aspect
        let k = h / scene.sprite.pixelSize.height * Pet.subtitleZoom
        let mid = scene.sprite.pixelSize.width / 2
        let subsW: CGFloat = scene.subs.map { (sub: (image: CGImage, rect: CGRect)) -> CGFloat in
            max(abs(sub.rect.minX - mid), abs(sub.rect.maxX - mid)) * 2 * k
        }.max() ?? 0
        // 画框四周留出余量：跟着唱时会摇摆、蹦高，换镜头时会弹一下，超出画框的部分会被裁掉
        let side = scene.singer ? h * 0.16 : w * 0.04, top = scene.singer ? h * 0.12 : h * 0.07
        let pw = max(w + side * 2, subsW + 8)
        let x = pw < area.width ? min(max(anchor.x - pw / 2, area.minX), area.maxX - pw) : area.midX - pw / 2
        let frame = CGRect(x: x, y: anchor.y, width: pw, height: h + top).integral
        return (frame, CGRect(x: (frame.width - w) / 2, y: 0, width: w, height: h))
    }

    /// 字幕比原视频里放大一些，桌面上才看得清
    static let subtitleZoom: CGFloat = 1.6

    /// 第几句字幕在面板里的位置：画布像素 → 面板坐标（以画布底边中点为中心放大）
    func subtitleFrame(_ scene: Scene, _ sub: Int, canvas: CGRect) -> CGRect {
        let k = canvas.height / scene.sprite.pixelSize.height * Pet.subtitleZoom, r = scene.subs[sub].rect
        let mid = scene.sprite.pixelSize.width / 2
        return CGRect(x: canvas.midX + (r.minX - mid) * k, y: canvas.minY + r.minY * k, width: r.width * k, height: r.height * k)
    }

    func startScene(_ id: SceneID) {
        guard let scene = scenes[id] else { return }
        restWalk()
        motion = nil
        asleep = false
        expression = nil
        let (frame, canvas) = sceneGeometry(scene)
        let panel = overlayPanel(frame)
        let root = panel.contentView!.layer!
        let stage = CALayer()
        stage.frame = canvas
        stage.anchorPoint = CGPoint(x: 0.5, y: 0)       // 换镜头时以脚底为轴弹一下
        stage.position = CGPoint(x: canvas.midX, y: canvas.minY)
        root.addSublayer(stage)
        if let rig = scene.rig {
            let l = CALayer()
            l.frame = stage.bounds
            l.contents = rig
            l.contentsGravity = .resize
            stage.addSublayer(l)
        }
        let frameLayer = CALayer()
        frameLayer.frame = stage.bounds
        frameLayer.contentsGravity = .resize
        frameLayer.contents = scene.sprite.image(0)
        stage.addSublayer(frameLayer)
        if scene.corner {
            // 秋千：左边和底边渐隐，她荡出画面时是慢慢淡出，而不是被一刀切掉
            let fade = CAGradientLayer()
            fade.frame = stage.bounds
            fade.startPoint = CGPoint(x: 0, y: 0.5)
            fade.endPoint = CGPoint(x: 1, y: 0.5)
            fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor]
            fade.locations = [0, 0.09]
            stage.mask = fade
        }
        let subLayer = CALayer()
        subLayer.contentsGravity = .resize
        subLayer.isHidden = true
        root.addSublayer(subLayer)

        var player: AVAudioPlayer?
        if soundOn {
            do {
                let p = try AVAudioPlayer(contentsOf: scene.audio)
                p.isMeteringEnabled = scene.shake || scene.singer
                p.volume = volumeScale
                let ok = p.play()
                player = p
                if debug { print("声音 \(scene.audio.lastPathComponent)：时长 \(p.duration) 秒，开始播放 \(ok)") }
            } catch {
                print("声音打不开：\(scene.audio.path) \(error)")
            }
        } else if debug {
            print("声音开关是关的")
        }
        playing = Playing(id: id, scene: scene, panel: panel, stage: stage, frameLayer: frameLayer, subLayer: subLayer, player: player,
                          start: CACurrentMediaTime(), origin: frame.origin)
        if scene.singer {
            playing?.duration = player?.duration ?? (try? AVAudioPlayer(contentsOf: scene.audio))?.duration ?? 10
        }

        // 贴纸「噗」一下变没，名场面淡入
        let center = NSPoint(x: anchor.x, y: anchor.y + stickerSize.height / 2)
        burst(at: center, radius: max(stickerSize.width, stickerSize.height) * 0.7)
        popOut()
        // 贴纸「噗」完再把按钮条挪开，不挡画面；她右脚边出现「停止」按钮（和「唱 Good 4 U」同一个位置）
        let screenVF = (window.screen ?? NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let canvasOnScreen = canvas.offsetBy(dx: frame.minX, dy: frame.minY)
        let stopOrigin = NSPoint(x: min(canvasOnScreen.maxX - 12, screenVF.maxX - SingButton.size.width - 4), y: max(frame.minY + 6, screenVF.minY + 2))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.playing?.id == id else { return }
            self.parkBar(beside: frame)
            self.stopPanel.setFrameOrigin(stopOrigin)
            self.stopPanel.orderFrontRegardless()
        }
        root.opacity = 0
        panel.orderFrontRegardless()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.2
        root.add(fade, forKey: "fade")
        root.opacity = 1
    }

    func updateScene(now: Double) {
        guard var p = playing else { return }
        if p.scene.singer {
            updateSinger(&p, now: now)
            if playing != nil { playing = p }
            return
        }
        let i = Int((now - p.start) * fps * p.scene.speed)
        if i >= p.scene.sprite.count {
            endScene()
            return
        }
        if i != p.shown {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            p.frameLayer.contents = p.scene.sprite.image(i)
            // 字幕：画布像素 → 面板坐标
            let sub = i < p.scene.subIndex.count ? p.scene.subIndex[i] : -1
            if sub != p.shownSub {
                p.shownSub = sub
                p.subLayer.isHidden = sub < 0
                if sub >= 0 {
                    p.subLayer.contents = p.scene.subs[sub].image
                    p.subLayer.frame = subtitleFrame(p.scene, sub, canvas: p.stage.frame)
                }
            }
            CATransaction.commit()
            // 原视频换镜头的那一帧：轻轻弹一下，切换不那么生硬
            if p.scene.cuts.contains(i) && p.shown < i {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                pop.values = [1.06, 0.98, 1]
                pop.duration = 0.2
                p.stage.add(pop, forKey: "cut")
            }
            // VMA：她一拳砸过来，屏幕裂了
            if let c = p.scene.crackAt, i >= c, p.shown < c {
                let f = p.panel.frame
                smashScreen(at: NSPoint(x: f.midX + f.width * 0.08, y: f.minY + f.height * 0.62), on: p.panel.screen ?? NSScreen.main!)
            }
            p.shown = i
            playing = p
        }
        if p.scene.shake {
            // 震屏：音乐越响抖得越厉害
            var level: CGFloat = 0.5
            if let player = p.player {
                player.updateMeters()
                level = CGFloat(min(1, max(0, (player.averagePower(forChannel: 0) + 26) / 20)))
            }
            let amp = level * level * 10 * base / 280
            p.panel.setFrameOrigin(NSPoint(x: p.origin.x + .random(in: -amp...amp), y: p.origin.y + .random(in: 0...amp)))
        }
    }

    /// 跟着唱：音量越大蹦得越高，身体左右摇，唱得响的时候头上冒音符
    func updateSinger(_ p: inout Playing, now: Double) {
        let t = now - p.start
        if t >= p.duration { endScene(); return }
        var target: CGFloat = 0.55
        if let player = p.player {
            player.updateMeters()
            target = CGFloat(min(1, max(0, (player.averagePower(forChannel: 0) + 30) / 22)))
        }
        p.level += (target - p.level) * 0.25
        let lv = p.level
        let sway = CGFloat(sin(t * 2 * .pi * 0.9)) * (0.03 + 0.05 * lv)
        let bob = CGFloat(abs(sin(t * 2 * .pi * 1.8))) * (0.015 + 0.06 * lv)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        p.stage.setAffineTransform(CGAffineTransform(rotationAngle: sway).scaledBy(x: 1 - bob * 0.4, y: 1 + bob))
        CATransaction.commit()
        if lv > 0.3, now - p.lastNote > 0.32 - Double(lv) * 0.12 {
            p.lastNote = now
            let f = p.panel.frame
            let colors: [NSColor] = [.systemPurple, .systemPink, NSColor(srgbRed: 0.75, green: 0.5, blue: 1, alpha: 1), .white]
            float(["♪", "♫", "♬", "♩"].randomElement()!, size: .random(in: 18...28), color: colors.randomElement()!,
                  from: CGPoint(x: f.midX + .random(in: -0.35...0.35) * p.stage.bounds.width - fx.frame.minX,
                                y: f.minY + p.stage.bounds.height * 0.9 - fx.frame.minY),
                  drift: CGVector(dx: .random(in: -40...40), dy: .random(in: 70...120)), duration: 1.4)
        }
    }

    func endScene() {
        guard let p = playing else { return }
        playing = nil
        stopPanel.orderOut(nil)
        if let player = p.player {
            player.setVolume(0, fadeDuration: 0.25)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { player.stop() }
        }
        let root = p.panel.contentView!.layer!
        CATransaction.begin()
        CATransaction.setCompletionBlock { p.panel.orderOut(nil) }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.2
        root.add(fade, forKey: "fade")
        root.opacity = 0
        CATransaction.commit()
        // 裂开的屏幕多留一会儿再慢慢消失
        if let c = crack {
            crack = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                CATransaction.begin()
                CATransaction.setCompletionBlock { c.orderOut(nil) }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 0.6
                c.contentView!.layer!.add(fade, forKey: "fade")
                c.contentView!.layer!.opacity = 0
                CATransaction.commit()
            }
        }
        unparkBar()
        let center = NSPoint(x: anchor.x, y: anchor.y + stickerSize.height / 2)
        burst(at: center, radius: max(stickerSize.width, stickerSize.height) * 0.7)
        popIn()
        restWalk()
        bar.needsDisplay = true
        if debug { log("名场面结束") }
    }

    /// 调试用：不上屏幕，直接把某个名场面的第几帧（连字幕、碎玻璃）合成到桌面壁纸上存成图片
    func snapshot(_ id: SceneID, frame i: Int, to url: URL) {
        guard let scene = scenes[id] else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.frame, (frame, canvas) = sceneGeometry(scene)
        let ctx = CGContext(data: nil, width: Int(f.width), height: Int(f.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let u = NSWorkspace.shared.desktopImageURL(for: screen), let wp = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            ctx.draw(wp, in: CGRect(origin: .zero, size: f.size))
        } else {
            ctx.setFillColor(CGColor(gray: 0.6, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: f.size))
        }
        let origin = CGPoint(x: frame.minX - f.minX, y: frame.minY - f.minY)
        if let rig = scene.rig { ctx.draw(rig, in: canvas.offsetBy(dx: origin.x, dy: origin.y)) }
        if let img = scene.sprite.image(i) { ctx.draw(img, in: canvas.offsetBy(dx: origin.x, dy: origin.y)) }
        if i < scene.subIndex.count, scene.subIndex[i] >= 0 {
            let sub = scene.subIndex[i]
            ctx.draw(scene.subs[sub].image, in: subtitleFrame(scene, sub, canvas: canvas).offsetBy(dx: origin.x, dy: origin.y))
        }
        if let c = scene.crackAt, i >= c {
            ctx.draw(crackImage(size: f.size, center: CGPoint(x: frame.midX + frame.width * 0.08 - f.minX, y: frame.minY + frame.height * 0.62 - f.minY), scale: 1),
                     in: CGRect(origin: .zero, size: f.size))
        }
        ctx.setStrokeColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        ctx.stroke(frame.offsetBy(dx: -f.minX, dy: -f.minY))       // 面板范围（红框，只在调试图里有）
        try? NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .jpeg, properties: [.compressionFactor: 0.85])!.write(to: url)
    }

    // MARK: 砸裂屏幕

    /// 整块屏幕盖一层「碎玻璃」：从砸中的地方放射出去的裂纹 + 一圈圈蛛网纹，白光一闪、抖一下
    /// 碎玻璃的样子：从砸中的地方放射出去的裂纹 + 一圈圈蛛网纹 + 中间几块反光的碎片
    func crackImage(size: CGSize, center: CGPoint, scale: CGFloat) -> CGImage {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let c = center
        let far = hypot(size.width, size.height)

        // 放射状的主裂纹：每条都歪歪扭扭地往外走，有长有短
        let rays = Int.random(in: 22...28)
        var paths: [[CGPoint]] = []
        for i in 0..<rays {
            var angle = Double(i) / Double(rays) * 2 * .pi + .random(in: -0.12...0.12)
            let length = far * .random(in: 0.3...1.0)
            var pts = [c], r = 0.0
            while r < length {
                r += .random(in: 22...60)
                angle += .random(in: -0.04...0.04)      // 玻璃裂纹基本是直的，只有一点点抖
                pts.append(CGPoint(x: c.x + cos(angle) * r, y: c.y + sin(angle) * r))
            }
            paths.append(pts)
        }
        func point(_ pts: [CGPoint], at radius: Double) -> CGPoint? {
            for j in 1..<pts.count where hypot(pts[j].x - c.x, pts[j].y - c.y) >= radius { return pts[j] }
            return nil
        }
        // 一圈圈的蛛网纹：相邻两条主裂纹之间连一段折线，有的地方断开
        var rings: [[CGPoint]] = []
        for base in [14.0, 30, 50, 76, 108, 150, 205, 280, 380, 520] {
            for i in 0..<rays where Double.random(in: 0...1) < 0.78 {
                let rr = base * .random(in: 0.85...1.15)
                guard let a = point(paths[i], at: rr), let b = point(paths[(i + 1) % rays], at: rr * .random(in: 0.9...1.1)) else { continue }
                let mid = CGPoint(x: (a.x + b.x) / 2 + .random(in: -7...7), y: (a.y + b.y) / 2 + .random(in: -7...7))
                rings.append([a, mid, b])
            }
        }
        // 中心附近几块碎片反着光
        for i in 0..<rays where Double.random(in: 0...1) < 0.45 {
            guard let a = point(paths[i], at: 30), let b = point(paths[i], at: 110),
                  let d = point(paths[(i + 1) % rays], at: 110), let e = point(paths[(i + 1) % rays], at: 30) else { continue }
            ctx.setFillColor(CGColor(gray: 1, alpha: .random(in: 0.06...0.16)))
            ctx.addLines(between: [a, b, d, e])
            ctx.fillPath()
        }
        // 主裂纹上随机岔出去的小裂纹
        var branches: [[CGPoint]] = []
        for pts in paths { for j in 1..<pts.count where Double.random(in: 0...1) < 0.22 {
            var p = pts[j], a = atan2(pts[j].y - c.y, pts[j].x - c.x) + (Bool.random() ? 1 : -1) * .random(in: 0.4...0.9)
            var b = [p]
            for _ in 0..<Int.random(in: 2...4) {
                a += .random(in: -0.25...0.25)
                p = CGPoint(x: p.x + cos(a) * .random(in: 10...28), y: p.y + sin(a) * .random(in: 10...28))
                b.append(p)
            }
            branches.append(b)
        } }
        // 先画一道暗边再画亮线，像玻璃裂口的反光；离砸中的地方越近线越粗
        for (gray, alpha, width, offset) in [(0.0, 0.4, 2.6, CGPoint(x: -0.8, y: -0.8)), (1.0, 0.95, 1.25, CGPoint.zero)] {
            for pts in paths + rings + branches {
                for j in 1..<pts.count {
                    let d = hypot(pts[j].x - c.x, pts[j].y - c.y)
                    ctx.setStrokeColor(CGColor(gray: gray, alpha: alpha * max(0.4, 1 - d / 1400)))   // 越远越淡
                    ctx.setLineWidth(width * max(0.7, 1.8 - d / 300))
                    ctx.move(to: CGPoint(x: pts[j - 1].x + offset.x, y: pts[j - 1].y + offset.y))
                    ctx.addLine(to: CGPoint(x: pts[j].x + offset.x, y: pts[j].y + offset.y))
                    ctx.strokePath()
                }
            }
        }
        // 砸中的那一点：一团白
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 26, options: [])
        return ctx.makeImage()!
    }

    func smashScreen(at p: NSPoint, on screen: NSScreen) {
        crack?.orderOut(nil)
        let f = screen.frame
        let panel = overlayPanel(f)
        panel.level = .statusBar        // 连菜单栏和 Dock 一起裂
        let root = panel.contentView!.layer!
        let scale = screen.backingScaleFactor
        let image = crackImage(size: f.size, center: CGPoint(x: p.x - f.minX, y: p.y - f.minY), scale: scale)
        let cracks = CALayer()
        cracks.frame = root.bounds
        cracks.contents = image
        cracks.contentsScale = scale
        root.addSublayer(cracks)
        let flash = CALayer()
        flash.frame = root.bounds
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        root.addSublayer(flash)
        let blink = CABasicAnimation(keyPath: "opacity")
        blink.fromValue = 0.75
        blink.toValue = 0
        blink.duration = 0.25
        flash.add(blink, forKey: "flash")
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [1.03, 0.99, 1]
        pop.duration = 0.18
        cracks.add(pop, forKey: "pop")
        panel.orderFrontRegardless()
        crack = panel
        sound("Glass", 0.6)
        // 抖三下
        for (i, dx) in [9.0, -7, 5, -3, 0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03 * Double(i)) { panel.setFrameOrigin(NSPoint(x: f.minX + dx, y: f.minY - dx / 2)) }
        }
    }

    // MARK: 变身特效

    func popOut() {
        stickerLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.playing != nil else { return }
            self.stickerLayer.isHidden = true
        }
        let a = CAKeyframeAnimation(keyPath: "transform.scale")
        a.values = [1, 1.15, 0.01]
        a.keyTimes = [0, 0.35, 1]
        a.duration = 0.22
        a.fillMode = .forwards
        a.isRemovedOnCompletion = false
        stickerLayer.add(a, forKey: "pop")
        CATransaction.commit()
    }

    func popIn() {
        stickerLayer.removeAllAnimations()
        stickerLayer.isHidden = false
        let a = CASpringAnimation(keyPath: "transform.scale")
        a.fromValue = 0.01
        a.toValue = 1
        a.damping = 9
        a.stiffness = 240
        a.duration = a.settlingDuration
        stickerLayer.add(a, forKey: "pop")
    }

    /// 点她一下：压扁再弹回来
    func boing() {
        let a = CAKeyframeAnimation(keyPath: "transform")
        a.values = [CATransform3DIdentity, CATransform3DMakeScale(1.08, 0.88, 1), CATransform3DMakeScale(0.95, 1.06, 1), CATransform3DIdentity]
        a.keyTimes = [0, 0.3, 0.65, 1]
        a.duration = 0.32
        stickerLayer.add(a, forKey: "boing")
        sound("Pop", 0.4)
    }

    func sound(_ name: String, _ volume: Float) {
        guard soundOn, let s = NSSound(named: name)?.copy() as? NSSound else { return }
        s.volume = volume
        s.play()
    }

    /// 「噗」：一团白烟加一圈小星星和小圆点往外炸开
    func burst(at p: NSPoint, radius r: CGFloat) {
        let panel = overlayPanel(NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
        let root = panel.contentView!.layer!
        let c = CGPoint(x: r, y: r)
        let now = CACurrentMediaTime()

        let puff = CALayer()
        puff.bounds = CGRect(x: 0, y: 0, width: r * 0.7, height: r * 0.7)
        puff.cornerRadius = r * 0.35
        puff.position = c
        puff.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
        puff.opacity = 0
        root.addSublayer(puff)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.7
        let fadePuff = CAKeyframeAnimation(keyPath: "opacity")
        fadePuff.values = [0.9, 0.6, 0]
        let puffGroup = CAAnimationGroup()
        puffGroup.animations = [grow, fadePuff]
        puffGroup.duration = 0.45
        puffGroup.timingFunction = CAMediaTimingFunction(name: .easeOut)
        puff.add(puffGroup, forKey: "puff")

        let colors: [NSColor] = [.systemPink, .white, .systemYellow, NSColor(srgbRed: 1, green: 0.55, blue: 0.75, alpha: 1), .systemPurple]
        let count = 16
        for i in 0..<count {
            let size = CGFloat.random(in: 0.07...0.13) * r
            let shape = CAShapeLayer()
            shape.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            shape.position = c
            shape.fillColor = colors[i % colors.count].cgColor
            if i % 2 == 0 {
                // 四角星
                let path = CGMutablePath(), m = size / 2, k = size * 0.12
                path.move(to: CGPoint(x: m, y: 0))
                path.addQuadCurve(to: CGPoint(x: size, y: m), control: CGPoint(x: m + k, y: m - k))
                path.addQuadCurve(to: CGPoint(x: m, y: size), control: CGPoint(x: m + k, y: m + k))
                path.addQuadCurve(to: CGPoint(x: 0, y: m), control: CGPoint(x: m - k, y: m + k))
                path.addQuadCurve(to: CGPoint(x: m, y: 0), control: CGPoint(x: m - k, y: m - k))
                shape.path = path
            } else {
                shape.path = CGPath(ellipseIn: shape.bounds.insetBy(dx: size * 0.2, dy: size * 0.2), transform: nil)
            }
            shape.opacity = 0
            root.addSublayer(shape)
            let angle = Double(i) / Double(count) * 2 * .pi + .random(in: -0.2...0.2)
            let dist = r * .random(in: 0.55...0.92)
            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = c
            move.toValue = CGPoint(x: c.x + cos(angle) * dist, y: c.y + sin(angle) * dist)
            move.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.8, 0.3, 1)
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.2
            shrink.toValue = 0.3
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.6, 1]
            let g = CAAnimationGroup()
            g.animations = [move, shrink, fade]
            g.duration = .random(in: 0.45...0.6)
            g.beginTime = now + .random(in: 0...0.05)
            g.fillMode = .backwards
            shape.add(g, forKey: "fly")
        }
        panel.orderFrontRegardless()
        sound("Pop", 0.35)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { panel.orderOut(nil) }
    }

    // MARK: 鼠标

    func mouseDown() {
        dragStart = NSEvent.mouseLocation
        dragAnchorStart = anchor
        dragged = false
        dragTrail = [(CACurrentMediaTime(), NSEvent.mouseLocation)]
    }

    func mouseDragged() {
        guard let s = dragStart, home == nil else { return }    // 名场面演的时候按钮条不能拖
        let p = NSEvent.mouseLocation
        if !dragged && hypot(p.x - s.x, p.y - s.y) < 4 { return }
        if !dragged { dragged = true; beginHold() }
        let now = CACurrentMediaTime()
        dragTrail.append((now, p))
        dragTrail.removeAll { now - $0.t > 0.15 }
        move(anchor: NSPoint(x: dragAnchorStart.x + p.x - s.x, y: dragAnchorStart.y + p.y - s.y))
    }

    func mouseUp() {
        if dragged {
            endHold()
        } else if asleep {
            wakeUp()
        } else if playing == nil {
            clicked()
        }
        dragStart = nil
        restWalk()
    }

    // MARK: 录屏背景

    static let backdrops = ["关闭", "干净桌面（只留壁纸，遮住窗口和图标）", "绿幕（方便后期抠图）"]
    var backdrop: NSPanel?
    var backdropIndex = 0

    /// 在所有普通窗口上面、桌宠下面铺一层背景：当前桌面壁纸（看起来就是一个干净的桌面）或者绿幕
    @objc func setBackdrop(_ item: NSMenuItem) {
        backdropIndex = item.tag
        backdrop?.orderOut(nil)
        backdrop = nil
        guard item.tag > 0 else { return }
        let screen = window.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = item.tag == 2 ? NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1) : .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let v = BackdropView()
        v.pet = self
        if item.tag == 1, let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let wallpaper = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            // 和系统铺壁纸的方式一样：等比例铺满屏幕，多出来的裁掉
            v.wantsLayer = true
            v.layer!.contents = wallpaper
            v.layer!.contentsGravity = .resizeAspectFill
            v.layer!.masksToBounds = true
        }
        panel.contentView = v
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
        backdrop = panel
    }

    func showMenu(_ e: NSEvent, in v: NSView) {
        let menu = NSMenu()
        let credit = NSMenuItem(title: "制作：小红书 @\(authorName)", action: #selector(openAuthor), keyEquivalent: "")
        credit.target = self
        menu.addItem(credit)
        menu.addItem(.separator())
        let backdropMenu = NSMenu()
        for (i, title) in Pet.backdrops.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setBackdrop(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == backdropIndex ? .on : .off
            backdropMenu.addItem(item)
        }
        let backdropItem = NSMenuItem(title: "录屏背景", action: nil, keyEquivalent: "")
        backdropItem.submenu = backdropMenu
        menu.addItem(backdropItem)
        menu.addItem(.separator())
        for (i, (title, _)) in Pet.sizes.enumerated() {
            let item = NSMenuItem(title: "\(title)号", action: #selector(setSize(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == sizeIndex ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let soundItem = NSMenuItem(title: "声音", action: #selector(toggleSound), keyEquivalent: "")
        soundItem.target = self
        soundItem.state = soundOn ? .on : .off
        menu.addItem(soundItem)
        let gravityItem = NSMenuItem(title: "重力（松手会掉下来，会跳上窗口）", action: #selector(toggleGravity), keyEquivalent: "")
        gravityItem.target = self
        gravityItem.state = gravityOn ? .on : .off
        menu.addItem(gravityItem)
        let sleepItem = NSMenuItem(title: "没人理就睡觉（3 分钟）", action: #selector(toggleSleep), keyEquivalent: "")
        sleepItem.target = self
        sleepItem.state = sleepOn ? .on : .off
        menu.addItem(sleepItem)
        let autoMenu = NSMenu()
        for (i, title) in ["不演", "偶尔（大约 15 分钟一次）", "经常（大约 5 分钟一次）"].enumerated() {
            let item = NSMenuItem(title: title, action: #selector(setAutoScene(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = i == autoScene ? .on : .off
            autoMenu.addItem(item)
        }
        let autoItem = NSMenuItem(title: "自己演名场面", action: nil, keyEquivalent: "")
        autoItem.submenu = autoMenu
        menu.addItem(autoItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 Olivia", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        NSMenu.popUpContextMenu(menu, with: e, for: v)
    }

    @objc func openAuthor() {
        NSWorkspace.shared.open(authorURL)
    }

    @objc func toggleGravity() {
        gravityOn.toggle()
        UserDefaults.standard.set(gravityOn, forKey: "gravity")
        if !gravityOn { motion = nil; perch = nil; pinned = false }
    }

    @objc func toggleSleep() {
        sleepOn.toggle()
        UserDefaults.standard.set(sleepOn, forKey: "sleep")
        if !sleepOn && asleep { wakeUp() }
    }

    @objc func setAutoScene(_ item: NSMenuItem) {
        autoScene = item.tag
        UserDefaults.standard.set(autoScene, forKey: "autoScene")
        scheduleAutoScene()
    }

    @objc func toggleSound() {
        soundOn.toggle()
        UserDefaults.standard.set(soundOn, forKey: "sound")
        if !soundOn { playing?.player?.stop() }
    }

    @objc func setSize(_ item: NSMenuItem) {
        let a = anchor
        sizeIndex = item.tag
        UserDefaults.standard.set(sizeIndex, forKey: "size")
        layout(anchor: a)
    }
}

// MARK: - 启动

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let pet = Pet(assets: Bundle.main.resourceURL!.appendingPathComponent("assets"))
let args = CommandLine.arguments
if args.contains("--mute") { pet.soundOn = false }

// 调试用：--backdrop 1 直接打开第几种录屏背景
if let i = args.firstIndex(of: "--backdrop"), i + 1 < args.count, let n = Int(args[i + 1]) {
    let item = NSMenuItem()
    item.tag = n
    pet.setBackdrop(item)
}
// 调试用：--press 荡秋千 --press 散步，启动后每隔 1 秒依次按下这些按钮（--gap 秒数 可以改间隔）
// --scene vma --scene g4u：依次直接演这些名场面（不弹菜单）；--quit-after 秒数：到时间自动退出
let gap = args.firstIndex(of: "--gap").flatMap { Double(args[$0 + 1]) } ?? 1
var step = 0
for j in args.indices where j + 1 < args.count {
    if args[j] == "--press", args[j + 1] == "唱", true {
        step += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(step)) { pet.singButton.onPress() }
    } else if args[j] == "--press", let a = Action.allCases.first(where: { $0.label == args[j + 1] }) {
        step += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(step)) { pet.trigger(a) }
    } else if args[j] == "--act" {
        // 调试用：--act hearts / throw / jump / sleep / say，模拟摸头、扔出去、跳窗口、睡着、说话
        step += 1
        let act = args[j + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(step)) {
            switch act {
            case "hearts": for k in 0..<8 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.2 * Double(k)) { pet.spawnHeart() } }; pet.show(face: Pet.Face.happy, for: 3); pet.say("好舒服～", force: true)
            case "throw": pet.motion = Pet.Motion(pos: pet.anchor, vel: CGVector(dx: -1600, dy: 1100), fallStartY: pet.anchor.y); pet.show(face: Pet.Face.surprised)
            case "jump": if let t = pet.jumpTarget() { pet.jump(to: t) } else { print("附近没有能跳上去的窗口") }
            case "sleep": pet.sleepAfter = 1e9; pet.fallAsleep()
            case "pet":
                // 假鼠标在她上半身左右来回蹭 2 秒
                let z = pet.petZone
                for k in 0..<120 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) / 60) {
                    pet.fakeMouse = NSPoint(x: z.midX + sin(Double(k) / 60 * 2 * .pi * 2.5) * z.width * 0.3, y: z.midY)
                } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) { pet.fakeMouse = nil }
            case "near":
                // 假鼠标从远处慢慢移到她右边不远的地方，停 2 秒
                let f = pet.window.frame
                for k in 0..<60 { DispatchQueue.main.asyncAfter(deadline: .now() + Double(k) / 60) {
                    pet.fakeMouse = NSPoint(x: f.maxX + 400 - CGFloat(k) * 5.5, y: f.minY + pet.stickerSize.height * 0.7)
                } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pet.fakeMouse = nil }
            default: pet.say(act, force: true)
            }
        }
    } else if args[j] == "--scene", let id = SceneID(rawValue: args[j + 1]) {
        step += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(step)) { pet.play(id) }
    }
}
// 调试用：--render vma 100 out.jpg，不上屏幕，把这一帧合成成图片后退出
if let i = args.firstIndex(of: "--render"), i + 3 < args.count, let id = SceneID(rawValue: args[i + 1]), let f = Int(args[i + 2]) {
    pet.snapshot(id, frame: f, to: URL(fileURLWithPath: args[i + 3]))
    exit(0)
}
// 调试用：--sleep-after 5 没人理 5 秒就睡；--idle-every 3 每 3 秒左右自己找点事做；--auto-scene-in 4 四秒后自己演一段
if let i = args.firstIndex(of: "--sleep-after"), let t = Double(args[i + 1]) { pet.sleepAfter = t }
if let i = args.firstIndex(of: "--idle-every"), let t = Double(args[i + 1]) { pet.idleEvery = t; pet.nextIdleAct = CACurrentMediaTime() + t }
if let i = args.firstIndex(of: "--auto-scene-in"), let t = Double(args[i + 1]) { pet.autoScene = max(pet.autoScene, 1); pet.nextAutoScene = CACurrentMediaTime() + t }
// 调试用：--trace 每 0.25 秒打印一次她的状态
if args.contains("--trace") {
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        let f = pet.window.frame, sl = pet.stickerLayer
        print(String(format: "%.2f", CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)),
              "窗口", Int(f.minX), Int(f.minY), Int(f.width), Int(f.height), "贴纸隐藏", sl.isHidden, "透明度", sl.opacity,
              "缩放", (sl.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat).map { String(format: "%.2f", $0) } ?? "-",
              "表情", pet.expression.map(String.init) ?? "-", "运动", pet.motion != nil, "窗台", pet.perch?.id ?? 0,
              "home", pet.home != nil, "lean", String(format: "%.3f", pet.lean), "near", pet.mouseNear, "动画", sl.animationKeys() ?? [])
        fflush(stdout)
    }
}
if let i = args.firstIndex(of: "--quit-after"), let t = Double(args[i + 1]) {
    DispatchQueue.main.asyncAfter(deadline: .now() + t) { NSApp.terminate(nil) }
}

// 自检：验证点击判定、按钮位置、素材是否都读得到，然后每个名场面各演 2 秒，最后退出
if args.contains("--selftest") {
    let s = pet.stickerRect, b = pet.barRect
    for (name, p) in [
        ("贴纸中间", CGPoint(x: s.midX, y: s.midY)),
        ("按钮条中间", CGPoint(x: b.midX, y: b.midY)),
        ("窗口左下角", CGPoint(x: 1, y: 1)),
    ] {
        print("点击判定 \(name): \(pet.isInteractive(p) ? "归桌宠" : "穿透")")
    }
    for a in Action.allCases {
        let r = pet.bar.circleRect(a)
        print("按钮「\(a.label)」位置 → \(pet.bar.action(at: NSPoint(x: r.midX, y: r.midY))?.label ?? "无")")
    }
    for id in SceneID.allCases {
        let sc = pet.scenes[id]!
        let secs = sc.singer ? ((try? AVAudioPlayer(contentsOf: sc.audio))?.duration ?? 0) : Double(sc.sprite.count) / fps / sc.speed
        print("\(id.title)：\(sc.sprite.count) 帧（\(sc.speed == 1 ? "" : "\(sc.speed) 倍速，")演 \(String(format: "%.1f", secs)) 秒），声音 \(FileManager.default.fileExists(atPath: sc.audio.path) ? "有" : "没有")，字幕 \(sc.subs.count) 句，换镜头 \(sc.cuts.count) 次\(sc.crackAt.map { "，第 \($0) 帧砸屏幕" } ?? "")")
    }
    print("能站的窗口：\(pet.windows().count) 个")
    pet.log("启动")
    var t = 1.0
    // 互动功能冒烟测试：说话、冒爱心、睡觉醒来、做鬼脸、蹦、转身、戳五下
    let smoke: [() -> Void] = [{ pet.say("测试一下", force: true) }, { pet.spawnHeart() }, { pet.fallAsleep() }, { pet.spawnZ() }, { pet.wakeUp() },
                               { pet.makeFace() }, { pet.hop() }, { pet.turnAround() },
                               { if let j = pet.jumpTarget() { pet.jump(to: j) } else { pet.jumpDown() } }]
    for f in smoke { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: f); t += 0.5 }
    t += 2
    for a in [Action.meme, .meme, .meme, .cute, .cute, .cute, .cute, .cute, .meme] {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { pet.trigger(a) }
        t += 0.6
    }
    for id in SceneID.allCases {
        DispatchQueue.main.asyncAfter(deadline: .now() + t) { pet.play(id) }
        t += 2.2
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + t) { pet.endScene(); pet.log("全部演完") }
    DispatchQueue.main.asyncAfter(deadline: .now() + t + 1) { NSApp.terminate(nil) }
}
app.run()
