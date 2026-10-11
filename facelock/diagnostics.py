from __future__ import annotations

import math
import os
import plistlib
import time
from pathlib import Path
from zipfile import BadZipFile

import numpy as np

from . import config, identity, macos


def run_checks() -> list[dict[str, str]]:
    checks: list[dict[str, str]] = []

    def add(name: str, status: str, detail: str) -> None:
        checks.append({"name": name, "status": status, "detail": detail})

    try:
        cfg = config.load(config.CONFIG_FILE)
        add("config", "pass", f"{config.CONFIG_FILE if config.CONFIG_FILE.exists() else 'defaults'} valid")
    except (OSError, ValueError, TypeError) as exc:
        cfg = None
        add("config", "fail", f"Invalid config: {exc}; fix {config.CONFIG_FILE}")

    try:
        enrollment = identity.load(config.ENROLLMENT_FILE, missing_ok=False)
        if not len(enrollment):
            add("enrollment", "fail", "No face samples; run facelock enroll")
        else:
            add("enrollment", "pass", f"{len(enrollment)} samples, {len(enrollment.profiles)} profile{'' if len(enrollment.profiles) == 1 else 's'} ({enrollment.recognizer})")
    except FileNotFoundError:
        enrollment = None
        add("enrollment", "fail", "No enrollment; run facelock enroll")
    except (OSError, ValueError, EOFError, TypeError, BadZipFile) as exc:
        enrollment = None
        add("enrollment", "fail", f"Invalid enrollment: {exc}; run facelock enroll")

    recognizer = enrollment.recognizer if enrollment is not None else config.DEFAULT_RECOGNIZER
    if cfg is not None and enrollment is not None and len(enrollment):
        threshold = max(cfg.threshold, enrollment.threshold or config.default_threshold(recognizer))
        add("threshold", "pass", f"Effective threshold {threshold:.3f} ({recognizer})")
    else:
        add("threshold", "unverified", "Needs valid config and nonempty enrollment")

    def check_file(name: str, path: Path) -> None:
        try:
            if path.is_file() and path.stat().st_size > 0:
                add(name, "pass", f"Present: {path}")
            else:
                add(name, "fail", f"Missing or empty: {path}; run facelock test to fetch models")
        except OSError as exc:
            add(name, "fail", f"Cannot read {path}: {exc}")

    check_file("detector", config.DETECTOR_MODEL)
    check_file("aligner", config.RECOGNIZERS["sface"][0])
    check_file("recognizer", config.RECOGNIZERS[recognizer][0])

    try:
        bank = identity.load_bank(recognizer, config.IMPOSTOR_BANK)
        dimension = config.RECOGNIZERS[recognizer][1]
        if bank.ndim != 2 or bank.shape[1] != dimension or len(bank) == 0 or not np.isfinite(bank).all():
            raise ValueError("empty or malformed comparison embeddings")
        add("comparison_bank", "pass", f"{len(bank)} {recognizer} comparison samples")
    except (OSError, ValueError, EOFError, TypeError, BadZipFile) as exc:
        add("comparison_bank", "fail", f"Comparison bank unavailable: {exc}; restore {config.IMPOSTOR_BANK}")

    try:
        pid = int(config.PID_FILE.read_text().strip())
        if pid <= 0 or pid > 2 ** 31 - 1:
            raise ValueError("invalid PID")
        os.kill(pid, 0)
    except (FileNotFoundError, ValueError, OverflowError, ProcessLookupError):
        add("watcher", "fail", "No live watcher PID; open FaceLock or run facelock watch")
    except PermissionError:
        add("watcher", "unverified", "Watcher PID exists, but process access is denied; recognition is unverified")
    except OSError as exc:
        add("watcher", "unverified", f"Could not verify watcher process: {exc}")
    else:
        add("watcher", "unverified", f"PID {pid} exists; watcher identity and active recognition are unverified")

    try:
        raw_pause = config.PAUSE_FILE.read_text().strip()
    except FileNotFoundError:
        add("pause", "pass", "Not paused")
    except OSError as exc:
        add("pause", "fail", f"Cannot read pause state: {exc}; check {config.PAUSE_FILE}")
    else:
        if raw_pause == "forever":
            add("pause", "unverified", "Protection paused indefinitely; run facelock resume")
        else:
            try:
                expiry = float(raw_pause)
                if not math.isfinite(expiry) or expiry < 0:
                    raise ValueError("invalid expiry")
            except ValueError:
                add("pause", "fail", f"Malformed pause state in {config.PAUSE_FILE}; run facelock resume")
            else:
                if expiry > time.time():
                    try:
                        until = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(expiry))
                    except (OverflowError, ValueError):
                        add("pause", "fail", f"Malformed pause expiry in {config.PAUSE_FILE}; run facelock resume")
                    else:
                        add("pause", "unverified", f"Protection paused until {until}; run facelock resume")
                else:
                    add("pause", "pass", "Not paused (saved expiry has passed)")

    app = macos.APP_BUNDLE
    if not app.exists():
        add("app_launcher", "unverified", f"App not installed at {app}; CLI watch may still be used")
    else:
        launcher = app / "Contents" / "MacOS" / "FaceLock"
        info = app / "Contents" / "Info.plist"
        try:
            with info.open("rb") as handle:
                body = plistlib.load(handle)
            valid = isinstance(body, dict) and body.get("CFBundleExecutable") == "FaceLock" and launcher.is_file() and os.access(launcher, os.X_OK)
            add("app_launcher", "pass" if valid else "fail", f"{'Launcher present' if valid else 'Broken launcher; rerun facelock install-app'}: {app}")
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as exc:
            add("app_launcher", "fail", f"Broken app bundle: {exc}; rerun facelock install-app")

    agent = macos.AGENT_PLIST
    if not agent.exists():
        add("login_agent", "unverified", "Login agent not installed; start FaceLock manually if needed")
    else:
        try:
            with agent.open("rb") as handle:
                body = plistlib.load(handle)
            args = body.get("ProgramArguments", []) if isinstance(body, dict) else []
            valid = isinstance(body, dict) and body.get("Label") == macos.AGENT_LABEL and isinstance(args, list) and len(args) >= 4 and args[1:3] == ["-m", "facelock"] and args[3] in ("watch", "menubar") and Path(args[0]).is_file()
            add("login_agent", "pass" if valid else "fail", "Login agent plist looks valid; launchd state unverified" if valid else "Broken login agent; rerun facelock install-agent")
        except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as exc:
            add("login_agent", "fail", f"Broken login agent: {exc}; rerun facelock install-agent")

    add("camera_session", "unverified", "Camera recognition, permissions, and screen locking need a live test")
    return checks


def format_report(checks: list[dict[str, str]]) -> str:
    return "\n".join(f"{check['name']:16} {check['status']:10} {check['detail']}" for check in checks)
