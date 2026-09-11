from types import SimpleNamespace

import pytest

from facelock import macos


def test_banner_passes_untrusted_text_as_argv(monkeypatch):
    calls = []
    monkeypatch.setattr(macos, "_spawn", calls.append)
    macos.banner('title " quoted', 'message \\ slash')
    command = calls[0]
    assert command[:2] == ["osascript", "-e"]
    assert command[-3] == "--"
    assert command[-2:] == ['title " quoted', 'message \\ slash']
    assert "item 1 of argv" in command[2]
    assert "item 2 of argv" in command[2]


@pytest.mark.parametrize("method, sleeps", [("suspend", 0), ("sleep", 1)])
def test_lock_requests_immediate_lock_then_verifies(monkeypatch, method, sleeps):
    calls = []
    framework = SimpleNamespace(SACLockScreenImmediate=lambda: calls.append("lock"))
    monkeypatch.setattr(macos.ctypes, "CDLL", lambda path: framework)
    monkeypatch.setattr(macos.subprocess, "run", lambda *args, **kwargs: calls.append("sleep"))
    monkeypatch.setattr(macos, "screen_locked", lambda: True)
    macos.lock(method)
    assert calls == ["lock"] + ["sleep"] * sleeps


def test_lock_retries_verification_and_exposes_failure(monkeypatch):
    checks = []
    framework = SimpleNamespace(SACLockScreenImmediate=lambda: None)
    monkeypatch.setattr(macos.ctypes, "CDLL", lambda path: framework)
    monkeypatch.setattr(macos, "screen_locked", lambda: checks.append(1) and False)
    monkeypatch.setattr(macos.time, "sleep", lambda seconds: None)
    with pytest.raises(RuntimeError, match="did not engage"):
        macos.lock("suspend")
    assert len(checks) == macos.LOCK_VERIFY_ATTEMPTS
