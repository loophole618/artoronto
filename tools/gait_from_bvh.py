"""One gait cycle from a CMU BVH walk, as bone directions, written as a Swift table.

    py tools/gait_from_bvh.py path/to/35_01.bvh ios/HelloAR/GaitCMU.swift [--frames 60]

Forward kinematics on the BVH, the right heel-strike-to-heel-strike cycle nearest the middle
of the clip, then per frame (resampled to --frames):
  - hips: sideways sway, height, and forward residual against an even advance, in hip-heights
  - for each bone, its unit direction in the body frame (x = the walker's left, y = up,
    z = forward along the travel)
The phone rebuilds the pose on its own figure's bone lengths, so proportions stay the
figure's and the motion stays the capture's.
"""
import argparse, math, re, sys
import numpy as np


def parse_bvh(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    head, motion = text.split("MOTION", 1)
    joints, stack, order = {}, [], []
    tokens = re.findall(r"[^\s{}]+|[{}]", head)
    i = 0
    cur = None
    while i < len(tokens):
        t = tokens[i]
        if t in ("ROOT", "JOINT"):
            name = tokens[i + 1]
            joints[name] = {"parent": stack[-1] if stack else None, "offset": None, "channels": []}
            order.append(name)
            cur = name
            i += 2
        elif t == "End":
            cur = None
            i += 2
        elif t == "{":
            stack.append(cur)
            i += 1
        elif t == "}":
            stack.pop()
            i += 1
        elif t == "OFFSET":
            if cur:
                joints[cur]["offset"] = np.array([float(x) for x in tokens[i + 1:i + 4]])
            i += 4
        elif t == "CHANNELS":
            n = int(tokens[i + 1])
            if cur:
                joints[cur]["channels"] = tokens[i + 2:i + 2 + n]
            i += 2 + n
        else:
            i += 1
    lines = [l for l in motion.strip().splitlines() if l.strip()]
    nframes = int(lines[0].split(":")[1])
    dt = float(lines[1].split(":")[1])
    data = np.array([[float(x) for x in l.split()] for l in lines[2:2 + nframes]])
    return joints, order, data, dt


def rot(axis, deg):
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    if axis == "X":
        return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])
    if axis == "Y":
        return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def fk(joints, order, row):
    pos, R, k = {}, {}, 0
    for name in order:
        j = joints[name]
        local_t = j["offset"].copy()
        local_R = np.eye(3)
        for ch in j["channels"]:
            v = row[k]; k += 1
            if ch.endswith("position"):
                local_t["XYZ".index(ch[0])] = v
            else:
                local_R = local_R @ rot(ch[0], v)
        p = j["parent"]
        if p is None:
            pos[name], R[name] = local_t, local_R
        else:
            pos[name] = pos[p] + R[p] @ local_t
            R[name] = R[p] @ local_R
    return pos


BONES = [  # (name, from CMU joint, to CMU joint)
    ("spine", "Hips", "Neck"), ("head", "Neck", "Head"),
    ("lShoulder", "Neck", "LeftArm"), ("rShoulder", "Neck", "RightArm"),
    ("lUpperArm", "LeftArm", "LeftForeArm"), ("lForearm", "LeftForeArm", "LeftHand"),
    ("rUpperArm", "RightArm", "RightForeArm"), ("rForearm", "RightForeArm", "RightHand"),
    ("lPelvis", "Hips", "LeftUpLeg"), ("rPelvis", "Hips", "RightUpLeg"),
    ("lThigh", "LeftUpLeg", "LeftLeg"), ("lShin", "LeftLeg", "LeftFoot"), ("lFoot", "LeftFoot", "LeftToeBase"),
    ("rThigh", "RightUpLeg", "RightLeg"), ("rShin", "RightLeg", "RightFoot"), ("rFoot", "RightFoot", "RightToeBase"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("bvh")
    ap.add_argument("out")
    ap.add_argument("--frames", type=int, default=60)
    a = ap.parse_args()
    joints, order, data, dt = parse_bvh(a.bvh)
    P = [fk(joints, order, row) for row in data]
    hips = np.array([p["Hips"] for p in P])
    fR = np.array([p["RightFoot"] for p in P])

    # Right heel strikes: the foot's horizontal speed drops under 30% of the body's (Y is up).
    hv = lambda arr: np.linalg.norm(np.diff(arr[:, [0, 2]], axis=0), axis=1)
    body = np.median(hv(hips))
    stance = hv(fR) < 0.3 * body
    strikes = [i for i in range(1, len(stance)) if stance[i] and not stance[i - 1]]
    cands = [(i, j) for i, j in zip(strikes, strikes[1:]) if i > 3 and j < len(P) - 3]
    if not cands:
        sys.exit(f"no complete right gait cycle (strikes {strikes})")
    mid = len(P) / 2
    i0, i1 = min(cands, key=lambda c: abs((c[0] + c[1]) / 2 - mid))
    L = i1 - i0

    # Body frame from the cycle's travel.
    travel = hips[i1] - hips[i0]
    fwd = np.array([travel[0], 0, travel[2]]); fwd /= np.linalg.norm(fwd)
    up = np.array([0.0, 1.0, 0.0])
    left = np.cross(up, fwd)
    left_check = np.mean([p["LeftUpLeg"] - p["RightUpLeg"] for p in P[i0:i1]], axis=0)
    if np.dot(left_check, left) < 0:
        left = -left
    B = np.stack([left, up, fwd])   # rows: body axes

    floor = min(min(p["LeftToeBase"][1], p["RightToeBase"][1], p["LeftFoot"][1], p["RightFoot"][1]) for p in P[i0:i1 + 1])
    hip_h = np.mean([p["Hips"][1] for p in P[i0:i1]]) - floor
    stride = float(np.dot(travel, fwd)) / hip_h          # cycle length in hip-heights

    frames = []
    for n in range(a.frames):
        u = i0 + L * n / a.frames
        k0 = int(math.floor(u)); fr = u - k0
        def lerp(name):
            return (1 - fr) * P[k0][name] + fr * P[k0 + 1][name]
        h = lerp("Hips")
        even = hips[i0] + travel * (u - i0) / L
        rel = B @ (h - even)
        hip = [rel[0] / hip_h, (h[1] - floor) / hip_h, rel[2] / hip_h]
        dirs = []
        for _, a_, b_ in BONES:
            d = B @ (lerp(b_) - lerp(a_))
            dirs.append(d / max(np.linalg.norm(d), 1e-9))
        frames.append((hip, dirs))

    names = [b[0] for b in BONES]
    flat = []
    for hip, dirs in frames:
        flat += hip
        for d in dirs:
            flat += list(d)
    rows = [", ".join(f"{v:.4f}" for v in flat[i:i + 12]) for i in range(0, len(flat), 12)]
    swift = [
        "// One captured gait cycle (CMU motion capture 35_01, right heel strike to right heel strike).",
        "// Generated by tools/gait_from_bvh.py; do not edit by hand.",
        "enum GaitCMU {",
        f"    static let frames = {a.frames}",
        f"    static let strideInHipHeights: Float = {stride:.4f}",
        f"    static let bones = [{', '.join(repr(n).replace(chr(39), chr(34)) for n in names)}]",
        "    /// Per frame: hips (sway, height, forward residual) in hip-heights, then a unit direction per bone.",
        "    static let data: [Float] = [",
    ] + [f"        {r}," for r in rows] + ["    ]", "}", ""]
    open(a.out, "w", encoding="utf-8").write("\n".join(swift))
    print(f"cycle frames {i0}..{i1} ({L} @ {1/dt:.0f} fps, {L*dt:.2f} s), stride {stride:.2f} hip-heights, "
          f"hip height {hip_h:.2f} BVH units, {a.frames} frames x {len(BONES)} bones -> {a.out}")


if __name__ == "__main__":
    main()
