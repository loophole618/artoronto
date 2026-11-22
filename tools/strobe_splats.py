"""A splat chronophotograph: one skinned walker frozen at evenly spaced moments of its walk.

    py tools/strobe_splats.py LIVE_DIR OUT_DIR [--length 9.5] [--every 0.6] [--per 15000]

Figure k stands k * every metres along the walk, posed at the frame where the walker
itself is that far along, so the strobe reads as one walk cut at equal distances
(Muybridge's plates). Each figure is written at the origin facing -Z; the phone lays
them along the saved path. The file name carries the layout the phone reads back:
  strobe-n<figures>-every<metres>.splat   (figures are consecutive, equal splat counts)
Figures are subsampled to --per splats each, with splat size enlarged to keep coverage.
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pose_splat_frame import load, pose


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("live")
    ap.add_argument("out_dir")
    ap.add_argument("--length", type=float, default=9.5)
    ap.add_argument("--every", type=float, default=0.6)
    ap.add_argument("--per", type=int, default=15000)
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    meta, rec, skin, bones = load(a.live)
    N, T = meta["numSplats"], meta["frames"]
    keep = np.sort(np.random.default_rng(a.seed).choice(N, size=min(a.per, N), replace=False))
    grow = float(np.sqrt(N / len(keep)))
    n = int(a.length // a.every) + 1
    figs = []
    for k in range(n):
        s = k * a.every
        frame = int(round((s % meta["distance"]) / meta["distance"] * T))
        figs.append(pose(meta, rec, skin, bones, frame, keep=keep, scale_mult=grow))
    out = np.concatenate(figs)
    name = f"strobe-n{n}-every{a.every:.2f}.splat"
    path = os.path.join(a.out_dir, name)
    out.tofile(path)
    print(f"{path}: {n} figures x {len(keep):,} splats ({len(out):,}), every {a.every} m over {a.length} m, "
          f"splat size x{grow:.2f}, {os.path.getsize(path)/1e6:.1f} MB")


if __name__ == "__main__":
    main()
