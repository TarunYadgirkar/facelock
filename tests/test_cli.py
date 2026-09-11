from argparse import Namespace

import numpy as np

from facelock import cli, config, enroll, identity


def test_failed_reenrollment_never_saves(monkeypatch):
    x = np.zeros((10, 512), dtype=np.float32)
    x[:, 0] = 1
    original = identity.Enrollment({"me": x})
    monkeypatch.setattr(config, "load", lambda: config.Config())
    monkeypatch.setattr(config, "ensure_dirs", lambda: None)
    monkeypatch.setattr(config, "write", lambda value: None)
    monkeypatch.setattr(identity, "load", lambda: original)
    monkeypatch.setattr(enroll, "capture", lambda *args, **kwargs: x[:2])
    saved = []
    monkeypatch.setattr(identity.Enrollment, "save", lambda self: saved.append(self))
    assert cli.main(["enroll"]) == 2
    assert saved == []


def test_calibration_write_binds_threshold_to_enrollment(monkeypatch):
    x = np.zeros((10, 512), dtype=np.float32)
    x[:, 0] = 1
    original = identity.Enrollment({"me": x})
    monkeypatch.setattr(config, "load", lambda: config.Config())
    monkeypatch.setattr(identity, "require", lambda: original)
    monkeypatch.setattr(config, "write", lambda value: None)
    saved = []
    monkeypatch.setattr(identity.Enrollment, "save", lambda self: saved.append(self.threshold))
    assert cli.cmd_calibrate(Namespace(write=True)) == 0
    assert saved and saved[0] >= .42
