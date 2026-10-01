"""アンプ (アナログ VU メーター) のスキン素材 (リアル 7 : UI 向けの簡略化 3)
blender -b -P art/blender/amp.py -- <出力フォルダ>

レイヤー: base (パネル・木枠・照明付きの目盛り板・ノブ) → [アプリ: 針・LED・ノブの指標] → glass (メーターのガラスと針の根元カバー)
"""

import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(__file__))
import common as c  # noqa: E402

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "Resources/Skins/amp"
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FACE = os.path.join(ROOT, "art", "textures", "vu-face.png")
DIN = "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf"
DIDOT = "/System/Library/Fonts/Supplemental/Didot.ttc"
K = 620
METERS = [(-0.47, 0.1), (0.47, 0.1)]
MW, MH = 0.84, 0.5
KNOB = (0.78, -0.3, 0.1)
LED = (0.0, -0.3)
Z = 0.08

scene = c.reset()
c.world("studio.exr", strength=0.5, rotation=math.radians(35), flatten=0.7, gray=0.36)
c.area_light((-2.0, 1.6, 3.0), size=4.5, power=320)
c.area_light((2.2, -1.0, 2.6), size=4.5, power=90, color=(0.9, 0.93, 1.0))
cam = c.Camera(K)
ground = c.shadow_catcher(size=8, z=0)

panel = c.material("Panel", color=(0.03, 0.03, 0.034), metallic=0.5, roughness=0.5, Coat_Weight=0.08)
c.brushed(panel, direction="X", scale=700, rough=(0.46, 0.54), strength=0.006)
walnut = c.material("Walnut", roughness=0.5)
c.wood(walnut, scale=5.0)
satin = c.material("Satin", color=(0.66, 0.67, 0.69), metallic=1, roughness=0.36)
c.soft_surface(satin, rough=0.03, tint=0.02)
knob_top = c.material("KnobTop", color=(0.7, 0.71, 0.73), metallic=1, roughness=0.34)
c.radial_hairline(knob_top, rings=350, strength=0.03, anis=0.6)
face = c.material("Face", roughness=0.85)
c.image_texture(face, FACE, emission=1.15)
glass = c.material("Glass", color=(0.95, 0.96, 0.97), roughness=0.1, Transmission_Weight=1.0, IOR=1.35)
cover = c.material("Cover", color=(0.02, 0.02, 0.022), roughness=0.5, Coat_Weight=0.1)
c.soft_surface(cover, rough=0.03, tint=0.04)
print_white = c.material("PrintWhite", color=(0.72, 0.72, 0.74), roughness=0.55)
lens = c.material("Lens", color=(0.2, 0.03, 0.02), roughness=0.2, Coat_Weight=0.4)
recess = c.material("Recess", color=(0.01, 0.01, 0.012), roughness=0.7)

# ---------------------------------------------------------------- パネルと木枠
body = c.rounded_rect("Panel", 1.98, 0.88, Z, 0.03, (0, 0, Z / 2), bevel=0.008, mat=panel)
cheeks = [c.rounded_rect(f"Cheek{s}", 0.09, 0.92, Z + 0.012, 0.02, (s * 1.03, 0, (Z + 0.012) / 2), bevel=0.01, mat=walnut) for s in (-1, 1)]
base_parts = [body] + cheeks

faces = []
for i, (x, y) in enumerate(METERS):
    c.cut(body, c.rounded_rect(f"WinCut{i}", MW, MH, 0.05, 0.025, (x, y, Z), bevel=0))
    well = c.rounded_rect(f"Well{i}", MW + 0.002, MH + 0.002, 0.004, 0.025, (x, y, Z - 0.026), bevel=0.001, mat=recess)
    # 目盛り板 (テクスチャを貼るので UV 付きの平面にする)
    bpy.ops.mesh.primitive_plane_add(size=1, location=(x, y, Z - 0.023))
    f = bpy.context.active_object
    f.name = f"Face{i}"
    f.scale = (MW - 0.01, MH - 0.01, 1)
    f.data.materials.append(face)
    faces.append(f)
    bezel = c.rounded_rect(f"Bezel{i}", MW + 0.04, MH + 0.04, 0.008, 0.035, (x, y, Z + 0.004), bevel=0.003, mat=satin)
    c.cut(bezel, c.rounded_rect(f"BezelCut{i}", MW, MH, 0.05, 0.025, (x, y, Z), bevel=0))
    base_parts += [well, f, bezel]

# 下段: ロゴ・電源ランプ・音量ノブ
base_parts.append(c.text("Logo", "Kanade", 0.075, (-0.8, -0.28, Z + 0.0002), font=DIDOT, mat=print_white, align="LEFT"))
base_parts.append(c.text("Sub", "STEREO POWER AMPLIFIER", 0.022, (-0.8, -0.355, Z + 0.0002), font=DIN, mat=print_white, align="LEFT"))
led_ring = c.cylinder("LedRing", 0.024, 0.008, (LED[0], LED[1], Z + 0.004), verts=64, bevel=0.003, mat=satin)
led_lens = c.cylinder("LedLens", 0.015, 0.01, (LED[0], LED[1], Z + 0.005), verts=48, bevel=0.004, mat=lens)
base_parts += [led_ring, led_lens, c.text("PowerText", "POWER", 0.02, (LED[0] + 0.045, LED[1], Z + 0.0002), font=DIN, mat=print_white, align="LEFT")]
knob_skirt = c.cylinder("KnobSkirt", KNOB[2] + 0.012, 0.012, (KNOB[0], KNOB[1], Z + 0.006), verts=128, bevel=0.004, mat=satin)
knob = c.cylinder("Knob", KNOB[2], 0.05, (KNOB[0], KNOB[1], Z + 0.025), verts=192, bevel=0.01, mat=knob_top)
base_parts += [knob_skirt, knob, c.text("VolText", "VOLUME", 0.02, (KNOB[0] - KNOB[2] - 0.03, KNOB[1], Z + 0.0002), font=DIN, mat=print_white, align="RIGHT")]
# ノブの周りの目盛り点
for j in range(11):
    a = math.radians(225 - 27 * j)
    base_parts.append(c.cylinder(f"Tick{j}", 0.005, 0.001, (KNOB[0] + (KNOB[2] + 0.03) * math.cos(a), KNOB[1] + (KNOB[2] + 0.03) * math.sin(a), Z + 0.0005),
                                 verts=16, mat=print_white))
for sx in (-1, 1):
    for sy in (-1, 1):
        base_parts.append(c.cylinder(f"Screw{sx}{sy}", 0.012, 0.004, (sx * 0.95, sy * 0.4, Z + 0.002), verts=48, bevel=0.002, mat=satin))

# ---------------------------------------------------------------- ガラスと針の根元カバー
glass_parts = []
for i, (x, y) in enumerate(METERS):
    top = y + MH / 2
    cover_y = top - 1.05 * MH
    cov = c.cylinder(f"Cover{i}", 0.28 * MH, 0.012, (x, cover_y, Z - 0.012), verts=128, bevel=0.004, mat=cover)
    clip = c.box(f"CoverClip{i}", (MW, 0.3, 0.1), (x, y - MH / 2 - 0.15, Z))
    c.cut(cov, clip)
    pane = c.rounded_rect(f"Glass{i}", MW, MH, 0.003, 0.025, (x, y, Z - 0.004), bevel=0.001, mat=glass)
    glass_parts += [cov, pane]

# ---------------------------------------------------------------- レンダリング
W, H = 2.3, 1.08
cam.frame(0, 0, W, H)
c.render(os.path.join(OUT, "base.png"), show=base_parts, catcher=None)
c.render(os.path.join(OUT, "glass.png"), show=glass_parts)


def rect(cx, cy, w, h):
    x0, y0 = cam.px(cx - w / 2, cy + h / 2)
    return [x0, y0, round(w * K, 1), round(h * K, 1)]


c.write_layout(os.path.join(OUT, "layout.json"), {
    "canvas": [round(W * K), round(H * K)],
    "meters": [rect(x, y, MW, MH) for x, y in METERS],
    "knob": {"center": cam.px(KNOB[0], KNOB[1]), "radius": round(KNOB[2] * K, 1)},
    "led": {"center": cam.px(*LED), "radius": round(0.015 * K, 1)},
})
print("done")
