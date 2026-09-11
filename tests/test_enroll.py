import numpy as np
import pytest

from facelock import config, enroll, identity, vision


def unit(seed):
    x = np.random.default_rng(seed).normal(size=512).astype(np.float32)
    return x / np.linalg.norm(x)


def views(seed):
    return np.array([(unit(seed) + .1 * unit(i)) for i in range(20, 30)])


def test_lesson_rejects_another_identity_without_changing_owner():
    owner = identity.Enrollment({"me": views(1)})
    with pytest.raises(ValueError, match="owner"):
        enroll.prepare(owner, views(2), threshold=.42)
    assert owner.profiles == {"me": 10}


def test_lesson_retains_owner_and_stores_calibration():
    owner = identity.Enrollment({"me": views(1)})
    result, calibration = enroll.prepare(owner, views(1), threshold=.42)
    assert len(result) == 20
    assert result.threshold == calibration.threshold


def test_failed_start_over_does_not_replace_good_enrollment():
    owner = identity.Enrollment({"me": views(1)})
    with pytest.raises(ValueError, match="samples"):
        enroll.prepare(owner, views(2)[:2], replace_all=True)
    assert owner.best(np.array([unit(1)])).score > .9


def test_named_profile_replacement_preserves_other_profiles():
    owner = identity.Enrollment({"me": views(1), "glasses": views(1)})
    result, _ = enroll.prepare(owner, views(1), profile="glasses", append=False)
    assert result.profiles == {"me": 10, "glasses": 10}


def test_capture_filters_other_faces_before_collecting(monkeypatch):
    owner = identity.Enrollment({"me": views(1)})
    script = [unit(2), unit(1), unit(1), unit(1)]

    class Camera:
        def __init__(self, cfg):
            pass
        def __enter__(self):
            return self
        def __exit__(self, *args):
            pass
        def read(self):
            return np.zeros((2, 2, 3))

    class Engine:
        def __init__(self, *args):
            pass
        def faces_and_embeddings(self, frame):
            return 1, np.array([script.pop(0)])

    monkeypatch.setattr(vision, "Camera", Camera)
    monkeypatch.setattr(vision, "FaceEngine", Engine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(enroll.time, "sleep", lambda seconds: None)
    samples = enroll.capture(config.Config(), 3, lambda text: None, minimum=3,
                              poses=enroll.LEARN_POSES, reference=owner)
    assert len(script) == 0
    assert (owner.scores(samples) > .9).all()


def test_cancelled_capture_returns_without_opening_camera(monkeypatch):
    def unexpected(*args, **kwargs):
        raise AssertionError("camera/model opened after cancellation")
    monkeypatch.setattr(vision, "FaceEngine", unexpected)
    with pytest.raises(ValueError, match="cancelled"):
        enroll.capture(config.Config(), 25, print, should_stop=lambda: True)


@pytest.mark.parametrize("replace_all", [False, True])
def test_initial_enrollment_rejects_two_consistent_identity_clusters(replace_all):
    current = identity.Enrollment({"me": views(3)} if replace_all else {})
    mixed = np.vstack([views(1), views(2)])
    with pytest.raises(ValueError, match="consistent"):
        enroll.prepare(current, mixed, replace_all=replace_all)
    assert current.profiles == ({"me": 10} if replace_all else {})


def test_capture_anchors_initial_samples_to_first_face(monkeypatch):
    script = [unit(1) * 3, unit(2), unit(1), unit(1)]

    class Camera:
        def __init__(self, cfg):
            pass
        def __enter__(self):
            return self
        def __exit__(self, *args):
            pass
        def read(self):
            return np.zeros((2, 2, 3))

    class Engine:
        def __init__(self, *args):
            pass
        def faces_and_embeddings(self, frame):
            return 1, np.array([script.pop(0)])

    monkeypatch.setattr(vision, "Camera", Camera)
    monkeypatch.setattr(vision, "FaceEngine", Engine)
    monkeypatch.setattr(vision, "warmup", lambda camera: None)
    monkeypatch.setattr(enroll.time, "sleep", lambda seconds: None)
    samples = enroll.capture(config.Config(), 3, lambda text: None, minimum=3,
                             poses=enroll.LEARN_POSES)
    assert len(script) == 0
    assert (identity.Enrollment({"me": views(1)}).scores(samples) > .9).all()
