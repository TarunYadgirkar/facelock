"""Rebuild the benchmark manifest with numpy, as a cross-check of `facelock-bench accuracy`, which
rebuilds the same list in Swift (PCG64 and Generator.shuffle, bit for bit).

The 0.4 impostor-bank recipe: every LFW funneled image in sorted path order, the first image of each
identity, shuffled with numpy.random.default_rng(1), the first 4,000; then every image of the 5
stand-in owners. (0.4 also skipped images without a YuNet face; every one of the 13,233 has one.)
The list goes to bench/out/manifest.tsv, which git ignores: file names are not committed.

usage: python -I bench/make_manifest.py [bench/data/lfw_funneled]
"""
import hashlib
import sys
from pathlib import Path

import numpy as np

EXPECTED = "d6c2e2b8da8d5b43a1f05478563b1a5e60600b67b9c906173eaac7e3cbd29462"
OWNERS = ["George_W_Bush", "Colin_Powell", "Tony_Blair", "Donald_Rumsfeld", "Gerhard_Schroeder"]
HERE = Path(__file__).resolve().parent

lfw = Path(sys.argv[1]) if len(sys.argv) > 1 else HERE / "data/lfw_funneled"
rel = sorted(f"{lfw.name}/{p.parent.name}/{p.name}" for p in lfw.glob("*/*.jpg"))
names = [r.split("/")[1] for r in rel]
first = {}
for j, n in enumerate(names):
    first.setdefault(n, j)
idx = np.array(sorted(first.values()))
np.random.default_rng(1).shuffle(idx)
rows = [("impostor", names[j], rel[j]) for j in idx[:4000]]
rows += [("genuine", n, r) for n, r in zip(names, rel) if n in OWNERS]
text = "role\tidentity\tpath\n" + "".join("\t".join(r) + "\n" for r in rows)
digest = hashlib.sha256(text.encode()).hexdigest()
out = HERE / "out/manifest.tsv"
out.parent.mkdir(exist_ok=True)
out.write_text(text)
print(f"{len(rows)} rows, sha256 {digest} ({'matches' if digest == EXPECTED else 'DOES NOT MATCH'} the committed hash)")
sys.exit(0 if digest == EXPECTED else 1)
