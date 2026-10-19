"""Build the two Core ML models FaceLock runs, from the pinned upstream files in models.lock.json.

  YuNet320x240.mlpackage  YuNet 2023mar with OpenCV's FaceDetectorYN decode inside the graph, fixed
                          320x240 BGR image input (Core ML reads the BGRA pixel buffer of the 640x480
                          camera frame after a 2x vImageScale), output dets [1680, 15] = x, y, w, h,
                          5 landmarks, score in 640x480 pixels.
  ArcFaceR50.mlpackage    InsightFace w600k_r50, 112x112 RGB image input, 512-float embedding.

Both are fp16 ML Programs, so Core ML can schedule every op on the Neural Engine.

The r50 weights are licensed for non-commercial research only and are never shipped. The app ships
ArcFaceR50.mlmodelc without weights/weight.bin and rebuilds that file on the user's Mac from the
w600k_r50.onnx it downloads. Resources/ArcFaceR50.layout.json, written here, says where each ONNX
initializer goes in weight.bin and how it was cast; it holds names, offsets and hashes, no weights.

usage: python -I tools/convert_models.py [--from DIR] [--out models] [--no-compile]
  --from DIR   look for the upstream files in DIR before downloading them
"""
import argparse
import hashlib
import json
import subprocess
import sys
import urllib.request
import warnings
import zipfile
from pathlib import Path

import numpy as np

warnings.filterwarnings("ignore")
TOOLS = Path(__file__).resolve().parent
LOCK = json.loads((TOOLS / "models.lock.json").read_text())
FRAME_W = 640
DET_W, DET_H = 320, 240


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def fetch(entry: dict, cache: Path, local: Path | None) -> Path:
    dst = cache / entry["file"]
    if not dst.exists() and local is not None and (local / entry["file"]).exists():
        dst.write_bytes((local / entry["file"]).read_bytes())
    if not dst.exists():
        print("downloading", entry["url"])
        urllib.request.urlretrieve(entry["url"], dst)
    got = sha256(dst)
    if got != entry["sha256"]:
        sys.exit(f"{dst}: sha256 {got} does not match models.lock.json {entry['sha256']}")
    return dst


def r50_onnx(cache: Path, local: Path | None) -> Path:
    entry = LOCK["w600k_r50"]
    dst = cache / entry["file"]
    if not dst.exists() and local is not None and (local / entry["file"]).exists():
        dst.write_bytes((local / entry["file"]).read_bytes())
    if not dst.exists():
        archive = fetch(LOCK[entry["archive"]], cache, local)
        with zipfile.ZipFile(archive) as z:
            dst.write_bytes(z.read(entry["member"]))
    got = sha256(dst)
    if got != entry["sha256"]:
        sys.exit(f"{dst}: sha256 {got} does not match models.lock.json {entry['sha256']}")
    return dst


def yunet_with_decode(src: Path, dst: Path) -> None:
    """float BGR image [1,3,240,320] -> zero alpha plane, pad to /32 -> YuNet -> OpenCV FaceDetectorYN decode.

    The first conv gets a zero-weight 4th input channel; the image input replaced an earlier
    float32 [1,240,320,4] MLMultiArray input and gives bit-identical detections, all 132 ops on
    the Neural Engine, without a CPU-side uint8 to float copy."""
    import onnx
    from onnx import TensorProto, helper, numpy_helper

    def const(name, arr):
        return numpy_helper.from_array(np.asarray(arr), name)

    m = onnx.load(src)
    g = m.graph
    old_in = g.input[0].name
    pw, ph = -(-DET_W // 32) * 32, -(-DET_H // 32) * 32
    inits = {i.name: i for i in g.initializer}
    for n in g.node:  # zero-weight 4th input channel so BGRA feeds the first conv directly
        if n.op_type == "Conv" and n.input[0] == old_in:
            w = numpy_helper.to_array(inits[n.input[1]])
            inits[n.input[1]].CopyFrom(numpy_helper.from_array(np.concatenate([w, np.zeros_like(w[:, :1])], 1), n.input[1]))
            break
    else:
        sys.exit("YuNet: no conv reads the input")
    pre = [helper.make_node("Concat", ["image", "zero_alpha"], ["nchw"], axis=1),
           helper.make_node("Pad", ["nchw", "pads"], [old_in], mode="constant")]
    g.input.remove(g.input[0])
    g.input.insert(0, helper.make_tensor_value_info("image", TensorProto.FLOAT, [1, 3, DET_H, DET_W]))
    g.initializer.append(const("zero_alpha", np.zeros((1, 1, DET_H, DET_W), np.float32)))
    for n in reversed(pre):
        g.node.insert(0, n)
    g.initializer.append(const("pads", np.array([0, 0, 0, 0, 0, 0, ph - DET_H, pw - DET_W], np.int64)))

    scale = FRAME_W / DET_W
    grid, stride = [], []
    for s in (8, 16, 32):
        cols, rows = pw // s, ph // s
        r, c = np.divmod(np.arange(rows * cols), cols)
        grid.append(np.stack([c, r], 1))
        stride.append(np.full((rows * cols, 1), s))
    grid = np.concatenate(grid).astype(np.float32)
    stride = np.concatenate(stride).astype(np.float32)
    n = len(grid)
    g.initializer.extend([
        const("d_grid", grid), const("d_grid5", np.tile(grid, (1, 5))), const("d_stride_s", stride * scale),
        const("d_half", np.float32(0.5)), const("d_zero", np.float32(0)), const("d_one", np.float32(1)),
        const("d_n1", np.array([n, 1], np.int64)), const("d_n4", np.array([n, 4], np.int64)),
        const("d_n10", np.array([n, 10], np.int64)), const("d_s0", np.array([0], np.int64)),
        const("d_s2", np.array([2], np.int64)), const("d_s4", np.array([4], np.int64)),
        const("d_ax1", np.array([1], np.int64)),
    ])
    mk = helper.make_node
    nodes = []
    for kind, shape in (("cls", "d_n1"), ("obj", "d_n1"), ("bbox", "d_n4"), ("kps", "d_n10")):
        nodes.append(mk("Concat", [f"{kind}_8", f"{kind}_16", f"{kind}_32"], [f"{kind}_cat"], axis=1))
        nodes.append(mk("Reshape", [f"{kind}_cat", shape], [f"{kind}_all"]))
    nodes += [
        mk("Clip", ["cls_all", "d_zero", "d_one"], ["cls_c"]), mk("Clip", ["obj_all", "d_zero", "d_one"], ["obj_c"]),
        mk("Mul", ["cls_c", "obj_c"], ["co"]), mk("Sqrt", ["co"], ["score"]),
        mk("Slice", ["bbox_all", "d_s0", "d_s2", "d_ax1"], ["b_xy"]),
        mk("Slice", ["bbox_all", "d_s2", "d_s4", "d_ax1"], ["b_wh"]),
        mk("Add", ["b_xy", "d_grid"], ["b_xyg"]), mk("Mul", ["b_xyg", "d_stride_s"], ["b_center"]),
        mk("Exp", ["b_wh"], ["b_ewh"]), mk("Mul", ["b_ewh", "d_stride_s"], ["b_size"]),
        mk("Mul", ["b_size", "d_half"], ["b_halfsize"]), mk("Sub", ["b_center", "b_halfsize"], ["b_x1y1"]),
        mk("Add", ["kps_all", "d_grid5"], ["k_g"]), mk("Mul", ["k_g", "d_stride_s"], ["k_xy"]),
        mk("Concat", ["b_x1y1", "b_size", "k_xy", "score"], ["dets"], axis=1),
    ]
    g.node.extend(nodes)
    del g.output[:]
    g.output.append(helper.make_tensor_value_info("dets", TensorProto.FLOAT, [n, 15]))
    del g.value_info[:]
    m.opset_import[0].version = 13
    m = onnx.shape_inference.infer_shapes(m)
    onnx.checker.check_model(m)
    onnx.save(m, dst)


def convert_yunet(fused: Path, dst: Path) -> None:
    import coremltools as ct
    import onnx
    import onnxruntime as ort
    import torch
    from onnx2torch import convert

    torch.set_num_threads(2)
    model = convert(onnx.load(fused)).eval()
    x = torch.randint(0, 255, (1, 3, DET_H, DET_W)).to(torch.float32)
    with torch.no_grad():
        t_out = model(x).numpy()
        traced = torch.jit.trace(model, x)
    o_out = ort.InferenceSession(str(fused), providers=["CPUExecutionProvider"]).run(None, {"image": x.numpy()})[0]
    print("YuNet torch vs onnx max abs diff", float(np.abs(t_out - o_out).max()))
    mlm = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=(1, 3, DET_H, DET_W), color_layout=ct.colorlayout.BGR)],
                     outputs=[ct.TensorType(name="dets", dtype=np.float32)], convert_to="mlprogram",
                     compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14)
    mlm.short_description = "YuNet 2023mar, 320x240 BGR image, decode in graph, boxes in 640x480 pixels"
    mlm.license = LOCK["yunet"]["license"]
    mlm.version = LOCK["yunet"]["sha256"][:12]
    mlm.save(str(dst))


def convert_arcface(src: Path, dst: Path) -> None:
    import coremltools as ct
    import onnx
    import onnxruntime as ort
    import torch
    from onnx2torch import convert

    torch.set_num_threads(4)
    net = convert(onnx.load(src)).eval()
    x = torch.rand(1, 3, 112, 112) * 2 - 1
    with torch.no_grad():
        traced = torch.jit.trace(net, x)
        t_out = traced(x).numpy().ravel()
    sess = ort.InferenceSession(str(src), providers=["CPUExecutionProvider"])
    o_out = sess.run(None, {sess.get_inputs()[0].name: x.numpy()})[0].ravel()
    print("ArcFace torch vs onnx cosine", float(t_out @ o_out / np.linalg.norm(t_out) / np.linalg.norm(o_out)))
    mlm = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=(1, 3, 112, 112), scale=1 / 127.5, bias=[-1.0, -1.0, -1.0],
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram", compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS14,
    )
    mlm.short_description = f"ArcFace w600k_r50 (InsightFace buffalo_l) converted with coremltools {ct.__version__}"
    mlm.license = LOCK["w600k_r50"]["license"]
    mlm.version = LOCK["w600k_r50"]["sha256"][:12]
    mlm.save(str(dst))


BLOB_HEADER = 64
BLOB_DTYPES = {1: 2, 2: 4}  # MIL blob dtype: 1 fp16, 2 fp32 -> bytes per element


def fp16_keep_nonzero(a: np.ndarray) -> np.ndarray:
    """coremltools' cast for some tensors: a nonzero value that rounds to 0 keeps its sign as the smallest subnormal."""
    h = a.astype(np.float16)
    under = (h == 0) & (a != 0)
    h[under] = np.copysign(np.float16(2 ** -24), a[under]).astype(np.float16)
    return h


def write_layout(pkg: Path, onnx_path: Path, dst: Path) -> None:
    """Maps every blob in weight.bin to the ONNX initializer it came from, and checks that replaying
    the map reproduces weight.bin byte for byte, so the app can rebuild it from the ONNX file alone."""
    import struct

    import onnx
    from onnx import numpy_helper

    weights = (pkg / "Data/com.apple.CoreML/weights/weight.bin").read_bytes()
    count, version = struct.unpack("<II", weights[:8])
    if version != 2 or weights[8:BLOB_HEADER] != bytes(BLOB_HEADER - 8):
        sys.exit("weight.bin: unexpected blob storage header")
    inits = {i.name: numpy_helper.to_array(i).astype(np.float32).ravel() for i in onnx.load(onnx_path).graph.initializer}
    casts = {"f16": lambda a: a.astype(np.float16).tobytes(), "f16nz": lambda a: fp16_keep_nonzero(a).tobytes(),
             "f32": lambda a: a.tobytes()}
    index: dict[bytes, list[tuple[str, str]]] = {}
    for name, a in inits.items():
        for cast, f in casts.items():
            index.setdefault(f(a), []).append((name, cast))
    blobs, pos, used = [], BLOB_HEADER, set()
    for _ in range(count):
        sentinel, dtype, size, data = struct.unpack("<IIQQ", weights[pos:pos + 24])
        if sentinel != 0xDEADBEEF or data != pos + BLOB_HEADER or weights[pos + 24:data] != bytes(BLOB_HEADER - 24):
            sys.exit(f"weight.bin: unexpected blob metadata at {pos}")
        hits = {n for n, c in index.get(weights[data:data + size], []) if BLOB_DTYPES[dtype] == (4 if c == "f32" else 2)}
        if len(hits) != 1:
            sys.exit(f"weight.bin: blob at {pos} matches {len(hits)} initializers")
        name = hits.pop()
        cast = next(c for n, c in index[weights[data:data + size]] if n == name and BLOB_DTYPES[dtype] == (4 if c == "f32" else 2))
        blobs.append({"offset": pos, "dtype": dtype, "initializer": name, "cast": cast, "count": size // BLOB_DTYPES[dtype]})
        used.add(name)
        pos = -(-(data + size) // BLOB_HEADER) * BLOB_HEADER
    if pos != len(weights) or used != set(inits):
        sys.exit("weight.bin: blobs do not cover the file or every initializer exactly once")
    replay = bytearray(len(weights))
    replay[:8] = struct.pack("<II", count, version)
    for b in blobs:
        data = casts[b["cast"]](inits[b["initializer"]])
        replay[b["offset"]:b["offset"] + 24] = struct.pack("<IIQQ", 0xDEADBEEF, b["dtype"], len(data), b["offset"] + BLOB_HEADER)
        replay[b["offset"] + BLOB_HEADER:b["offset"] + BLOB_HEADER + len(data)] = data
    if bytes(replay) != weights:
        sys.exit("weight.bin: replaying the layout does not reproduce the file")
    r50, archive = LOCK["w600k_r50"], LOCK[LOCK["w600k_r50"]["archive"]]
    layout = {
        "about": "Where each w600k_r50.onnx initializer goes in ArcFaceR50.mlmodelc/weights/weight.bin. No weights.",
        "source": {"url": archive["url"], "archive_sha256": archive["sha256"], "archive_bytes": archive["bytes"],
                   "member": r50["member"], "sha256": r50["sha256"], "bytes": r50["bytes"], "license": r50["license"]},
        "weights": {"bytes": len(weights), "sha256": hashlib.sha256(weights).hexdigest(), "version": version},
        "blobs": blobs,
    }
    dst.write_text(json.dumps(layout, indent=1) + "\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="local", type=Path)
    ap.add_argument("--out", type=Path, default=TOOLS.parent / "models")
    ap.add_argument("--no-compile", action="store_true")
    ap.add_argument("--layout-only", action="store_true", help="only rewrite Resources/ArcFaceR50.layout.json from models/")
    args = ap.parse_args()
    out: Path = args.out
    cache = out / "upstream"
    cache.mkdir(parents=True, exist_ok=True)
    layout = TOOLS.parent / "Resources/ArcFaceR50.layout.json"
    if args.layout_only:
        write_layout(out / "ArcFaceR50.mlpackage", r50_onnx(cache, args.local), layout)
        print("wrote", layout)
        return

    yunet_src = fetch(LOCK["yunet"], cache, args.local)
    fused = cache / f"yunet_{DET_W}x{DET_H}_decode.onnx"
    yunet_with_decode(yunet_src, fused)
    targets = {"YuNet320x240": lambda d: convert_yunet(fused, d),
               "ArcFaceR50": lambda d: convert_arcface(r50_onnx(cache, args.local), d)}
    for name, build in targets.items():
        pkg = out / f"{name}.mlpackage"
        build(pkg)
        print("saved", pkg)
        if name == "ArcFaceR50":
            write_layout(pkg, r50_onnx(cache, args.local), layout)
            print("wrote", layout)
        if not args.no_compile:
            subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(out)], check=True, stdout=subprocess.DEVNULL)
            print("compiled", out / f"{name}.mlmodelc")


if __name__ == "__main__":
    main()
