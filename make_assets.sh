#!/bin/zsh
# 从 source/ 里的原图和原视频重新生成素材到 assets/（一般不需要再跑，素材已经生成好，全部跑完大概要 15 分钟）
set -e
cd "$(dirname "$0")"
mkdir -p build/tools assets
cat tools/stickers.swift tools/edges.swift.inc > build/tools/stickers.swift
cat tools/swing.swift tools/edges.swift.inc tools/audio.swift.inc > build/tools/swing.swift
cat tools/scene.swift tools/edges.swift.inc tools/audio.swift.inc > build/tools/scene.swift
cat tools/audiofix.swift tools/audio.swift.inc > build/tools/audiofix.swift
for t in stickers swing scene audiofix; do swiftc -O build/tools/$t.swift -o build/tools/$t; done

# 搞笑娅娅：三张表情包照片抠成白边贴纸
for i in 1 2 3; do ./build/tools/stickers source/meme$i.jpg assets/meme$i 720; done
./build/tools/stickers source/meme4.webp assets/meme4 720       # 紫色漆皮那张（小红书原图是 webp）
# 萌娅娅：5 张自拍抠成白边贴纸
for i in 1 2 3 4 5; do ./build/tools/stickers source/cute$i.jpg assets/cute$i 720; done
# 荡秋千：固定机位仰拍，防抖 + 空背景对比抠图，链子是重新画的
./build/tools/swing source/swing.mp4 assets/swing
# 发疯系列
#   Good 4 U：裁掉底下的双语字幕条（字幕单独抠出来放回去）；前半段床上的毛绒玩具会被一起认成主体，划掉那块
./build/tools/scene source/g4u.mp4 assets/g4u --crop 225,14,2428,1550 --subs 225,1560,2428,250 --exclude 0.0,0.68,0.27,1.0@200-278
#   全美婊 1、2：SNL 现场，竖屏视频中间那一条才是画面
./build/tools/scene source/meangirls.mp4 assets/aab --crop 0,661,1080,585
./build/tools/audiofix assets/aab 1.25        # 稍微加快一点
./build/tools/scene source/aab2.mp4 assets/aab2 --crop 0,655,1080,609
./build/tools/audiofix assets/aab2 1.75       # 太长了，1.75 倍速（变速不变调）
#   VMA：她一拳挥过来之后是碎玻璃特写，这段直接放原画面（四周淡出）；左上角 TikTok 水印用下方画面盖住
./build/tools/scene source/vma.mp4 assets/vma --raw-from 86 --patch 0,0.012,0.28,0.095
#   VMA 现场 Good 4 U：现场混剪画面不用，只要声音，桌宠上用默认那张全身照跟着唱
cat tools/audioonly.swift tools/audio.swift.inc > build/tools/audioonly.swift && swiftc -O build/tools/audioonly.swift -o build/tools/audioonly
./build/tools/audioonly source/crazy5.mov assets/vmalive
./build/tools/audiofix assets/vmalive 1.4
# 抓马抓马：话筒架也留着，盖掉压在她毛衣上的抖音水印
./build/tools/scene source/drama.mp4 assets/drama --with-props --patch 0.875,0.86,1,0.915
# 思念棉夫：竖着录的横屏视频，黑底采访字幕留在她身上；最后半秒切到主持人和播放器界面，定格在她身上
./build/tools/scene source/thanku.mp4 assets/thanku --crop 231,0,2158,1206 --keep-captions 0.55 --freeze-from 259
./build/tools/audiofix assets/thanku 1.53     # 加快到 6 秒左右
