import numpy as np
import pytest

from facelock import identity


def unit(seed, dim=identity.embedding_dim("arcface")):
    rng = np.random.default_rng(seed)
    vec = rng.normal(size=dim).astype(np.float32)
    return vec / np.linalg.norm(vec)


def test_best_match_reports_score_and_profile():
    mine = np.array([unit(1), unit(1), unit(1)])
    enrollment = identity.Enrollment({"me": mine})
    match = enrollment.best(np.array([mine[1]]))
    assert match.profile == "me"
    assert match.score == pytest.approx(1.0, abs=1e-5)


def test_one_identical_view_among_unrelated_ones_is_not_a_full_match():
    """Scores average the closest few views, so a single lucky template cannot carry a stranger."""
    enrollment = identity.Enrollment({"me": np.array([unit(1), unit(2), unit(3)])})
    assert enrollment.best(np.array([unit(1)])).score == pytest.approx(1 / 3, abs=0.05)


def test_best_match_picks_the_owning_profile():
    enrollment = identity.Enrollment({"me": np.array([unit(1)]), "glasses": np.array([unit(9)])})
    assert enrollment.best(np.array([unit(9)])).profile == "glasses"


def test_no_faces_and_no_enrollment_score_zero():
    enrollment = identity.Enrollment({"me": np.array([unit(1)])})
    assert enrollment.best(np.empty((0, identity.embedding_dim("arcface")))) is identity.NO_MATCH
    assert identity.Enrollment({}).best(np.array([unit(1)])) is identity.NO_MATCH


def test_stranger_scores_below_threshold():
    enrollment = identity.Enrollment({"me": np.array([unit(1), unit(2)])})
    assert not enrollment.best(np.array([unit(77)])).accepted(0.363)


def test_append_and_remove_profiles():
    base = identity.Enrollment({"me": np.array([unit(1)])})
    grown = base.with_profile("me", np.array([unit(2)]), append=True)
    assert grown.profiles == {"me": 2}
    assert base.profiles == {"me": 1}  # original untouched
    assert grown.with_profile("me", np.array([unit(3)])).profiles == {"me": 1}
    assert grown.without_profile("me").profiles == {}


def test_round_trip_through_disk(tmp_path):
    path = tmp_path / "enrollment.npz"
    identity.Enrollment({"me": np.array([unit(1), unit(2)])}).save(path)
    assert identity.load(path).profiles == {"me": 2}
    assert path.stat().st_mode & 0o777 == 0o600


def test_require_refuses_an_empty_enrollment(tmp_path):
    with pytest.raises(SystemExit):
        identity.require(tmp_path / "missing.npz")


def test_malformed_samples_rejected():
    with pytest.raises(ValueError):
        identity.Enrollment({"me": np.zeros((2, 5), dtype=np.float32)})


def test_live_enrollment_picks_up_samples_added_while_watching(tmp_path):
    path = tmp_path / "enrollment.npz"
    identity.Enrollment({"me": np.array([unit(1)])}).save(path)
    live = identity.Live(path)
    taught = unit(2)
    assert live.best(np.array([taught])).score < 0.1

    identity.load(path).with_profile("me", np.array([taught]), append=True).save(path)
    assert live.best(np.array([taught])).score > 0.45  # now one of its two known views


@pytest.mark.parametrize("value", [0.0, float("nan"), float("inf")])
def test_invalid_embedding_values_rejected(value):
    with pytest.raises(ValueError):
        identity.Enrollment({"me": np.full((1, 512), value, dtype=np.float32)})


def test_enrollment_normalizes_and_owns_its_input():
    samples = np.array([unit(1) * 3])
    enrolled = identity.Enrollment({"me": samples})
    samples[:] = 0
    assert enrolled.best(np.array([unit(1)])).score == pytest.approx(1, abs=1e-5)


def test_failed_atomic_save_preserves_previous_enrollment(tmp_path, monkeypatch):
    path = tmp_path / "enrollment.npz"
    original = identity.Enrollment({"me": np.array([unit(1)])})
    original.save(path)
    before = path.read_bytes()

    def fail(target, **kwargs):
        if hasattr(target, "write"):
            target.write(b"partial archive")
        else:
            target.write_bytes(b"partial archive")
        raise OSError("disk full")

    monkeypatch.setattr(np, "savez_compressed", fail)
    with pytest.raises(OSError):
        original.with_profile("new", np.array([unit(2)])).save(path)
    assert path.read_bytes() == before
    assert list(tmp_path.iterdir()) == [path]


def test_calibrated_threshold_round_trips_with_enrollment(tmp_path):
    path = tmp_path / "e.npz"
    identity.Enrollment({"me": np.array([unit(1)])}, threshold=0.48).save(path)
    assert identity.load(path).threshold == 0.48


def test_deleted_enrollment_retains_last_good_cache_and_threshold(tmp_path):
    path = tmp_path / "e.npz"
    identity.Enrollment({"me": np.array([unit(1)])}, threshold=.48).save(path)
    live = identity.Live(path)
    path.unlink()
    assert live.best(np.array([unit(1)])).score > .9
    assert live.threshold == .48
    assert "enrollment" in live.error
    assert not path.exists()


def test_corrupt_live_replacement_retained_then_recovered(tmp_path):
    path = tmp_path / "e.npz"
    identity.Enrollment({"me": np.array([unit(1)])}, threshold=.48).save(path)
    live = identity.Live(path)
    path.write_bytes(b"broken archive")
    assert live.best(np.array([unit(1)])).score > .9
    assert live.threshold == .48
    assert live.error
    assert path.read_bytes() == b"broken archive"
    identity.Enrollment({"me": np.array([unit(2)])}, threshold=.49).save(path)
    assert live.best(np.array([unit(2)])).score > .9
    assert live.threshold == .49
    assert live.error is None


def test_empty_live_replacement_revokes_enrollment(tmp_path):
    path = tmp_path / "e.npz"
    identity.Enrollment({"me": np.array([unit(1)])}).save(path)
    live = identity.Live(path)
    identity.Enrollment({}).save(path)
    assert live.best(np.array([unit(1)])) == identity.NO_MATCH
    assert len(live) == 0
    assert live.error is None


def test_live_retries_failed_replacement_without_timestamp_change(tmp_path, monkeypatch):
    path = tmp_path / "e.npz"
    identity.Enrollment({"me": np.array([unit(1)])}).save(path)
    live = identity.Live(path)
    identity.Enrollment({"me": np.array([unit(2)])}).save(path)
    original_load = identity.load

    def unavailable(*args, **kwargs):
        raise PermissionError("temporarily unavailable")

    monkeypatch.setattr(identity, "load", unavailable)
    assert live.best(np.array([unit(1)])).score > .9
    assert live.error
    monkeypatch.setattr(identity, "load", original_load)
    assert live.best(np.array([unit(2)])).score > .9
    assert live.error is None


def test_live_does_not_hide_programming_errors(tmp_path, monkeypatch):
    path = tmp_path / "e.npz"
    identity.Enrollment({"me": np.array([unit(1)])}).save(path)
    live = identity.Live(path)
    identity.Enrollment({"me": np.array([unit(2)])}).save(path)

    def bug(*args, **kwargs):
        raise RuntimeError("implementation bug")

    monkeypatch.setattr(identity, "load", bug)
    with pytest.raises(RuntimeError, match="implementation bug"):
        live.refresh()


def test_live_keeps_owner_when_threshold_metadata_is_malformed(tmp_path):
    path = tmp_path / "e.npz"
    identity.Enrollment({"me": np.array([unit(1)])}, threshold=.48).save(path)
    live = identity.Live(path)
    np.savez(path, me=np.array([unit(2)]), __recognizer__="arcface",
             __threshold__=np.array([.4, .5]))
    assert live.best(np.array([unit(1)])).score > .9
    assert live.threshold == .48
    assert live.error
