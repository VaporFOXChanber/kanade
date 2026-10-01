"""ミニプレイヤー用のポータブルカセットプレイヤー (リアル 7 : UI 向けの簡略化 3)
blender -b -P art/blender/walkman.py -- <出力フォルダ>

少し上から見下ろす角度 (TILT) で撮り、前面の窓と上面のキーが両方見えるようにする。
レイヤー: body (本体・カセットの内側) → [アプリ: テープの巻き・ハブ] → cassette (カセットの表面)
        → [アプリ: ラベルの文字] → lid (蓋とガラス) → key0〜3 (押し下げはアプリ側) → [アプリ: 音量ホイールの目盛り・LED]
中のカセットは cassette_model.py と同じ形状で、ハブの画像は Skins/cassette/hub.png を使う。
"""

import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(__file__))
import cassette_model as cm  # noqa: E402
import common as c  # noqa: E402

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "Resources/Skins/walkman"
FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"
DIN = "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf"
K = 700
CASSETTE_K = 1300          # カセットのスキン素材の解像度 (ハブ・テープの寸法の換算用)
TILT = 32

BW, BH, T = 1.16, 0.88, 0.26                 # 本体の幅・高さ・厚み
TOP = BH / 2                                  # 上面の y
LID = (0.0, -0.01, 1.08, 0.80)                # 蓋 (中心 x, y, 幅, 高さ)
WIN = (0.0, -0.04, 0.96, 0.58)                # 蓋の窓
LID_Z = T + 0.022                             # 蓋の表面
CASSETTE = (0.0, -0.085, T - 0.098)           # カセットの中心と背面の高さ
KEY_W, KEY_Z0, KEY_Z1 = 0.15, 0.06, 0.20      # キーの幅と奥行き (z の範囲)
KEY_UP = 0.065                                # 上面から出ている高さ
KEY_PRESS = 0.03                              # 押し込んだときの沈み
KEYS = [("stop", -0.425), ("rew", -0.257), ("play", -0.089), ("ff", 0.079)]
LED = (0.19, 0.13)
JACK = (0.27, 0.13)
WHEEL = (0.40, 0.10, 0.045)                   # x, 半径, 上面からの出っ張り
WHEEL_Z = (0.105, 0.155)

scene = c.reset()
c.world("studio.exr", strength=0.32, rotation=math.radians(35), flatten=0.65, gray=0.4)
c.area_light((-1.6, 2.4, 2.6), size=4.0, power=360)
c.area_light((1.8, -1.4, 2.4), size=4.0, power=90, color=(0.9, 0.93, 1.0))
cam = c.Camera(K)

# ---------------------------------------------------------------- 材質
silver = c.material("Silver", color=(0.46, 0.46, 0.48), metallic=1, roughness=0.4)
c.brushed(silver, direction="X", scale=800, rough=(0.36, 0.46), strength=0.008)
lid_black = c.material("LidBlack", color=(0.008, 0.008, 0.01), roughness=0.5, Specular_IOR_Level=0.22)
c.soft_surface(lid_black, rough=0.04, tint=0.05, scale=8)
glass = c.material("Glass", color=(0.96, 0.97, 0.98), roughness=0.05, Transmission_Weight=1.0, IOR=1.22)
interior = c.material("Interior", color=(0.02, 0.02, 0.022), roughness=0.7)
key_mat = c.material("Key", color=(0.012, 0.012, 0.014), roughness=0.44, Specular_IOR_Level=0.3)
c.soft_surface(key_mat, rough=0.04, tint=0.05, scale=20)
print_white = c.material("PrintWhite", color=(0.78, 0.78, 0.8), roughness=0.55)
print_orange = c.material("PrintOrange", color=(0.95, 0.36, 0.08), roughness=0.5)
chrome = c.material("Chrome", color=(0.72, 0.72, 0.74), metallic=1, roughness=0.28)
lens = c.material("Lens", color=(0.22, 0.03, 0.02), roughness=0.2, Coat_Weight=0.4)
wheel_mat = c.material("Wheel", color=(0.02, 0.02, 0.024), roughness=0.5, Specular_IOR_Level=0.3)
c.soft_surface(wheel_mat, rough=0.03, tint=0.04, scale=30)


def cut(obj, cutter, dark=True):
    """くり抜いた面を暗い内装の材質にする"""
    if dark:
        cutter.data.materials.append(interior)
    m = obj.modifiers.new("Cut", "BOOLEAN")
    m.operation = "DIFFERENCE"
    m.object = cutter
    try:
        m.material_mode = "TRANSFER"
    except (AttributeError, TypeError):
        pass
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=m.name)
    bpy.data.objects.remove(cutter, do_unlink=True)


def ccw(points):
    area = sum(points[i][0] * points[(i + 1) % len(points)][1] - points[(i + 1) % len(points)][0] * points[i][1] for i in range(len(points)))
    return points if area > 0 else list(reversed(points))


def symbol(name, kind, center, size, mat):
    """キーの上面 (+Y 向き) に印刷した記号"""
    s = size
    shapes = {
        "stop": [[(-0.45, -0.45), (0.45, -0.45), (0.45, 0.45), (-0.45, 0.45)]],
        "play": [[(-0.4, -0.55), (0.6, 0), (-0.4, 0.55)]],
        "ff": [[(-0.75, -0.45), (0.05, 0), (-0.75, 0.45)], [(0.0, -0.45), (0.8, 0), (0.0, 0.45)]],
        "rew": [[(0.75, -0.45), (-0.05, 0), (0.75, 0.45)], [(0.0, -0.45), (-0.8, 0), (0.0, 0.45)]],
    }
    return [c.polygon(f"{name}{i}", ccw([(x * s, y * s) for x, y in pts]), center, mat=mat, thickness=0.0006, tilt=-math.pi / 2)
            for i, pts in enumerate(shapes[kind])]


# ---------------------------------------------------------------- 本体
body = c.rounded_rect("Body", BW, BH, T, 0.075, (0, 0, T / 2), bevel=0.022, mat=silver)
bpy.context.view_layer.objects.active = body
bpy.ops.object.modifier_apply(modifier="Bevel")   # 外周の丸みを先に確定し、穴の縁は小さく面取りする
cut(body, c.rounded_rect("Pocket", 1.04, 0.67, 0.2, 0.03, (CASSETTE[0], CASSETTE[1], T), bevel=0))
for name, x in KEYS:
    cut(body, c.box(f"Slot{name}", (KEY_W + 0.004, 0.2, KEY_Z1 - KEY_Z0 + 0.004), (x, TOP, (KEY_Z0 + KEY_Z1) / 2)))
wx, wr, wup = WHEEL
chord = 2 * math.sqrt(wr * wr - (wr - wup) ** 2)   # 上面から見えるホイールの幅
cut(body, c.box("WheelSlot", (chord + 0.02, 0.2, WHEEL_Z[1] - WHEEL_Z[0] + 0.008), (wx, TOP, sum(WHEEL_Z) / 2)))
cut(body, c.cylinder("JackHole", 0.02, 0.1, (JACK[0], TOP, JACK[1]), verts=48, rotation=(math.pi / 2, 0, 0)))
edge = body.modifiers.new("SoftEdge", "BEVEL")
edge.width = 0.003
edge.segments = 3
edge.limit_method = "ANGLE"
edge.angle_limit = math.radians(50)
body_parts = [body]

# 上面の小物: ヘッドホン端子・LED・音量ホイール
body_parts.append(c.cylinder("JackRing", 0.032, 0.012, (JACK[0], TOP + 0.002, JACK[1]), verts=64, bevel=0.003,
                             mat=chrome, rotation=(math.pi / 2, 0, 0)))
jack_ring = body_parts[-1]
cut(jack_ring, c.cylinder("JackRingHole", 0.019, 0.1, (JACK[0], TOP, JACK[1]), verts=48, rotation=(math.pi / 2, 0, 0)))
body_parts.append(c.cylinder("LedLens", 0.014, 0.012, (LED[0], TOP + 0.001, LED[1]), verts=48, bevel=0.004,
                             mat=lens, rotation=(math.pi / 2, 0, 0)))
wheel = c.cylinder("Wheel", wr, WHEEL_Z[1] - WHEEL_Z[0], (wx, TOP + wup - wr, sum(WHEEL_Z) / 2), verts=192, bevel=0.004, mat=wheel_mat)
body_parts.append(wheel)
for i in range(90):  # 縁のギザギザ
    a = i / 90 * 2 * math.pi
    r = c.box(f"Knurl{i}", (0.006, 0.01, WHEEL_Z[1] - WHEEL_Z[0] - 0.006),
              (wx + wr * math.cos(a), TOP + wup - wr + wr * math.sin(a), sum(WHEEL_Z) / 2), bevel=0.002, segments=2, mat=wheel_mat)
    r.rotation_euler.z = a
    body_parts.append(r)
body_parts.append(c.cylinder("WheelHub", wr * 0.3, 0.004, (wx, TOP + wup - wr, WHEEL_Z[1] + 0.001), verts=64, bevel=0.0015, mat=chrome))


# ---------------------------------------------------------------- カセット
cas = cm.build()
for group in cas.values():
    cm.move(group, CASSETTE)

# ---------------------------------------------------------------- 蓋 (黒い枠・ガラス・印刷)
lx, ly, lw, lh = LID
lid = c.rounded_rect("Lid", lw, lh, 0.022, 0.05, (lx, ly, T + 0.011), bevel=0.006, mat=lid_black)
cut(lid, c.rounded_rect("LidWindow", WIN[2], WIN[3], 0.1, 0.035, (WIN[0], WIN[1], T), bevel=0), dark=False)
pane = c.rounded_rect("Pane", WIN[2] + 0.006, WIN[3] + 0.006, 0.004, 0.037, (WIN[0], WIN[1], T + 0.015), bevel=0.001, mat=glass)
band_y = (ly + lh / 2 + WIN[1] + WIN[3] / 2) / 2          # 窓の上の帯の中心
lid_parts = [lid, pane]
lid_parts.append(c.text("Logo", "Kanade", 0.064, (-0.47, band_y + 0.006, LID_Z + 0.0002), font=FUTURA, mat=print_white, align="LEFT"))
lid_parts.append(c.text("Sub", "STEREO CASSETTE PLAYER", 0.021, (0.47, band_y + 0.022, LID_Z + 0.0002), font=DIN, mat=print_white, align="RIGHT"))
lid_parts.append(c.text("Sub2", "AUTO REVERSE", 0.021, (0.47, band_y - 0.014, LID_Z + 0.0002), font=DIN, mat=print_orange, align="RIGHT"))
lid_parts.append(c.box("Stripe", (0.3, 0.005, 0.0004), (-0.32, band_y - 0.036, LID_Z + 0.0002), mat=print_orange))

# ---------------------------------------------------------------- キー
keys = []
for name, x in KEYS:
    k = c.box(f"Key{name}", (KEY_W, KEY_UP + 0.02, KEY_Z1 - KEY_Z0), (x, TOP + (KEY_UP - 0.02) / 2, (KEY_Z0 + KEY_Z1) / 2),
              bevel=0.012, segments=5, mat=key_mat)
    sym = symbol(f"Sym{name}", name, (x, TOP + KEY_UP + 0.0002, (KEY_Z0 + KEY_Z1) / 2), 0.034,
                 print_orange if name == "play" else print_white)
    keys.append((name, x, [k] + sym))
key_objs = [o for _, _, objs in keys for o in objs]

# 音量ホイールの目盛り (正面から撮って、アプリ側で回す)
marks = []
for n in range(11):
    a = math.radians(90 + 27 * n)
    r_text = wr * 0.72
    marks.append(c.text(f"Vol{n}", str(n), 0.024, (wx + r_text * math.cos(a), TOP + wup - wr + r_text * math.sin(a), WHEEL_Z[1] + 0.0004),
                        font=DIN, mat=print_white, rotation=a - math.pi / 2))

# ---------------------------------------------------------------- レンダリング
cos, sin = math.cos(math.radians(TILT)), math.sin(math.radians(TILT))
v_top = (TOP + KEY_UP) * cos - KEY_Z0 * sin + 0.035
v_bottom = -BH / 2 * cos - T * sin - 0.035
W = BW + 0.08
H = v_top - v_bottom
VC = (v_top + v_bottom) / 2
cam.frame(0, VC, W, H, tilt=TILT)
c.render(os.path.join(OUT, "body.png"), show=body_parts + cas["back"], shadow_only=lid_parts + cas["front"] + key_objs)
c.render(os.path.join(OUT, "cassette.png"), show=cas["front"], shadow_only=lid_parts)
c.render(os.path.join(OUT, "lid.png"), show=lid_parts)

key_layout = []
for name, x, objs in keys:
    box = cam.bounds(objs, margin=4)
    cam.crop(box)
    c.render(os.path.join(OUT, f"key_{name}.png"), show=objs)
    clip = cam.px(x, TOP, KEY_Z1)[1]
    key_layout.append({"action": name, "rect": [box[0], box[1], box[2] - box[0], box[3] - box[1]],
                       "clipY": clip, "press": round(KEY_PRESS * cos * K, 2)})
cam.uncrop()

wheel_center = cam.px(wx, TOP + wup - wr, WHEEL_Z[1])
wheel_clip = cam.px(wx, TOP, WHEEL_Z[1])[1]
led = cam.px(LED[0], TOP + 0.007, LED[1])
reels = cam.px(CASSETTE[0], CASSETTE[1], CASSETTE[2] + cm.HUB_Z)
label = cam.px(CASSETTE[0], CASSETTE[1], CASSETTE[2] + cm.LABEL_Z)
canvas = [round(W * K), round(H * K)]

# 目盛りは正面から (傾けずに) 撮る
wheel_size = 2 * wr + 0.01
cam.frame(wx, TOP + wup - wr, wheel_size, wheel_size)
c.render(os.path.join(OUT, "wheel_marks.png"), show=marks)

c.write_layout(os.path.join(OUT, "layout.json"), {
    "canvas": canvas,
    "tilt": round(cos, 5),
    "cassetteScale": round(K / CASSETTE_K, 5),
    "reels": reels,
    "label": label,
    "keys": key_layout,
    "wheel": {"center": wheel_center, "size": round(wheel_size * K, 1), "clipY": wheel_clip},
    "led": {"center": led, "radius": round(0.014 * K, 1)},
})
print("done")
