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
