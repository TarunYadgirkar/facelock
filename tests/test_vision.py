import numpy as np

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
    assert embeddings.shape == (0, 128)


def test_embeddings_are_unit_length():
    engine = vision.FaceEngine(config.Config())
    frame = (np.random.default_rng(0).random((480, 640, 3)) * 255).astype(np.uint8)
    face = np.array([100, 100, 120, 120] + [150, 140, 200, 140, 175, 175, 155, 205, 195, 205]
                    + [0.99], dtype=np.float32)
    embeddings = engine.embed(frame, np.array([face]))
    assert np.allclose(np.linalg.norm(embeddings, axis=1), 1.0, atol=1e-5)
