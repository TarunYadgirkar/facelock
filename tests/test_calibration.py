import numpy as np
import pytest

from facelock import config, identity


def unit(seed, dim=512):
    rng = np.random.default_rng(seed)
    vec = rng.normal(size=dim).astype(np.float32)
    return vec / np.linalg.norm(vec)


def near(base, seed, wobble=0.15):
    vec = base + wobble * unit(seed)
    return vec / np.linalg.norm(vec)


ME = unit(1)
VIEWS = np.array([near(ME, s) for s in range(10, 20)])


def test_score_averages_the_closest_views_not_the_single_best():
    enrollment = identity.Enrollment({"me": VIEWS})
    lucky = np.array([VIEWS[0]])  # identical to exactly one enrolled view
    score = enrollment.scores(lucky)[0]
    assert score < 1.0  # max alone would say 1.0
    assert score > 0.9


def test_a_stranger_scores_far_below_me():
    enrollment = identity.Enrollment({"me": VIEWS})
    mine = enrollment.best(np.array([near(ME, 99)])).score
    stranger = enrollment.best(np.array([unit(2)])).score
    assert mine > 0.9
    assert stranger < 0.2


def test_recognizer_tag_round_trips_and_untagged_files_are_sface(tmp_path):
    path = tmp_path / "e.npz"
    identity.Enrollment({"me": VIEWS}).save(path)
    assert identity.load(path).recognizer == "arcface"

    np.savez(tmp_path / "old.npz", me=np.array([unit(1, 128)]))
    legacy = identity.load(tmp_path / "old.npz")
    assert legacy.recognizer == "sface"
    assert legacy.profiles == {"me": 1}


def test_dimension_must_match_the_recognizer():
    with pytest.raises(ValueError):
        identity.Enrollment({"me": np.array([unit(1, 128)])}, "arcface")
    with pytest.raises(ValueError):
        identity.Enrollment({"me": VIEWS}, "nope")


def test_calibrate_sits_above_the_strongest_stranger_with_a_margin():
    enrollment = identity.Enrollment({"me": VIEWS})
    bank = np.array([unit(s) for s in range(200, 260)])
    bank[0] = near(ME, 7, wobble=3.0)  # one faint look-alike
    calibration = identity.calibrate(enrollment, bank)
    assert calibration.threshold == pytest.approx(
        min(identity.CALIBRATION_CEILING,
            max(0.42, calibration.stranger_max + identity.CALIBRATION_MARGIN)), abs=1e-3)
    assert calibration.own_p05 > calibration.threshold
    assert calibration.bank_size == 60


def test_calibrate_never_drops_below_the_default_nor_above_the_ceiling():
    enrollment = identity.Enrollment({"me": VIEWS})
    far = np.array([-ME])  # a bank that scores nothing
    assert identity.calibrate(enrollment, far).threshold == config.default_threshold()
    close = np.array([near(ME, 5)])  # a bank that is basically me
    assert identity.calibrate(enrollment, close).threshold == identity.CALIBRATION_CEILING


def test_calibrate_against_the_shipped_bank_rejects_random_strangers():
    enrollment = identity.Enrollment({"me": VIEWS})
    calibration = identity.calibrate(enrollment)
    assert calibration.bank_size >= 1000
    assert calibration.stranger_max < calibration.threshold


def test_live_reports_the_recognizer_of_whatever_is_on_disk(tmp_path):
    path = tmp_path / "e.npz"
    np.savez(path, me=np.array([unit(1, 128)]))
    live = identity.Live(path)
    assert live.recognizer == "sface"
    identity.Enrollment({"me": VIEWS}).save(path)
    assert live.recognizer == "arcface"


def test_stay_awake_round_trips_through_config(tmp_path):
    path = tmp_path / "config.toml"
    config.write(config.Config(stay_awake=False), path)
    assert config.load(path).stay_awake is False
