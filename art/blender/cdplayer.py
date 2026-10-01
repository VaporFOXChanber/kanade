"""ポータブル CD プレイヤーのスキン素材 (リアル 7 : UI 向けの簡略化 3)
blender -b -P art/blender/cdplayer.py -- <出力フォルダ>

レイヤー: base (本体・液晶・ボタン・影) → [アプリ: 回転する盤 (アルバムアート)] → hub (盤の中央) → lid (透明なふた) → [アプリ: 液晶の文字]
"""

import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(__file__))
import common as c  # noqa: E402

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "Resources/Skins/cd"
DIN = "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf"
K = 1250
D = (0.0, 0.07)          # 盤の中心
DISC_R = 0.4
LCD = (0.0, -0.44, 0.56, 0.12)
BUTTONS = [(-0.4, -0.44), (0.4, -0.44)]
Z_TOP = 0.08

scene = c.reset()
c.world("studio.exr", strength=0.5, rotation=math.radians(35), flatten=0.75, gray=0.36)
c.area_light((-1.3, 1.6, 2.8), size=3.8, power=240)
c.area_light((1.6, -0.9, 2.4), size=3.8, power=75, color=(0.9, 0.93, 1.0))
cam = c.Camera(K)
ground = c.shadow_catcher(size=6, z=0)

silver = c.material("Silver", color=(0.44, 0.45, 0.47), metallic=1, roughness=0.42)
c.radial_hairline(silver, rings=420, strength=0.03, anis=0.6, center=(D[0], D[1]))
well_mat = c.material("Well", color=(0.05, 0.05, 0.055), roughness=0.65)
chrome = c.material("Chrome", color=(0.72, 0.73, 0.75), metallic=1, roughness=0.26)
lcd_mat = c.material("LCD", color=(0.5, 0.58, 0.45), roughness=0.7)
c.soft_surface(lcd_mat, rough=0.02, tint=0.03, scale=12)
glass = c.material("Glass", color=(0.96, 0.97, 0.98), roughness=0.07, Transmission_Weight=1.0, IOR=1.4)
lid_glass = c.material("LidGlass", color=(0.86, 0.89, 0.92), roughness=0.1, Transmission_Weight=1.0, IOR=1.35)
dark = c.material("Dark", color=(0.03, 0.03, 0.035), roughness=0.5)
print_gray = c.material("PrintGray", color=(0.1, 0.1, 0.11), roughness=0.6)
clear_hub = c.material("ClearHub", color=(0.92, 0.94, 0.96), roughness=0.06, Transmission_Weight=1.0, IOR=1.45)
mirror = c.material("MirrorBand", color=(0.8, 0.81, 0.83), metallic=1, roughness=0.26, Thin_Film_Thickness=520.0, Thin_Film_IOR=1.5)

# ---------------------------------------------------------------- 本体
body = c.rounded_rect("Body", 1.0, 1.12, Z_TOP, 0.2, (0, 0, Z_TOP / 2), bevel=0.014, mat=silver)
c.cut(body, c.cylinder("WellCut", 0.445, 0.05, (D[0], D[1], Z_TOP), verts=256))
c.cut(body, c.rounded_rect("LcdCut", LCD[2] + 0.03, LCD[3] + 0.03, 0.03, 0.03, (LCD[0], LCD[1], Z_TOP), bevel=0))
floor = c.cylinder("WellFloor", 0.446, 0.002, (D[0], D[1], Z_TOP - 0.024), verts=256, mat=well_mat)
motor = c.cylinder("Motor", 0.04, 0.014, (D[0], D[1], Z_TOP - 0.017), verts=96, bevel=0.003, mat=chrome)
lcd_panel = c.rounded_rect("LcdPanel", LCD[2] + 0.028, LCD[3] + 0.028, 0.004, 0.028, (LCD[0], LCD[1], Z_TOP - 0.013), bevel=0.001, mat=dark)
lcd = c.rounded_rect("Lcd", LCD[2], LCD[3], 0.003, 0.018, (LCD[0], LCD[1], Z_TOP - 0.01), bevel=0.001, mat=lcd_mat)
lcd_glass = c.rounded_rect("LcdGlass", LCD[2] + 0.028, LCD[3] + 0.028, 0.003, 0.028, (LCD[0], LCD[1], Z_TOP - 0.004), bevel=0.001, mat=glass)
buttons = [c.cylinder(f"Button{i}", 0.05, 0.02, (x, y, Z_TOP + 0.004), verts=96, bevel=0.009, mat=silver) for i, (x, y) in enumerate(BUTTONS)]
brand = c.text("Brand", "KANADE  -  DISC  -  ESP", 0.028, (0, -0.53, Z_TOP + 0.0002), font=DIN, mat=print_gray)
base_parts = [body, floor, motor, lcd_panel, lcd, lcd_glass, brand] + buttons

# ---------------------------------------------------------------- 盤の中央 (回転しても見た目が変わらない部分)
z_disc = Z_TOP - 0.012
hub_clear = c.cylinder("HubClear", 0.125, 0.0012, (D[0], D[1], z_disc), verts=192, mat=clear_hub)
c.cut(hub_clear, c.cylinder("HubHole", 0.075, 0.01, (D[0], D[1], z_disc), verts=96))
band = c.cylinder("MirrorBand", 0.122, 0.0005, (D[0], D[1], z_disc + 0.0009), verts=192, mat=mirror)
c.cut(band, c.cylinder("BandHole", 0.104, 0.01, (D[0], D[1], z_disc), verts=96))
clamp = c.cylinder("Clamp", 0.034, 0.014, (D[0], D[1], z_disc + 0.006), verts=96, bevel=0.005, mat=chrome)
hub_parts = [hub_clear, band, clamp]
print_sheen = c.cylinder("PrintSheen", DISC_R, 0.0008, (D[0], D[1], z_disc + 0.0004), verts=256,
                         mat=c.material("PrintGloss", color=(0, 0, 0), roughness=0.34, Specular_IOR_Level=0.3))
c.cut(print_sheen, c.cylinder("PrintHole", 0.125, 0.01, (D[0], D[1], z_disc), verts=128))

# ---------------------------------------------------------------- ふた
lid = c.cylinder("Lid", 0.46, 0.004, (D[0], D[1], Z_TOP + 0.012), verts=256, bevel=0.0015, mat=lid_glass)
rim = c.cylinder("Rim", 0.472, 0.01, (D[0], D[1], Z_TOP + 0.011), verts=256, bevel=0.004, mat=chrome)
c.cut(rim, c.cylinder("RimHole", 0.458, 0.05, (D[0], D[1], Z_TOP), verts=256))
hinge = c.box("Hinge", (0.16, 0.035, 0.02), (D[0], D[1] + 0.475, Z_TOP + 0.008), bevel=0.008, mat=chrome)
lid_parts = [lid, rim, hinge]

# ---------------------------------------------------------------- レンダリング
W, H = 1.1, 1.22
cam.frame(0, 0, W, H)
c.render(os.path.join(OUT, "base.png"), show=base_parts, shadow_only=lid_parts, catcher=None)
c.render(os.path.join(OUT, "lid.png"), show=lid_parts)
hub_size = 0.27
cam.frame(D[0], D[1], hub_size, hub_size)
c.render(os.path.join(OUT, "hub.png"), show=hub_parts)
sheen_size = 2 * DISC_R + 0.01
cam.frame(D[0], D[1], sheen_size, sheen_size)
c.render(os.path.join(OUT, "disc_sheen.png"), show=[print_sheen])

cam.frame(0, 0, W, H)
c.write_layout(os.path.join(OUT, "layout.json"), {
    "canvas": [round(W * K), round(H * K)],
    "disc": {"center": cam.px(*D), "radius": round(DISC_R * K, 1), "holeRadius": round(0.125 * K, 1)},
    "hub": {"center": cam.px(*D), "size": round(hub_size * K)},
    "sheen": {"center": cam.px(*D), "size": round(sheen_size * K)},
    "lcd": [cam.px(LCD[0] - LCD[2] / 2, LCD[1] + LCD[3] / 2)[0], cam.px(LCD[0] - LCD[2] / 2, LCD[1] + LCD[3] / 2)[1],
            round(LCD[2] * K, 1), round(LCD[3] * K, 1)],
    "buttons": [{"center": cam.px(x, y), "radius": round(0.05 * K, 1)} for x, y in BUTTONS],
})
print("done")
