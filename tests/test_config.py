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


def test_grace_counts_the_rechecks_after_the_first_miss():
    cfg = config.Config(interval=45.0, recheck_interval=20.0, confirm_checks=3)
    assert config.grace_seconds(cfg) == 85.0


def test_write_refuses_an_invalid_config(tmp_path):
    with pytest.raises(ValueError):
        config.write(config.Config(lock_method="explode"), tmp_path / "config.toml")
