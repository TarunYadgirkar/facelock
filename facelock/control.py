"""Pause switch, pid file and logging - the bits that let one process steer another."""

from __future__ import annotations

import logging
import os
import re
import signal
import time
from logging.handlers import RotatingFileHandler
from pathlib import Path

from . import config

FOREVER = float("inf")
_DURATION = re.compile(r"^(\d+(?:\.\d+)?)\s*([smh]?)$")
_UNITS = {"": 60.0, "s": 1.0, "m": 60.0, "h": 3600.0}


def parse_duration(text: str) -> float:
    """'30' and '30m' are minutes; '45s' seconds; '2h' hours; 'forever' never expires."""
    if text.strip().lower() in ("forever", "inf", "off"):
        return FOREVER
    match = _DURATION.match(text.strip().lower())
    if not match:
        raise ValueError(f"cannot read duration {text!r} (try 15m, 45s, 2h, forever)")
    return float(match.group(1)) * _UNITS[match.group(2)]


def pause(seconds: float, path: Path = config.PAUSE_FILE) -> float | None:
    """Suspend watching. Returns the wall-clock expiry, or None when indefinite."""
    path.parent.mkdir(parents=True, exist_ok=True)
    until = None if seconds == FOREVER else time.time() + seconds
    path.write_text("forever" if until is None else f"{until:.0f}")
    return until


def resume(path: Path = config.PAUSE_FILE) -> bool:
    if not path.exists():
        return False
    path.unlink()
    return True


def pause_expiry(path: Path = config.PAUSE_FILE) -> float | None:
    """None when not paused, FOREVER when indefinite, else the expiry timestamp."""
    try:
        raw = path.read_text().strip()
    except FileNotFoundError:
        return None
    if raw == "forever":
        return FOREVER
    try:
        until = float(raw)
    except ValueError:
        path.unlink(missing_ok=True)
        return None
    if until <= time.time():
        path.unlink(missing_ok=True)
        return None
    return until


def is_paused(path: Path = config.PAUSE_FILE) -> bool:
    return pause_expiry(path) is not None


START_OVER = "start-over"


def request_lesson(name: str, path: Path = config.LESSON_FILE) -> None:
    """Ask the running menu bar app to teach `name` (a lesson label, or START_OVER)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(name)


def take_lesson_request(path: Path = config.LESSON_FILE) -> str | None:
    """The app polls this: returns and clears a pending request, else None."""
    try:
        name = path.read_text().strip()
    except FileNotFoundError:
        return None
    path.unlink(missing_ok=True)
    return name or None


def write_pid(path: Path = config.PID_FILE) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(str(os.getpid()))


def clear_pid(path: Path = config.PID_FILE) -> None:
    path.unlink(missing_ok=True)


def running_pid(path: Path = config.PID_FILE) -> int | None:
    try:
        pid = int(path.read_text().strip())
    except (FileNotFoundError, ValueError):
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        path.unlink(missing_ok=True)
        return None
    except PermissionError:
        pass
    return pid


def stop_running(path: Path = config.PID_FILE) -> int | None:
    pid = running_pid(path)
    if pid is not None:
        os.kill(pid, signal.SIGTERM)
    return pid


def setup_logging(verbose: bool = False, path: Path = config.LOG_FILE) -> logging.Logger:
    path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger(config.APP)
    logger.setLevel(logging.DEBUG if verbose else logging.INFO)
    logger.handlers.clear()
    handler = RotatingFileHandler(path, maxBytes=512_000, backupCount=2)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)-7s %(message)s"))
    logger.addHandler(handler)
    return logger


def tail_log(lines: int = 10, path: Path = config.LOG_FILE) -> list[str]:
    try:
        return path.read_text().splitlines()[-lines:]
    except FileNotFoundError:
        return []
