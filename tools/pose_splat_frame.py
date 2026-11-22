"""Pose one frame of a skinned splat walker (Geppetto live export) and write a standard .splat.

    py tools/pose_splat_frame.py LIVE_DIR OUT.splat [--frame 30]

LIVE_DIR holds splats.bin (centre f32x3, scale f32x3, quat f32x4 xyzw, rgba u8x4), skin.bin
(bone index u8x4, weight u8x4) and bones.bin (T x B x 4x4 f32 column-major, pose @ rest^-1).
Linear-blend skinning moves each centre; the blended matrix's rotation turns each splat.
The posed figure is moved to stand at the origin (feet at y = 0) facing -Z, its walking
direction, and written as .splat: position f32x3, scale f32x3, rgba u8x4, rotation u8x4 (w x y z).
"""
import argparse, json, os
import numpy as np


def load(live):
    meta = json.load(open(os.path.join(live, "meta.json")))
    N, B, T = meta["numSplats"], meta["numBones"], meta["frames"]
    rec = np.fromfile(os.path.join(live, "splats.bin"),
                      dtype=[("c", "<f4", 3), ("s", "<f4", 3), ("q", "<f4", 4), ("rgba", "u1", 4)])
    skin = np.fromfile(os.path.join(live, "skin.bin"), dtype=np.uint8).reshape(N, 8)
    bones = np.fromfile(os.path.join(live, "bones.bin"), dtype="<f4").reshape(T, B, 4, 4).transpose(0, 1, 3, 2)
    return meta, rec, skin, bones


def pose(meta, rec, skin, bones, frame, keep=None, scale_mult=1.0):
    """One posed figure, standing at the origin (feet y = 0) facing -Z, as .splat records."""
    if keep is not None:
        rec, skin = rec[keep], skin[keep]
    N, T = len(rec), meta["frames"]
    gi, gw = skin[:, :4].astype(int), skin[:, 4:].astype(np.float64) / 255.0
    t = frame % T
    M = (gw[:, :, None, None] * bones[t][gi]).sum(1)
    c = np.einsum("nij,nj->ni", M[:, :3, :3], rec["c"]) + M[:, :3, 3]
    U, _, Vt = np.linalg.svd(M[:, :3, :3])
    R = U @ Vt
    R[np.linalg.det(R) < 0] *= -1
    x, y, z, w = rec["q"].T
    Q = np.stack([
        np.stack([1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)], -1),
        np.stack([2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)], -1),
        np.stack([2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)], -1)], 1)
    Rq = R @ Q
    hip0 = np.array(meta["rest_heads"][0] + [1.0]) if "rest_heads" in meta else np.array([0, 0.93, 0, 1.0])
    hp = lambda f: (bones[f % T][0] @ hip0)[:3]
    d = hp(t + 10) - hp(t - 10)
    yaw = np.arctan2(d[0], -d[2])
    cy, sy = np.cos(yaw), np.sin(yaw)
    Ry = np.array([[cy, 0, -sy], [0, 1, 0], [sy, 0, cy]])
    c = c - np.array([hp(t)[0], 0, hp(t)[2]])
    c = c @ Ry.T
    c[:, 1] -= np.percentile(c[:, 1], 0.5)
    m = Ry @ Rq
    qw = np.sqrt(np.maximum(0, 1 + m[:, 0, 0] + m[:, 1, 1] + m[:, 2, 2])) / 2
    qx = np.copysign(np.sqrt(np.maximum(0, 1 + m[:, 0, 0] - m[:, 1, 1] - m[:, 2, 2])) / 2, m[:, 2, 1] - m[:, 1, 2])
    qy = np.copysign(np.sqrt(np.maximum(0, 1 - m[:, 0, 0] + m[:, 1, 1] - m[:, 2, 2])) / 2, m[:, 0, 2] - m[:, 2, 0])
    qz = np.copysign(np.sqrt(np.maximum(0, 1 - m[:, 0, 0] - m[:, 1, 1] + m[:, 2, 2])) / 2, m[:, 1, 0] - m[:, 0, 1])
    q = np.stack([qw, qx, qy, qz], 1)
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    out = np.zeros(N, dtype=[("p", "<f4", 3), ("s", "<f4", 3), ("rgba", "u1", 4), ("r", "u1", 4)])
    out["p"] = c
    out["s"] = rec["s"] * scale_mult
    out["rgba"] = rec["rgba"]
    out["r"] = np.clip(np.round(q * 128 + 128), 0, 255).astype(np.uint8)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("live")
    ap.add_argument("out")
    ap.add_argument("--frame", type=int, default=30)
    a = ap.parse_args()
    meta, rec, skin, bones = load(a.live)
    out = pose(meta, rec, skin, bones, a.frame)
    out.tofile(a.out)
    c = out["p"]
    print(f"{a.out}: {len(out):,} splats, frame {a.frame % meta['frames']}, height {c[:, 1].max():.2f} m, "
          f"{os.path.getsize(a.out) / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
