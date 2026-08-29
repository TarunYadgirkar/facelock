import time

import pytest

from facelock import control


@pytest.mark.parametrize(
    "text,expected",
    [("30", 1800.0), ("45s", 45.0), ("15m", 900.0), ("2h", 7200.0), ("forever", control.FOREVER)],
)
def test_parse_duration(text, expected):
    assert control.parse_duration(text) == expected


def test_parse_duration_rejects_junk():
    with pytest.raises(ValueError):
        control.parse_duration("soon")


def test_pause_and_resume(tmp_path):
    path = tmp_path / "pause"
    control.pause(60, path)
    assert control.is_paused(path)
    assert control.resume(path)
    assert not control.is_paused(path)
    assert not control.resume(path)


def test_expired_pause_clears_itself(tmp_path):
    path = tmp_path / "pause"
    path.write_text(str(time.time() - 1))
    assert not control.is_paused(path)
    assert not path.exists()


def test_indefinite_pause(tmp_path):
    path = tmp_path / "pause"
    assert control.pause(control.FOREVER, path) is None
    assert control.pause_expiry(path) == control.FOREVER


def test_corrupt_pause_file_is_ignored(tmp_path):
    path = tmp_path / "pause"
    path.write_text("garbage")
    assert not control.is_paused(path)


def test_pid_file_tracks_this_process(tmp_path):
    path = tmp_path / "pid"
    assert control.running_pid(path) is None
    control.write_pid(path)
    assert control.running_pid(path) is not None
    control.clear_pid(path)
    assert control.running_pid(path) is None


def test_stale_pid_file_is_discarded(tmp_path):
    path = tmp_path / "pid"
    path.write_text("999999")
    assert control.running_pid(path) is None
    assert not path.exists()
