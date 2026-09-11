import numpy as np
import pytest
from types import SimpleNamespace

from facelock import config, vision


class StubDetector:
    """Stands in for YuNet so the scaling maths can be checked without a real face."""

    def __init__(self, row):
        self.row = row
        self.size = None

    def setInputSize(self, size):
        self.size = size

    def detect(self, image):
        return 1, self.row.copy()


def test_detector_scales_coordinates_back_to_full_frame():
    cfg = config.Config(detect_width=320)
    engine = vision.FaceEngine(cfg)
    frame = np.zeros((480, 640, 3), dtype=np.uint8)
    row = np.array([[10, 20, 30, 40] + [5] * 10 + [0.99]], dtype=np.float32)
    stub = StubDetector(row)
    engine._detector = stub
    faces = engine.detect(frame)
    assert stub.size == (320, 240)
    assert faces[0][0] == 20  # 0.5 scale doubles the coordinate
    assert faces[0][14] == np.float32(0.99)  # score untouched


def test_no_faces_in_a_blank_frame():
    engine = vision.FaceEngine(config.Config())
    count, embeddings = engine.faces_and_embeddings(np.zeros((480, 640, 3), dtype=np.uint8))
    assert count == 0
    assert embeddings.shape == (0, 512)


def test_embeddings_are_unit_length():
    engine = vision.FaceEngine(config.Config())
    frame = (np.random.default_rng(0).random((480, 640, 3)) * 255).astype(np.uint8)
    face = np.array([100, 100, 120, 120] + [150, 140, 200, 140, 175, 175, 155, 205, 195, 205]
                    + [0.99], dtype=np.float32)
    embeddings = engine.embed(frame, np.array([face]))
    assert np.allclose(np.linalg.norm(embeddings, axis=1), 1.0, atol=1e-5)


def test_models_download_only_when_missing(tmp_path, monkeypatch):
    """First run fetches; later runs must not touch the network."""
    source = tmp_path / "zoo"
    source.mkdir()
    (source / "model.onnx").write_bytes(b"weights")
    monkeypatch.setattr(config, "MODELS_DIR", tmp_path / "models")
    monkeypatch.setattr(config, "MODELS", {"model.onnx": ((source / "model.onnx").as_uri(), None)})

    fetched = []
    vision.ensure_models(fetched.append)
    assert (tmp_path / "models" / "model.onnx").read_bytes() == b"weights"
    assert len(fetched) == 1

    vision.ensure_models(fetched.append)
    assert len(fetched) == 1  # already there, nothing downloaded


def test_a_model_inside_a_zip_is_extracted(tmp_path, monkeypatch):
    import zipfile

    archive = tmp_path / "pack.zip"
    with zipfile.ZipFile(archive, "w") as pack:
        pack.writestr("inner.onnx", b"weights")
        pack.writestr("other.onnx", b"noise")
    monkeypatch.setattr(config, "MODELS_DIR", tmp_path / "models")
    monkeypatch.setattr(config, "MODELS", {"inner.onnx": (archive.as_uri(), "inner.onnx")})
    vision.ensure_models(lambda _: None)
    assert (tmp_path / "models" / "inner.onnx").read_bytes() == b"weights"
    assert sorted(p.name for p in (tmp_path / "models").iterdir()) == ["inner.onnx"]


def test_a_failed_download_leaves_nothing_behind(tmp_path, monkeypatch):
    monkeypatch.setattr(config, "MODELS_DIR", tmp_path / "models")
    monkeypatch.setattr(config, "MODELS", {"model.onnx": ((tmp_path / "missing").as_uri(), None)})
    with pytest.raises(SystemExit):
        vision.ensure_models(lambda _: None)
    assert list((tmp_path / "models").iterdir()) == []


def test_legacy_sface_engine_still_embeds():
    engine = vision.FaceEngine(config.Config(), "sface")
    count, embeddings = engine.faces_and_embeddings(np.zeros((480, 640, 3), dtype=np.uint8))
    assert (count, embeddings.shape) == (0, (0, 128))


def test_camera_open_failure_is_recoverable(monkeypatch):
    class ClosedCapture:
        def set(self, *_args):
            pass

        def isOpened(self):
            return False

        def release(self):
            pass

    monkeypatch.setattr(vision.cv2, "VideoCapture", lambda *_args: ClosedCapture())
    with pytest.raises(vision.CameraError):
        vision.Camera(config.Config()).open()


def test_silence_opencv_logs_uses_top_level_api(monkeypatch):
    calls = []
    monkeypatch.setattr(vision.cv2, "setLogLevel", calls.append, raising=False)
    monkeypatch.setattr(vision.cv2, "utils", SimpleNamespace(), raising=False)
    monkeypatch.setattr(vision.sys.stdout, "isatty", lambda: True)
    vision.silence_opencv_logs()
    assert calls == [2]


def test_silence_opencv_logs_uses_legacy_api(monkeypatch):
    calls = []
    logging = SimpleNamespace(LOG_LEVEL_ERROR=2, LOG_LEVEL_SILENT=0, setLogLevel=calls.append)
    monkeypatch.delattr(vision.cv2, "setLogLevel", raising=False)
    monkeypatch.setattr(vision.cv2, "utils", SimpleNamespace(logging=logging), raising=False)
    monkeypatch.setattr(vision.sys.stdout, "isatty", lambda: False)
    vision.silence_opencv_logs()
    assert calls == [2, 0]
