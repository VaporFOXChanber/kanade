"""カセットテープの形状と材質 (cassette.py と walkman.py で共用)

原点がカセットの中心、背面が z = 0、表面が +Z を向く。単位は BU (1BU ≒ 100mm)。
"""

import math

import bpy

import common as c

HUBS = [(-0.2, 0.015), (0.2, 0.015)]
HUB_R = 0.066
LABEL = (0.0, 0.07, 0.88, 0.39)      # 中心 x, y, 幅, 高さ
WINDOW = (0.0, 0.015, 0.62, 0.22)
SIZE = (1.0, 0.63)
HUB_Z = 0.018                         # ハブ (テープの巻き) の高さ
LABEL_Z = 0.0375                      # ラベル面の高さ


def build():
    """カセットを組み立てて、レイヤーごとの部品を返す: back (内側) / hub (回転) / front (ケース・窓・ラベル)"""
    smoke = c.material("Smoke", color=(0.045, 0.045, 0.052), roughness=0.3, Transmission_Weight=0.8, IOR=1.45)
    c.soft_surface(smoke, rough=0.04, tint=0, scale=5)
    clear = c.material("Clear", color=(0.94, 0.95, 0.96), roughness=0.09, Transmission_Weight=1.0, IOR=1.45)
    inner = c.material("Inner", color=(0.035, 0.035, 0.04), roughness=0.62)
    tape = c.material("Tape", color=(0.2, 0.12, 0.07), roughness=0.35, metallic=0.2)
    label_paper = c.material("Label", color=(0.92, 0.89, 0.81), roughness=0.84)
    c.paper(label_paper, strength=0.05)
    chrome = c.material("Chrome", color=(0.74, 0.74, 0.76), metallic=1, roughness=0.3)
    hub_white = c.material("HubWhite", color=(0.88, 0.88, 0.86), roughness=0.5, Coat_Weight=0.05)
    c.soft_surface(hub_white, rough=0.03, tint=0.03, scale=30)
    hole = c.material("Hole", color=(0.01, 0.01, 0.012), roughness=0.9)

    # ------------------------------------------------------------ 背面 (内側)
    back = c.rounded_rect("Back", 1.0, 0.63, 0.012, 0.03, (0, 0, 0.006), bevel=0.004, mat=inner)
    tape_strip = c.box("TapeStrip", (0.62, 0.012, 0.004), (0, -0.296, 0.014), mat=tape)
    back_parts = [back, tape_strip]
    for x in (-0.16, 0.16):
        back_parts.append(c.cylinder(f"Roller{x}", 0.018, 0.02, (x, -0.215, 0.012), verts=48, bevel=0.003, mat=hub_white))

    # ------------------------------------------------------------ ハブ (歯のついた白い樹脂リング)
    ring = c.cylinder("HubRing", HUB_R, 0.012, (0, 0, HUB_Z), verts=128, bevel=0.003, mat=hub_white)
    core = c.cylinder("HubCore", HUB_R * 0.6, 0.03, (0, 0, HUB_Z), verts=96)
    c.cut(ring, core)
    teeth = []
    for i in range(6):
        a = i / 6 * 2 * math.pi
        t = c.box(f"Tooth{i}", (0.012, HUB_R * 0.26, 0.012), (0, HUB_R * 0.5, HUB_Z), bevel=0.002, mat=hub_white)
        t.location = (math.sin(-a) * HUB_R * 0.5, math.cos(a) * HUB_R * 0.5, HUB_Z)
        t.rotation_euler.z = a
        teeth.append(t)
    mark = c.cylinder("HubMark", 0.006, 0.013, (0, HUB_R * 0.8, HUB_Z + 0.0005), verts=24, mat=hole)
    hub = [ring, mark] + teeth

    # ------------------------------------------------------------ 表面 (スモークのケース・窓・ラベル・ネジ)
    front = c.rounded_rect("Front", 1.0, 0.63, 0.012, 0.03, (0, 0, 0.03), bevel=0.005, mat=smoke)
    win_cut = c.rounded_rect("WinCut", WINDOW[2], WINDOW[3], 0.05, 0.1, (WINDOW[0], WINDOW[1], 0.03), bevel=0)
    c.cut(front, win_cut)
    window = c.rounded_rect("Window", WINDOW[2] - 0.004, WINDOW[3] - 0.004, 0.008, 0.098, (WINDOW[0], WINDOW[1], 0.031), bevel=0.001, mat=clear)
    lab = c.rounded_rect("Label", LABEL[2], LABEL[3], 0.0015, 0.02, (LABEL[0], LABEL[1], 0.03675), bevel=0.0005, mat=label_paper)
    lab_cut = c.rounded_rect("LabelCut", WINDOW[2] + 0.02, WINDOW[3] + 0.02, 0.05, 0.11, (WINDOW[0], WINDOW[1], 0.03), bevel=0)
    c.cut(lab, lab_cut)

    # 下部の台形 (ヘッドが当たる部分)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, -0.235, 0.039))
    trap = bpy.context.active_object
    trap.name = "Trapezoid"
    trap.scale = (0.62, 0.16, 0.006)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    for v in trap.data.vertices:
        if v.co.y > 0:
            v.co.x *= 0.82
    m = trap.modifiers.new("Bevel", "BEVEL")
    m.width = 0.004
    m.segments = 3
    trap.data.materials.append(smoke)
    for x in (-0.22, -0.06, 0.06, 0.22):
        cutter = c.box(f"Head{x}", (0.055, 0.04, 0.05), (x, -0.3, 0.03))
        c.cut(trap, cutter)
        cutter2 = c.box(f"HeadF{x}", (0.055, 0.04, 0.05), (x, -0.3, 0.03))
        c.cut(front, cutter2)

    screws = []
    for i, (x, y) in enumerate(((-0.465, 0.28), (0.465, 0.28), (-0.465, -0.28), (0.465, -0.28), (0.0, -0.2))):
        z = 0.0425 if i == 4 else 0.0365
        s = c.cylinder(f"Screw{i}", 0.013, 0.004, (x, y, z), verts=48, bevel=0.002, mat=chrome)
        slot = c.box(f"Slot{i}", (0.017, 0.003, 0.01), (x, y, z + 0.003))
        slot.rotation_euler.z = math.radians(35 + i * 20)
        c.cut(s, slot)
        screws.append(s)

    return {"back": back_parts, "hub": hub, "front": [front, window, lab, trap] + screws}


def move(parts, offset):
    """組み立て済みの部品をまとめて平行移動する"""
    for o in parts:
        o.location = (o.location[0] + offset[0], o.location[1] + offset[1], o.location[2] + offset[2])
