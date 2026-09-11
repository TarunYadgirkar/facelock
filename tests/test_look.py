import numpy as np

from facelock.identity import Enrollment, embedding_dim

EMBEDDING_DIM = embedding_dim("arcface")
from facelock.watcher import look


class FakeCamera:
    def __init__(self, frames):
        self.frames = list(frames)

    def read(self):
        return self.frames.pop(0) if self.frames else None


class FakeEngine:
    """Returns a canned (face_count, embeddings) per frame, keyed by the frame's first pixel."""

    def __init__(self, script):
        self.script = script

    def faces_and_embeddings(self, frame):
        return self.script[int(frame[0][0][0])]


def unit(seed):
    rng = np.random.default_rng(seed)
    vec = rng.normal(size=EMBEDDING_DIM).astype(np.float32)
    return (vec / np.linalg.norm(vec)).reshape(1, EMBEDDING_DIM)


def frame(tag):
    return np.full((1, 1, 3), tag, dtype=np.uint8)


MINE = unit(1)
EMPTY = np.empty((0, EMBEDDING_DIM), dtype=np.float32)


def test_two_supporting_frames_tolerate_one_bad_frame():
    """One bad frame in three - a blink, a turn - must not read as absence."""
    engine = FakeEngine({0: (0, EMPTY), 1: (1, MINE)})
    reading = look(FakeCamera([frame(1), frame(0), frame(1)]), engine,
                   Enrollment({"me": MINE}), frames=3)
    assert reading.match.score > 0.99
    assert reading.face_count == 1


def test_one_lucky_face_in_a_burst_is_rejected():
    engine = FakeEngine({0: (0, EMPTY), 1: (1, MINE)})
    reading = look(FakeCamera([frame(0), frame(1), frame(0)]), engine,
                   Enrollment({"me": MINE}), frames=3)
    assert not reading.match.accepted(0.363)


def test_one_frame_check_uses_its_only_match():
    engine = FakeEngine({1: (1, MINE)})
    reading = look(FakeCamera([frame(1)]), engine, Enrollment({"me": MINE}), frames=1)
    assert reading.match.accepted(0.363)


def test_a_dead_camera_reads_as_no_reading():
    engine = FakeEngine({0: (0, EMPTY)})
    assert look(FakeCamera([frame(0)]), engine, Enrollment({"me": MINE}), frames=3) is None


def test_face_count_is_the_busiest_frame():
    engine = FakeEngine({0: (0, EMPTY), 2: (2, unit(9))})
    reading = look(FakeCamera([frame(0), frame(2)]), engine, Enrollment({"me": MINE}), frames=2)
    assert reading.face_count == 2
    assert not reading.match.accepted(0.363)
