"""macOS session state and screen locking."""

from __future__ import annotations

import subprocess

try:  # pyobjc is optional at import time so the tests run anywhere
    from Quartz import CGSessionCopyCurrentDictionary
except ImportError:  # pragma: no cover
    CGSessionCopyCurrentDictionary = None

CGSESSION = (
    "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession"
)
LOCK_COMMANDS = {
    "suspend": [CGSESSION, "-suspend"],
    "sleep": ["pmset", "displaysleepnow"],
}


def screen_locked() -> bool:
    """True when the login window is up or this session is not on the console."""
    if CGSessionCopyCurrentDictionary is None:  # pragma: no cover
        return False
    info = CGSessionCopyCurrentDictionary() or {}
    if info.get("CGSSessionScreenIsLocked", 0):
        return True
    return not bool(info.get("kCGSSessionOnConsoleKey", True))


def lock(method: str = "suspend") -> None:
    command = LOCK_COMMANDS.get(method)
    if command is None:
        raise ValueError(f"unknown lock method {method!r}")
    subprocess.run(command, check=False, capture_output=True)
