"""カセットテープのスキン素材 (リアル 7 : UI 向けの簡略化 3)
blender -b -P art/blender/cassette.py -- <出力フォルダ>

レイヤー: back (内側と影) → [アプリ: テープの巻き] → hub (回転) → front (半透明ケース・窓・ラベル) → [アプリ: ラベルの文字]
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
import cassette_model as cm  # noqa: E402
import common as c  # noqa: E402

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "Resources/Skins/cassette"
K = 1300

scene = c.reset()
c.world("studio.exr", strength=0.6, rotation=math.radians(35))
key = c.area_light((-1.3, 1.5, 2.8), size=3.6, power=260)
c.area_light((1.6, -0.8, 2.4), size=3.6, power=75, color=(0.9, 0.93, 1.0))
cam = c.Camera(K)
ground = c.shadow_catcher(size=6, z=0)

parts = cm.build()

# ---------------------------------------------------------------- レンダリング
W, H = 1.1, 0.73
cam.frame(0, 0, W, H)
c.render(os.path.join(OUT, "back.png"), show=parts["back"], shadow_only=parts["front"], catcher=None)
c.render(os.path.join(OUT, "front.png"), show=parts["front"])
hub_size = 2 * cm.HUB_R + 0.01
cam.frame(0, 0, hub_size, hub_size)
c.render(os.path.join(OUT, "hub.png"), show=parts["hub"])

cam.frame(0, 0, W, H)


def rect(cx, cy, w, h):
    x0, y0 = cam.px(cx - w / 2, cy + h / 2)
    return [x0, y0, round(w * K, 1), round(h * K, 1)]


c.write_layout(os.path.join(OUT, "layout.json"), {
    "canvas": [round(W * K), round(H * K)],
    "hubs": [cam.px(*h) for h in cm.HUBS],
    "hubSize": round(hub_size * K),
    "packRadius": [round(0.07 * K, 1), round(0.138 * K, 1)],
    "label": rect(*cm.LABEL),
    "window": rect(*cm.WINDOW),
    "cassette": rect(0, 0, *cm.SIZE),
})
print("done")
