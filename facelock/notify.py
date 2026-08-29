"""Non-blocking user feedback: a sound cue and a Notification Center banner."""

from __future__ import annotations

import shlex
import subprocess

WARN_SOUND = "/System/Library/Sounds/Tink.aiff"


def _spawn(command: list[str]) -> None:
    try:
        subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass  # feedback is best-effort; never let it break the watch loop


def play(sound: str = WARN_SOUND) -> None:
    _spawn(["afplay", "-v", "0.3", sound])


def banner(title: str, message: str) -> None:
    script = f"display notification {shlex.quote(message)} with title {shlex.quote(title)}"
    _spawn(["osascript", "-e", script])
