"""Blender で機器のスキン素材をレンダリングするための共通処理。

真上からの平行投影カメラで撮り、回転する部品・動く部品は別々のレイヤーとして書き出す。
アプリ側はレイアウト JSON を読んで、同じピクセル座標系で重ねる。
"""

import json
import math
import os

import bpy
from mathutils import Vector

# ---------------------------------------------------------------- シーン


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    try:
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL"
        prefs.refresh_devices()
        for d in prefs.devices:
            d.use = d.type != "CPU"
        scene.cycles.device = "GPU"
        print("devices:", [(d.name, d.type, d.use) for d in prefs.devices])
    except Exception as e:  # noqa: BLE001
        print("GPU unavailable:", e)
    scene.cycles.samples = 192
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 10
    scene.cycles.transmission_bounces = 10
    scene.render.film_transparent = True
    try:
        scene.cycles.film_transparent_glass = True
    except AttributeError:
        pass
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    scene.render.image_settings.compression = 90
    try:
        scene.view_settings.view_transform = "AgX"
        scene.view_settings.look = "AgX - Base Contrast"
    except TypeError:
        pass
    return scene


def world(hdri="studio.exr", strength=0.9, rotation=0.0, flatten=0.6, gray=0.42):
    """環境光。flatten で HDRI を均一なグレーに寄せ、映り込みを穏やかにする"""
    w = bpy.data.worlds.new("World")
    bpy.context.scene.world = w
    w.use_nodes = True
    nt = w.node_tree
    nt.nodes.clear()
    out = nt.nodes.new("ShaderNodeOutputWorld")
    bg = nt.nodes.new("ShaderNodeBackground")
    env = nt.nodes.new("ShaderNodeTexEnvironment")
    mapping = nt.nodes.new("ShaderNodeMapping")
    coord = nt.nodes.new("ShaderNodeTexCoord")
    import glob

    path = bpy.utils.system_resource("DATAFILES", path=f"studiolights/world/{hdri}")
    if not path or not os.path.exists(path):
        found = glob.glob(os.path.join(os.path.dirname(bpy.app.binary_path), "..", "Resources", "*", "datafiles",
                                       "studiolights", "world", hdri))
        path = os.path.abspath(found[0])
    env.image = bpy.data.images.load(path)
    mapping.inputs["Rotation"].default_value = (0, 0, rotation)
    nt.links.new(coord.outputs["Generated"], mapping.inputs["Vector"])
    nt.links.new(mapping.outputs["Vector"], env.inputs["Vector"])
    mix = nt.nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.inputs["Factor"].default_value = flatten
    mix.inputs["B"].default_value = (gray, gray, gray, 1)
    nt.links.new(env.outputs["Color"], mix.inputs["A"])
    nt.links.new(mix.outputs["Result"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = strength
    nt.links.new(bg.outputs["Background"], out.inputs["Surface"])


def world_strength(value):
    bg = bpy.context.scene.world.node_tree.nodes.get("Background")
    bg.inputs["Strength"].default_value = value


def area_light(location, target=(0, 0, 0), size=1.5, power=120, color=(1, 0.97, 0.92)):
    data = bpy.data.lights.new("Key", "AREA")
    data.size = size
    data.energy = power
    data.color = color
    obj = bpy.data.objects.new("Key", data)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    direction = Vector(target) - Vector(location)
    obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    return obj


class Camera:
    """真上から見る平行投影カメラ。k = 1BU あたりのピクセル数"""

    def __init__(self, k):
        self.k = k
        data = bpy.data.cameras.new("Cam")
        data.type = "ORTHO"
        data.sensor_fit = "HORIZONTAL"
        data.clip_start = 0.01
        data.clip_end = 100
        self.obj = bpy.data.objects.new("Cam", data)
        bpy.context.collection.objects.link(self.obj)
        bpy.context.scene.camera = self.obj
        self.frame(0, 0, 1, 1)

    def frame(self, cx, cy, w, h, tilt=0.0):
        """中心 (cx, cy)、幅 w × 高さ h (BU) を写す。

        tilt (度) を指定すると、機器の上端 (+Y) 側へ傾けて見下ろす (上面が見える)。
        このとき (cx, cy) は画面上の座標 u = x、v = y·cosθ − z·sinθ で表す。
        """
        self.cx, self.cy, self.w, self.h = cx, cy, w, h
        t = math.radians(tilt)
        self.cos, self.sin = math.cos(t), math.sin(t)
        self.obj.location = (cx, cy * self.cos + 20 * self.sin, -cy * self.sin + 20 * self.cos)
        self.obj.rotation_euler = (-t, 0, 0)
        self.obj.data.ortho_scale = w
        r = bpy.context.scene.render
        r.resolution_x = round(w * self.k)
        r.resolution_y = round(h * self.k)
        r.resolution_percentage = 100
        r.use_border = False
        r.use_crop_to_border = False

    def px(self, x, y, z=0.0):
        """ワールド座標 → 画像ピクセル (左上原点、y 下向き)"""
        W = round(self.w * self.k)
        H = round(self.h * self.k)
        v = y * self.cos - z * self.sin
        return [round(W / 2 + (x - self.cx) * self.k, 2), round(H / 2 - (v - self.cy) * self.k, 2)]

    def bounds(self, objs, margin=4):
        """オブジェクトが写る範囲 (ピクセル、整数) を [x0, y0, x1, y1] で返す"""
        W = round(self.w * self.k)
        H = round(self.h * self.k)
        bpy.context.view_layer.update()
        xs, ys = [], []
        for o in objs:
            for corner in o.bound_box:
                p = o.matrix_world @ Vector(corner)
                x, y = self.px(p.x, p.y, p.z)
                xs.append(x)
                ys.append(y)
        return [max(0, math.floor(min(xs)) - margin), max(0, math.floor(min(ys)) - margin),
                min(W, math.ceil(max(xs)) + margin), min(H, math.ceil(max(ys)) + margin)]

    def crop(self, box):
        """次のレンダリングを box = [x0, y0, x1, y1] (ピクセル) だけに切り抜く"""
        W = round(self.w * self.k)
        H = round(self.h * self.k)
        r = bpy.context.scene.render
        r.use_border = True
        r.use_crop_to_border = True
        r.border_min_x = (box[0] + 0.25) / W
        r.border_max_x = (box[2] + 0.25) / W
        r.border_min_y = (H - box[3] + 0.25) / H
        r.border_max_y = (H - box[1] + 0.25) / H

    def uncrop(self):
        r = bpy.context.scene.render
        r.use_border = False
        r.use_crop_to_border = False


def render(path, show, hide_all=True, shadow_only=(), catcher=None):
    """`show` のオブジェクトだけを写してレンダリング。`shadow_only` は写らないが影は落とす"""
    for o in bpy.data.objects:
        if o.type in ("CAMERA", "LIGHT"):
            continue
        visible = o in show or o in shadow_only or o is catcher
        o.hide_render = not visible if hide_all else o.hide_render
        o.visible_camera = o not in shadow_only
    for o in shadow_only:
        o.visible_camera = False
        o.visible_glossy = False
        o.visible_diffuse = True
        o.visible_shadow = True
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.context.scene.render.filepath = path
    bpy.ops.render.render(write_still=True)
    for o in shadow_only:
        o.visible_glossy = True
    print("rendered", path)


def write_layout(path, data):
    with open(path, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


# ---------------------------------------------------------------- 形状


def _finish(obj, smooth=True, angle=35):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    if smooth:
        try:
            bpy.ops.object.shade_auto_smooth(angle=math.radians(angle))
        except Exception:  # noqa: BLE001
            bpy.ops.object.shade_smooth()
    obj.select_set(False)
    return obj


def box(name, size, location, bevel=0.0, segments=6, mat=None):
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    if bevel > 0:
        m = obj.modifiers.new("Bevel", "BEVEL")
        m.width = bevel
        m.segments = segments
        m.limit_method = "ANGLE"
        m.harden_normals = False
    if mat:
        obj.data.materials.append(mat)
    return _finish(obj)


def rounded_rect(name, w, h, depth, radius, location, bevel=0.004, mat=None, segments=12):
    """角丸の板 (上面の縁にも小さな面取り)"""
    bpy.ops.mesh.primitive_cube_add(size=1, location=location)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (w, h, depth)
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    # 縦の 4 辺だけ大きく丸める
    bpy.ops.object.mode_set(mode="EDIT")
    import bmesh

    bm = bmesh.from_edit_mesh(obj.data)
    vertical = [e for e in bm.edges if abs((e.verts[0].co - e.verts[1].co).normalized().z) > 0.99]
    bmesh.ops.bevel(bm, geom=vertical, offset=radius, segments=segments, affect="EDGES", profile=0.5)
    bmesh.update_edit_mesh(obj.data)
    bpy.ops.object.mode_set(mode="OBJECT")
    if bevel > 0:
        m = obj.modifiers.new("Bevel", "BEVEL")
        m.width = bevel
        m.segments = 4
        m.limit_method = "ANGLE"
        m.angle_limit = math.radians(60)
    if mat:
        obj.data.materials.append(mat)
    return _finish(obj, angle=50)


def cylinder(name, radius, depth, location, verts=128, bevel=0.0, mat=None, rotation=(0, 0, 0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=radius, depth=depth, location=location, rotation=rotation)
    obj = bpy.context.active_object
    obj.name = name
    if bevel > 0:
        m = obj.modifiers.new("Bevel", "BEVEL")
        m.width = bevel
        m.segments = 4
        m.limit_method = "ANGLE"
    if mat:
        obj.data.materials.append(mat)
    return _finish(obj, angle=40)


def cut(obj, cutter, apply=True):
    m = obj.modifiers.new("Cut", "BOOLEAN")
    m.operation = "DIFFERENCE"
    m.object = cutter
    if apply:
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.modifier_apply(modifier=m.name)
        bpy.data.objects.remove(cutter, do_unlink=True)
    else:
        cutter.hide_render = True
        cutter.hide_viewport = True
    return obj


def join(objs, name):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    obj = bpy.context.active_object
    obj.name = name
    return obj


def text(name, body, size, location, font=None, mat=None, align="CENTER", extrude=0.0004, rotation=0.0, tilt=0.0):
    curve = bpy.data.curves.new(name, "FONT")
    curve.body = body
    curve.size = size
    curve.align_x = align
    curve.align_y = "CENTER"
    curve.extrude = extrude
    if font:
        curve.font = bpy.data.fonts.load(font)
    obj = bpy.data.objects.new(name, curve)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (tilt, 0, rotation)
    if mat:
        curve.materials.append(mat)
    return obj


def polygon(name, points, location, mat=None, thickness=0.0005, tilt=0.0):
    """XY 平面の多角形を薄い板にする。tilt は X 軸まわりの回転 (ラジアン)"""
    mesh = bpy.data.meshes.new(name)
    verts = [(x, y, 0) for x, y in points] + [(x, y, thickness) for x, y in points]
    n = len(points)
    faces = [list(range(n - 1, -1, -1)), list(range(n, 2 * n))]
    faces += [[i, (i + 1) % n, n + (i + 1) % n, n + i] for i in range(n)]
    mesh.from_pydata(verts, [], faces)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.location = location
    obj.rotation_euler = (tilt, 0, 0)
    if mat:
        obj.data.materials.append(mat)
    return obj


def shadow_catcher(size=6, z=0.0):
    bpy.ops.mesh.primitive_plane_add(size=size, location=(0, 0, z))
    p = bpy.context.active_object
    p.name = "ShadowCatcher"
    p.is_shadow_catcher = True
    return p


# ---------------------------------------------------------------- 材質


def material(name, color=(0.8, 0.8, 0.8), metallic=0.0, roughness=0.5, **inputs):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    for k, v in inputs.items():
        key = k.replace("_", " ")
        if isinstance(v, tuple) and len(v) == 3:
            v = (*v, 1)
        bsdf.inputs[key].default_value = v
    return m


def nodes(m):
    return m.node_tree.nodes, m.node_tree.links, m.node_tree.nodes["Principled BSDF"]


def add_bump(m, height_socket, strength=0.2, distance=0.001):
    n, l, bsdf = nodes(m)
    bump = n.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = strength
    bump.inputs["Distance"].default_value = distance
    l.new(height_socket, bump.inputs["Height"])
    l.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return bump


def brushed(m, direction="X", scale=900, rough=(0.22, 0.34), strength=0.08):
    """直線のヘアライン"""
    n, l, bsdf = nodes(m)
    tc = n.new("ShaderNodeTexCoord")
    mp = n.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (scale, 2, 1) if direction == "Y" else (2, scale, 1)
    noise = n.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 1.0
    noise.inputs["Detail"].default_value = 6
    rng = n.new("ShaderNodeMapRange")
    rng.inputs["To Min"].default_value = rough[0]
    rng.inputs["To Max"].default_value = rough[1]
    l.new(tc.outputs["Object"], mp.inputs["Vector"])
    l.new(mp.outputs["Vector"], noise.inputs["Vector"])
    l.new(noise.outputs["Fac"], rng.inputs["Value"])
    l.new(rng.outputs["Result"], bsdf.inputs["Roughness"])
    bsdf.inputs["Anisotropic"].default_value = 0.7
    tan = n.new("ShaderNodeTangent")
    tan.direction_type = "RADIAL"
    tan.axis = "Y" if direction == "X" else "X"
    l.new(tan.outputs["Tangent"], bsdf.inputs["Tangent"])
    add_bump(m, noise.outputs["Fac"], strength=strength, distance=0.0005)


def radial_hairline(m, rings=600, strength=0.06, anis=0.85, center=(0, 0)):
    """同心円のヘアライン (CD プレイヤーの天板・レコード盤など)。中心はオブジェクト座標で指定"""
    n, l, bsdf = nodes(m)
    tc = n.new("ShaderNodeTexCoord")
    mp = n.new("ShaderNodeMapping")
    mp.inputs["Location"].default_value = (-center[0], -center[1], 0)
    wave = n.new("ShaderNodeTexWave")
    wave.wave_type = "RINGS"
    wave.rings_direction = "SPHERICAL"
    wave.inputs["Scale"].default_value = rings
    wave.inputs["Distortion"].default_value = 2.0
    wave.inputs["Detail"].default_value = 4
    l.new(tc.outputs["Object"], mp.inputs["Vector"])
    l.new(mp.outputs["Vector"], wave.inputs["Vector"])
    tan = n.new("ShaderNodeTangent")
    tan.direction_type = "RADIAL"
    tan.axis = "Z"
    l.new(tan.outputs["Tangent"], bsdf.inputs["Tangent"])
    bsdf.inputs["Anisotropic"].default_value = anis
    add_bump(m, wave.outputs["Fac"], strength=strength, distance=0.0003)
    return wave


def wood(m, scale=6.0, dark=(0.1, 0.045, 0.022), light=(0.24, 0.12, 0.055)):
    """縦に長い木目 (オブジェクトの Y 方向に流れる)"""
    n, l, bsdf = nodes(m)
    tc = n.new("ShaderNodeTexCoord")
    mp = n.new("ShaderNodeMapping")
    mp.inputs["Scale"].default_value = (12, 0.7, 1)
    wave = n.new("ShaderNodeTexWave")
    wave.wave_type = "BANDS"
    wave.bands_direction = "X"
    wave.inputs["Scale"].default_value = scale
    wave.inputs["Distortion"].default_value = 3
    wave.inputs["Detail"].default_value = 3
    wave.inputs["Detail Scale"].default_value = 0.8
    ramp = n.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*dark, 1)
    ramp.color_ramp.elements[1].color = (*light, 1)
    l.new(tc.outputs["Object"], mp.inputs["Vector"])
    l.new(mp.outputs["Vector"], wave.inputs["Vector"])
    l.new(wave.outputs["Fac"], ramp.inputs["Fac"])
    l.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.5
    bsdf.inputs["Coat Weight"].default_value = 0.15
    bsdf.inputs["Coat Roughness"].default_value = 0.35
    add_bump(m, wave.outputs["Fac"], strength=0.02)


def soft_surface(m, rough=0.04, tint=0.03, scale=6.0):
    """のっぺり感を減らす、ごく弱いツヤと色の揺らぎ"""
    n, l, bsdf = nodes(m)
    noise = n.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = 3
    if not bsdf.inputs["Roughness"].is_linked and rough > 0:
        r = bsdf.inputs["Roughness"].default_value
        rng = n.new("ShaderNodeMapRange")
        rng.inputs["To Min"].default_value = max(0, r - rough)
        rng.inputs["To Max"].default_value = min(1, r + rough)
        l.new(noise.outputs["Fac"], rng.inputs["Value"])
        l.new(rng.outputs["Result"], bsdf.inputs["Roughness"])
    if not bsdf.inputs["Base Color"].is_linked and tint > 0:
        base = bsdf.inputs["Base Color"].default_value[:]
        mix = n.new("ShaderNodeMix")
        mix.data_type = "RGBA"
        mix.blend_type = "MULTIPLY"
        mix.inputs["Factor"].default_value = 1
        mix.inputs["A"].default_value = base
        rng2 = n.new("ShaderNodeMapRange")
        rng2.inputs["To Min"].default_value = 1 - tint
        rng2.inputs["To Max"].default_value = 1 + tint
        l.new(noise.outputs["Fac"], rng2.inputs["Value"])
        comb = n.new("ShaderNodeCombineColor")
        for ch in ("Red", "Green", "Blue"):
            l.new(rng2.outputs["Result"], comb.inputs[ch])
        l.new(comb.outputs["Color"], mix.inputs["B"])
        l.new(mix.outputs["Result"], bsdf.inputs["Base Color"])


def paper(m, strength=0.15):
    n, l, bsdf = nodes(m)
    noise = n.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 900
    noise.inputs["Detail"].default_value = 8
    add_bump(m, noise.outputs["Fac"], strength=strength, distance=0.0002)
    soft_surface(m, rough=0.03, tint=0.025, scale=40)


def image_texture(m, path, emission=0.0, target="Base Color"):
    n, l, bsdf = nodes(m)
    tex = n.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(path)
    tex.extension = "CLIP"
    l.new(tex.outputs["Color"], bsdf.inputs[target])
    if emission > 0:
        l.new(tex.outputs["Color"], bsdf.inputs["Emission Color"])
        bsdf.inputs["Emission Strength"].default_value = emission
    return tex
