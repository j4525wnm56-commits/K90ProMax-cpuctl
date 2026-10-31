#!/usr/bin/env python
"""发布截图前给"状态栏通知图标"打码。

为什么需要: 状态栏时钟右边那排小图标是**第三方 App 的通知图标**, 会暴露装了哪些应用。
系统图标(信号/网速/WiFi/电量/时钟)不用管, 它们不透露个人安装情况。

为什么不用"自动识别彩色小方块": 试过 —— 这张壁纸本身是暖色渐变, 饱和度就超过阈值,
整条状态栏都会被判成"图标"。启发式在这里不可靠, 所以改成**坐标 + 预览核对**:
先画红框看一眼, 对了再落盘。

用法:
    # 1) 先出预览图, 人工确认红框位置
    python tools/mask_status_icons.py shot.png --preview

    # 2) 确认没问题后原地打码
    python tools/mask_status_icons.py shot.png

    # 别的机型/分辨率: 用比例指定(默认值就是 K90 Pro Max 1200x2608 实测出来的)
    python tools/mask_status_icons.py shot.png --rel 0.143,0.019,0.322,0.037

    # 或者直接给像素坐标
    python tools/mask_status_icons.py shot.png --box 172,50,386,96

依赖: Pillow
"""
import sys

from PIL import Image, ImageDraw

# K90 Pro Max(1200x2608) 实测: 通知图标带 x 172..386, y 50..96 (含末尾的 "...")
DEFAULT_REL = (0.143, 0.019, 0.322, 0.037)
MOSAIC = 12


def mosaic(im, box, block=MOSAIC):
    t = im.crop(box)
    w, h = t.size
    if w < 2 or h < 2:
        return
    t = t.resize((max(1, w // block), max(1, h // block)), Image.BOX)
    t = t.resize((w, h), Image.NEAREST)
    im.paste(t, box)


def main():
    a = sys.argv[1:]
    if not a:
        print(__doc__)
        return 1
    src = a[0]
    dst = src
    rel = DEFAULT_REL
    box = None
    preview = False
    i = 1
    while i < len(a):
        if a[i] == '--preview':
            preview = True
            i += 1
        elif a[i] == '--rel' and i + 1 < len(a):
            rel = tuple(float(v) for v in a[i + 1].split(','))
            i += 2
        elif a[i] == '--box' and i + 1 < len(a):
            box = tuple(int(v) for v in a[i + 1].split(','))
            i += 2
        else:
            dst = a[i]
            i += 1

    im = Image.open(src).convert('RGB')
    W, H = im.size
    if box is None:
        box = (int(W * rel[0]), int(H * rel[1]), int(W * rel[2]), int(H * rel[3]))
    print(f'图像 {W}x{H}, 打码区域 {box}')

    if preview:
        pv = im.copy()
        ImageDraw.Draw(pv).rectangle(box, outline=(255, 0, 0), width=3)
        out = dst if dst != src else src.rsplit('.', 1)[0] + '.preview.png'
        pv.save(out)
        print(f'预览已保存 {out} —— 红框位置对吗? 对就去掉 --preview 再跑一次')
        return 0

    mosaic(im, box)
    im.save(dst)
    print(f'已打码并保存 {dst}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
