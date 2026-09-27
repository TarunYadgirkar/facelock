import time
import os
import signal
import subprocess

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


def test_expired_pause_is_ignored_without_deleting_file(tmp_path):
    path = tmp_path / "pause"
    path.write_text(str(time.time() - 1))
    assert not control.is_paused(path)
    assert path.exists()


def test_indefinite_pause(tmp_path):
    path = tmp_path / "pause"
    assert control.pause(control.FOREVER, path) is None
    assert control.pause_expiry(path) == control.FOREVER


def test_corrupt_pause_file_is_ignored(tmp_path):
    path = tmp_path / "pause"
    path.write_text("garbage")
    assert not control.is_paused(path)
    assert path.exists()


@pytest.mark.parametrize("raw", ["nan", "inf", "-inf"])
def test_nonfinite_pause_file_is_ignored(tmp_path, raw):
    path = tmp_path / "pause"
    path.write_text(raw)
    assert control.pause_expiry(path) is None
    assert path.exists()


@pytest.mark.parametrize("seconds", [0, -1, float("nan"), -float("inf")])
def test_pause_rejects_invalid_duration(tmp_path, seconds):
    path = tmp_path / "pause"
    with pytest.raises(ValueError):
        control.pause(seconds, path)
    assert not path.exists()


def test_pause_replaces_file_atomically_with_private_permissions(tmp_path, monkeypatch):
    path = tmp_path / "pause"
    path.write_text("forever")
    original_replace = os.replace

    def check_replace(source, destination):
        assert path.read_text() == "forever"
        assert os.stat(source).st_mode & 0o777 == 0o600
        original_replace(source, destination)

    monkeypatch.setattr(control.os, "replace", check_replace)
    control.pause(60, path)
    assert control.pause_expiry(path) != control.FOREVER
    assert path.stat().st_mode & 0o777 == 0o600


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


@pytest.mark.parametrize("raw", ["0", "-1", str(2 ** 63)])
def test_invalid_pid_is_never_signalled(tmp_path, monkeypatch, raw):
    path = tmp_path / "pid"
    path.write_text(raw)
    signals = []
    monkeypatch.setattr(control.os, "kill", lambda pid, sig: signals.append((pid, sig)))
    assert control.running_pid(path) is None
    assert control.stop_running(path) is None
    assert signals == []


def test_stop_refuses_unrelated_live_process(tmp_path, monkeypatch):
    path = tmp_path / "pid"
    path.write_text("12345")
    signals = []
    monkeypatch.setattr(control.os, "kill", lambda pid, sig: signals.append((pid, sig)))
    monkeypatch.setattr(subprocess, "run", lambda *_args, **_kwargs: type(
        "Result", (), {"returncode": 0, "stdout": "/usr/bin/python -m unrelated watch\n"})())
    assert control.stop_running(path) is None
    assert signals == [(12345, 0)]


@pytest.mark.parametrize("command", [
    "/usr/bin/python -c print -m facelock watch",
    "/usr/bin/python -m unrelated -m facelock watch",
    "/some/venv/bin/facelock --unknown 1 watch",
    "/some/venv/bin/facelock --camera watch",
])
def test_stop_rejects_ambiguous_command(tmp_path, monkeypatch, command):
    path = tmp_path / "pid"
    path.write_text("12345")
    signals = []
    monkeypatch.setattr(control.os, "kill", lambda pid, sig: signals.append((pid, sig)))
    monkeypatch.setattr(subprocess, "run", lambda *_args, **_kwargs: type(
        "Result", (), {"returncode": 0, "stdout": command + "\n"})())
    assert control.stop_running(path) is None
    assert signals == [(12345, 0)]


def test_stop_refuses_ps_timeout(tmp_path, monkeypatch):
    path = tmp_path / "pid"
    path.write_text("12345")
    signals = []
    monkeypatch.setattr(control.os, "kill", lambda pid, sig: signals.append((pid, sig)))

    def timed_out(_args, **kwargs):
        assert kwargs["timeout"] == 2
        raise subprocess.TimeoutExpired("ps", 2)

    monkeypatch.setattr(subprocess, "run", timed_out)
    assert control.stop_running(path) is None
    assert signals == [(12345, 0)]


@pytest.mark.parametrize("command", [
    "/usr/bin/python -m facelock menubar",
    "/usr/bin/python -m facelock watch",
    "/usr/bin/python -m facelock --camera 1 watch",
    "/usr/bin/python -m facelock --threshold=0.9 --recheck 5 watch --dry-run -v",
    "/usr/bin/python /some/venv/bin/facelock watch",
    "/some/venv/bin/facelock watch",
    "/some/venv/bin/facelock --interval 10 menubar --dry-run",
    "/some/venv/bin/facelock --camera=1 --threshold 0.8 watch",
])
def test_stop_signals_matching_facelock_process(tmp_path, monkeypatch, command):
    path = tmp_path / "pid"
    path.write_text("12345")
    signals = []
    monkeypatch.setattr(control.os, "kill", lambda pid, sig: signals.append((pid, sig)))
    monkeypatch.setattr(subprocess, "run", lambda *_args, **_kwargs: type(
        "Result", (), {"returncode": 0, "stdout": command + "\n"})())
    assert control.stop_running(path) == 12345
    assert signals == [(12345, 0), (12345, signal.SIGTERM)]


def test_lesson_requests_are_taken_once(tmp_path):
    path = tmp_path / "lesson"
    assert control.take_lesson_request(path) is None
    control.request_lesson(control.START_OVER, path)
    assert control.take_lesson_request(path) == control.START_OVER
    assert control.take_lesson_request(path) is None
