import json
import time

import numpy as np

from facelock import cli, config, identity, macos


def _paths(monkeypatch, tmp_path):
    monkeypatch.setattr(config, "CONFIG_FILE", tmp_path / "config.toml")
    monkeypatch.setattr(config, "ENROLLMENT_FILE", tmp_path / "enrollment.npz")
    monkeypatch.setattr(config, "DETECTOR_MODEL", tmp_path / "detector.onnx")
    monkeypatch.setattr(config, "IMPOSTOR_BANK", tmp_path / "bank.npz")
    monkeypatch.setattr(config, "PID_FILE", tmp_path / "watcher.pid")
    monkeypatch.setattr(config, "PAUSE_FILE", tmp_path / "pause")
    monkeypatch.setattr(config, "RECOGNIZERS", {
        "arcface": (tmp_path / "arcface.onnx", 512, .42),
        "sface": (tmp_path / "sface.onnx", 128, .363),
    })
    monkeypatch.setattr(macos, "APP_BUNDLE", tmp_path / "FaceLock.app")
    monkeypatch.setattr(macos, "AGENT_PLIST", tmp_path / "agent.plist")


def _checks(capsys):
    result = cli.main(["doctor", "--json"])
    return result, {check["name"]: check for check in json.loads(capsys.readouterr().out)["checks"]}


def test_doctor_reports_missing_readiness_without_writing(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    result, checks = _checks(capsys)
    assert result == 1
    assert checks["config"]["status"] == "pass"
    assert checks["enrollment"]["status"] == "fail"
    assert checks["detector"]["status"] == "fail"
    assert checks["watcher"]["status"] == "fail"
    assert checks["camera_session"]["status"] == "unverified"
    assert list(tmp_path.iterdir()) == []


def test_doctor_checks_valid_files_and_effective_threshold(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    sample = np.zeros((3, 512), dtype=np.float32)
    sample[:, 0] = 1
    identity.Enrollment({"me": sample}, threshold=.49).save(config.ENROLLMENT_FILE)
    np.savez(config.IMPOSTOR_BANK, arcface=sample[:1])
    for path in (config.DETECTOR_MODEL, *(entry[0] for entry in config.RECOGNIZERS.values())):
        path.write_bytes(b"model")
    monkeypatch.setattr("facelock.diagnostics.os.kill", lambda pid, sig: None)
    config.PID_FILE.write_text("123")
    result, checks = _checks(capsys)
    assert result == 0
    assert checks["enrollment"]["status"] == "pass"
    assert "0.490" in checks["threshold"]["detail"]
    assert checks["recognizer"]["status"] == "pass"
    assert checks["comparison_bank"]["status"] == "pass"
    assert checks["watcher"]["status"] == "unverified"


def test_doctor_reports_corrupt_config_and_continues(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    config.CONFIG_FILE.write_text("threshold = 'bad'\n")
    config.ENROLLMENT_FILE.write_bytes(b"broken")
    config.IMPOSTOR_BANK.write_bytes(b"broken")
    result, checks = _checks(capsys)
    assert result == 1
    assert checks["config"]["status"] == "fail"
    assert checks["enrollment"]["status"] == "fail"
    assert checks["comparison_bank"]["status"] == "fail"
    assert checks["detector"]["status"] == "fail"


def test_doctor_human_output_has_remedies(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    assert cli.main(["doctor"]) == 1
    output = capsys.readouterr().out
    assert "facelock enroll" in output
    assert "facelock watch" in output
    assert "unverified" in output


def test_doctor_reports_malformed_launchers(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    info = macos.APP_BUNDLE / "Contents" / "Info.plist"
    info.parent.mkdir(parents=True)
    info.write_bytes(b"<plist><array/></plist>")
    macos.AGENT_PLIST.write_bytes(b"<plist><array/></plist>")
    result, checks = _checks(capsys)
    assert result == 1
    assert checks["app_launcher"]["status"] == "fail"
    assert checks["login_agent"]["status"] == "fail"


def test_doctor_reports_active_pause_without_changing_file(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    for value in ("forever", str(time.time() + 3600)):
        config.PAUSE_FILE.write_text(value)
        _, checks = _checks(capsys)
        assert checks["pause"]["status"] == "unverified"
        assert "paused" in checks["pause"]["detail"].lower()
        assert "facelock resume" in checks["pause"]["detail"]
        assert config.PAUSE_FILE.read_text() == value


def test_doctor_reports_expired_pause_without_cleanup(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    config.PAUSE_FILE.write_text("1")
    _, checks = _checks(capsys)
    assert checks["pause"]["status"] == "pass"
    assert "not paused" in checks["pause"]["detail"].lower()
    assert config.PAUSE_FILE.read_text() == "1"


def test_doctor_reports_malformed_pause_without_cleanup(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    config.PAUSE_FILE.write_text("broken")
    _, checks = _checks(capsys)
    assert checks["pause"]["status"] == "fail"
    assert "facelock resume" in checks["pause"]["detail"]
    assert config.PAUSE_FILE.read_text() == "broken"


def test_doctor_reports_truncated_npz_files(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    truncated = b"PK\x03\x04incomplete"
    config.ENROLLMENT_FILE.write_bytes(truncated)
    config.IMPOSTOR_BANK.write_bytes(truncated)
    result, checks = _checks(capsys)
    assert result == 1
    assert checks["enrollment"]["status"] == "fail"
    assert checks["comparison_bank"]["status"] == "fail"


def test_doctor_reports_oversized_pid(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    config.PID_FILE.write_text(str(2**100))
    result, checks = _checks(capsys)
    assert result == 1
    assert checks["watcher"]["status"] == "fail"
    assert config.PID_FILE.read_text() == str(2**100)


def test_doctor_reports_unrenderable_pause_expiry(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    config.PAUSE_FILE.write_text("1e300")
    result, checks = _checks(capsys)
    assert result == 1
    assert checks["pause"]["status"] == "fail"
    assert config.PAUSE_FILE.read_text() == "1e300"


def test_doctor_rejects_pid_outside_process_range_before_query(monkeypatch, tmp_path, capsys):
    _paths(monkeypatch, tmp_path)
    config.PID_FILE.write_text(str(2**31))
    signals = []
    monkeypatch.setattr("facelock.diagnostics.os.kill", lambda *args: signals.append(args))
    _, checks = _checks(capsys)
    assert signals == []
    assert checks["watcher"]["status"] == "fail"
