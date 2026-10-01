"""レコードプレイヤーのスキン素材 (リアル 7 : UI 向けの簡略化 3)
blender -b -P art/blender/turntable.py -- <出力フォルダ>
"""

import math
import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(__file__))
import common as c  # noqa: E402

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "Resources/Skins/turntable"
FUTURA = "/System/Library/Fonts/Supplemental/Futura.ttc"
DIN = "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf"

K = 1250  # px / BU
CENTER = (-0.13, 0.0)
PIVOT = (0.44, 0.27)
ARM_L = 0.63
R_OUTER, R_INNER = 0.368, 0.145
PLATTER_R, RECORD_R, LABEL_R = 0.40, 0.385, 0.127
Z_PLINTH, Z_PLATTER, Z_RECORD = 0.07, 0.092, 0.0955


def arm_angle(r):
    """針先がレコード中心から半径 r に来るときのアーム角 (度、y 上向き)"""
    dx, dy = CENTER[0] - PIVOT[0], CENTER[1] - PIVOT[1]
    d = math.hypot(dx, dy)
    beta = math.atan2(dy, dx)
    phi = math.acos((ARM_L**2 + d**2 - r**2) / (2 * ARM_L * d))
    return math.degrees(beta + phi)


scene = c.reset()
c.world("studio.exr", strength=0.6, rotation=math.radians(40))
# 大きく柔らかいキーライト (左上) と弱いフィル
key = c.area_light((-1.4, 1.7, 3.0), size=4.0, power=300)
fill = c.area_light((1.8, -0.8, 2.6), size=4.0, power=85, color=(0.9, 0.93, 1.0))
cam = c.Camera(K)
ground = c.shadow_catcher(size=8, z=0)

# ---------------------------------------------------------------- 材質 (ノイズ控えめのクリーンな質感)
body = c.material("Body", color=(0.024, 0.024, 0.027), metallic=0.35, roughness=0.55, Coat_Weight=0.1, Coat_Roughness=0.45)
c.brushed(body, direction="X", scale=500, rough=(0.5, 0.58), strength=0.006)
chrome = c.material("Chrome", color=(0.84, 0.84, 0.86), metallic=1, roughness=0.2)
satin = c.material("Satin", color=(0.72, 0.73, 0.75), metallic=1, roughness=0.38)
c.soft_surface(satin, rough=0.03, tint=0.02)
black_plastic = c.material("BlackPlastic", color=(0.016, 0.016, 0.018), roughness=0.48, Coat_Weight=0.12, Coat_Roughness=0.4)
c.soft_surface(black_plastic, rough=0.04, tint=0.05)
c.soft_surface(body, rough=0, tint=0.06, scale=3)
rubber = c.material("Rubber", color=(0.02, 0.02, 0.02), roughness=0.8)
print_white = c.material("PrintWhite", color=(0.78, 0.78, 0.8), roughness=0.5)
print_dark = c.material("PrintDark", color=(0.05, 0.05, 0.055), roughness=0.6)
led_off = c.material("LedOff", color=(0.22, 0.03, 0.02), roughness=0.18, Coat_Weight=0.5)
cart_red = c.material("Cartridge", color=(0.62, 0.08, 0.05), roughness=0.42, Coat_Weight=0.3)


def platter_mat(mode):
    if mode == "diffuse":
        return c.material("Platter-diffuse", color=(0.32, 0.32, 0.33), roughness=0.6)
    m = c.material("Platter-full", color=(0.5, 0.51, 0.53), metallic=1, roughness=0.38)
    c.radial_hairline(m, rings=300, strength=0.015, anis=0.6)
    return m


def vinyl_mat(mode):
    """mode: diffuse = 回転させる素地 / glossy = 回転させない反射"""
    if mode == "diffuse":
        return c.material("Vinyl-diffuse", color=(0.014, 0.014, 0.016), roughness=0.5, Specular_IOR_Level=0.0)
    m = c.material("Vinyl-glossy", color=(0, 0, 0), roughness=0.42, Specular_IOR_Level=0.38)
    n, l, bsdf = c.nodes(m)
    c.radial_hairline(m, rings=900, strength=0.12, anis=0.95)
    # 曲間の帯だけ少しなめらかにする
    tc = n.new("ShaderNodeTexCoord")
    length = n.new("ShaderNodeVectorMath")
    length.operation = "LENGTH"
    l.new(tc.outputs["Object"], length.inputs[0])
    ramp = n.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    cr.interpolation = "CONSTANT"
    cr.elements[0].color = (0.34, 0.34, 0.34, 1)
    for i, r in enumerate((0.215, 0.219, 0.275, 0.279, 0.33, 0.334)):
        e = cr.elements.new(r / RECORD_R)
        e.color = (0.18, 0.18, 0.18, 1) if i % 2 == 0 else (0.34, 0.34, 0.34, 1)
    cr.elements[-1].color = (0.34, 0.34, 0.34, 1)
    l.new(length.outputs["Value"], ramp.inputs["Fac"])
    l.new(ramp.outputs["Color"], bsdf.inputs["Roughness"])
    return m


label_gray = c.material("LabelGray", color=(0.5, 0.5, 0.5), roughness=0.8)
matte_black = c.material("MatteBlack", color=(0, 0, 0), roughness=1, Specular_IOR_Level=0)

# ---------------------------------------------------------------- 本体 (角を大きく丸めた一枚板)
plinth = c.rounded_rect("Plinth", 1.2, 0.92, Z_PLINTH, 0.06, (0, 0, Z_PLINTH / 2), bevel=0.01, mat=body)
well = c.cylinder("Well", PLATTER_R + 0.014, 0.01, (CENTER[0], CENTER[1], Z_PLINTH), verts=256)
c.cut(plinth, well)
static = [plinth]

base_ring = c.cylinder("PivotBase", 0.08, 0.026, (PIVOT[0], PIVOT[1], Z_PLINTH + 0.013), bevel=0.006, mat=satin)
base_top = c.cylinder("PivotTop", 0.05, 0.034, (PIVOT[0], PIVOT[1], Z_PLINTH + 0.017), bevel=0.005, mat=black_plastic)
rest_a = math.radians(-95)
rest = (PIVOT[0] + 0.62 * ARM_L * math.cos(rest_a), PIVOT[1] + 0.62 * ARM_L * math.sin(rest_a))
rest_post = c.cylinder("RestPost", 0.022, 0.05, (rest[0], rest[1], Z_PLINTH + 0.025), bevel=0.006, mat=black_plastic)
static += [base_ring, base_top, rest_post]

buttons = {}
start = c.rounded_rect("Start", 0.2, 0.075, 0.014, 0.018, (0.42, -0.36, Z_PLINTH + 0.007), bevel=0.005, mat=satin)
static.append(start)
static.append(c.text("StartText", "START / STOP", 0.022, (0.42, -0.36, Z_PLINTH + 0.0142), font=DIN, mat=print_dark))
buttons["start"] = (0.42, -0.36, 0.2, 0.075)
for label, x in (("33", 0.365), ("45", 0.475)):
    b = c.rounded_rect(f"Btn{label}", 0.085, 0.045, 0.012, 0.012, (x, -0.24, Z_PLINTH + 0.006), bevel=0.004, mat=black_plastic)
    t = c.text(f"Btn{label}Text", label, 0.024, (x, -0.24, Z_PLINTH + 0.0122), font=DIN, mat=print_white)
    led = c.cylinder(f"Led{label}", 0.008, 0.004, (x, -0.195, Z_PLINTH + 0.002), bevel=0.0015, mat=led_off)
    static += [b, t, led]
    buttons[label] = (x, -0.24, 0.085, 0.045)
    buttons[f"led{label}"] = (x, -0.195, 0.016, 0.016)
static.append(c.text("Brand", "KANADE", 0.036, (-0.545, 0.405, Z_PLINTH + 0.0002), font=FUTURA, mat=print_white, align="LEFT"))

# ---------------------------------------------------------------- 回転する部分
platter = c.cylinder("Platter", PLATTER_R, 0.022, (CENTER[0], CENTER[1], Z_PLATTER - 0.011), verts=256, bevel=0.003)
dots = []
for i in range(72):
    a = i / 72 * 2 * math.pi
    dots.append(c.cylinder(f"Dot{i}", 0.0045, 0.0012, (CENTER[0] + 0.3925 * math.cos(a), CENTER[1] + 0.3925 * math.sin(a), Z_PLATTER),
                           verts=24))
dots = c.join(dots, "Dots")
record = c.cylinder("Record", RECORD_R, 0.0035, (CENTER[0], CENTER[1], Z_RECORD - 0.00175), verts=256, bevel=0.0012)
label = c.cylinder("Label", LABEL_R, 0.0006, (CENTER[0], CENTER[1], Z_RECORD + 0.0003), verts=256)
spindle = c.cylinder("Spindle", 0.008, 0.02, (CENTER[0], CENTER[1], Z_RECORD + 0.008), verts=48, bevel=0.003, mat=chrome)


def set_mat(obj, m):
    obj.data.materials.clear()
    obj.data.materials.append(m)


# ---------------------------------------------------------------- トーンアーム (簡潔な直線アーム)
mid = (arm_angle(R_OUTER) + arm_angle(R_INNER)) / 2
z_arm = 0.128
parts = [
    c.cylinder("Gimbal", 0.036, 0.034, (0, 0, 0.104), verts=64, bevel=0.006, mat=chrome),
    c.cylinder("Tube", 0.012, 0.56, (0.26, 0, z_arm), verts=48, mat=satin, rotation=(0, math.pi / 2, 0)),
    c.cylinder("Weight", 0.038, 0.07, (-0.095, 0, z_arm), verts=96, bevel=0.008, mat=satin, rotation=(0, math.pi / 2, 0)),
    c.cylinder("WeightRing", 0.0385, 0.014, (-0.074, 0, z_arm), verts=96, bevel=0.002, mat=black_plastic, rotation=(0, math.pi / 2, 0)),
    c.cylinder("WeightStub", 0.014, 0.05, (-0.03, 0, z_arm), verts=32, mat=satin, rotation=(0, math.pi / 2, 0)),
]
hs_ang = math.radians(-22)
u = (math.cos(hs_ang), math.sin(hs_ang))
shell = c.box("Headshell", (0.1, 0.042, 0.01), (ARM_L - 0.046 * u[0], -0.046 * u[1], z_arm - 0.004), bevel=0.006, mat=black_plastic)
shell.rotation_euler.z = hs_ang
cart = c.box("Cartridge", (0.05, 0.032, 0.022), (ARM_L - 0.014 * u[0], -0.014 * u[1], z_arm - 0.018), bevel=0.005, mat=cart_red)
cart.rotation_euler.z = hs_ang
parts += [shell, cart]

rig = bpy.data.objects.new("ArmRig", None)
bpy.context.collection.objects.link(rig)
for o in parts:
    o.parent = rig
rig.location = (PIVOT[0], PIVOT[1], 0)
rig.rotation_euler.z = math.radians(mid)
bpy.context.view_layer.update()

# ---------------------------------------------------------------- レンダリング
W, H = 1.28, 1.0
disc_size = 2 * (PLATTER_R + 0.012)
spinning = [platter, dots, record, label]

# 1. 本体 (プラッターの影は落とすが写さない)
set_mat(platter, platter_mat("full"))
set_mat(record, vinyl_mat("diffuse"))
set_mat(label, label_gray)
set_mat(dots, chrome)
cam.frame(0, 0, W, H)
c.render(os.path.join(OUT, "base.png"), show=static, shadow_only=spinning, catcher=None)

# 2. 回転する盤 (反射なし)
set_mat(platter, platter_mat("diffuse"))
set_mat(dots, c.material("DotsDiffuse", color=(0.72, 0.72, 0.74), roughness=0.5))
cam.frame(CENTER[0], CENTER[1], disc_size, disc_size)
c.render(os.path.join(OUT, "disc.png"), show=spinning)

# 3. 回転しない反射 (盤の上に加算合成)。環境光を落として溝に映る光の筋を拾う
set_mat(platter, platter_mat("full"))
set_mat(record, vinyl_mat("glossy"))
set_mat(label, matte_black)
set_mat(dots, matte_black)
c.world_strength(0.04)
key.data.size, key.data.energy = 1.3, 130
fill.data.energy = 0
c.render(os.path.join(OUT, "sheen.png"), show=spinning)
c.world_strength(0.55)
key.data.size, key.data.energy = 4.0, 300
fill.data.energy = 85

# 4. スピンドル
c.render(os.path.join(OUT, "spindle.png"), show=[spindle])

# 5. トーンアームとその影 (本体と同じキャンバス)
cam.frame(0, 0, W, H)
c.render(os.path.join(OUT, "arm.png"), show=parts)
arm_catcher = c.shadow_catcher(size=8, z=Z_RECORD + 0.0005)
c.render(os.path.join(OUT, "arm_shadow.png"), show=[], shadow_only=parts, catcher=arm_catcher)

cam.frame(0, 0, W, H)
c.write_layout(os.path.join(OUT, "layout.json"), {
    "canvas": [round(W * K), round(H * K)],
    "disc": {"center": cam.px(*CENTER), "size": round(disc_size * K), "labelRadius": round(LABEL_R * K, 1), "rpm": 33.333},
    "arm": {
        "pivot": cam.px(*PIVOT),
        # 画面座標 (y 下向き・時計回りが正) の角度
        "renderedAngle": round(-mid, 3),
        "outerAngle": round(-arm_angle(R_OUTER), 3),
        "innerAngle": round(-arm_angle(R_INNER), 3),
        "restAngle": 95.0,
        "length": round(ARM_L * K, 1),
    },
    "buttons": {k: {"center": cam.px(v[0], v[1]), "size": [round(v[2] * K), round(v[3] * K)]} for k, v in buttons.items()},
})
print("done")
