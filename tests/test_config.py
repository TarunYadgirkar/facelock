import pytest

from facelock import config


def test_settings_round_trip_through_the_file(tmp_path):
    path = tmp_path / "config.toml"
    written = config.Config(**config.PRESETS["Relaxed"], sound=False, lock_method="sleep")
    config.write(written, path)
    assert config.load(path) == written


def test_preset_of_names_a_matching_cadence():
    assert config.preset_of(config.Config(**config.PRESETS["Strict"])) == "Strict"
    assert config.preset_of(config.Config(interval=7.0)) is None


def test_grace_counts_the_escalating_rechecks_after_the_first_miss():
    cfg = config.Config(interval=45.0, recheck_interval=20.0, recheck_decay=0.5, confirm_checks=3)
    assert config.grace_seconds(cfg) == 45.0 + 20.0 + 10.0


def test_write_refuses_an_invalid_config(tmp_path):
    with pytest.raises(ValueError):
        config.write(config.Config(lock_method="explode"), tmp_path / "config.toml")


@pytest.mark.parametrize("changes", [
    {"interval": float("nan")}, {"interval": float("inf")},
    {"frames_per_check": 1.5}, {"notify": "false"}, {"camera": -1},
    {"frame_width": 0}, {"detect_score": 2.0},
])
def test_invalid_runtime_values_rejected(changes):
    with pytest.raises(ValueError):
        config.Config(**changes).validate()


def test_failed_config_replacement_keeps_previous_file(tmp_path, monkeypatch):
    path = tmp_path / "config.toml"
    config.write(config.Config(), path)
    before = path.read_bytes()
    import os
    def fail(*args):
        raise OSError("disk full")
    monkeypatch.setattr(os, "replace", fail)
    with pytest.raises(OSError):
        config.write(config.Config(interval=15), path)
    assert path.read_bytes() == before
