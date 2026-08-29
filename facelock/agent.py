"""launchd agent so the watcher starts at login."""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
from pathlib import Path

from . import config

LABEL = "com.tarunyadgirkar.facelock"
PLIST = Path.home() / "Library" / "LaunchAgents" / f"{LABEL}.plist"
DOMAIN = f"gui/{os.getuid()}"


def _plist_body() -> dict:
    return {
        "Label": LABEL,
        "ProgramArguments": [sys.executable, "-m", "facelock", "watch"],
        "WorkingDirectory": str(Path(__file__).resolve().parent.parent),
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "ProcessType": "Interactive",
        "StandardOutPath": str(config.STATE_DIR / "agent.out.log"),
        "StandardErrorPath": str(config.STATE_DIR / "agent.err.log"),
    }


def install() -> Path:
    config.ensure_dirs()
    PLIST.parent.mkdir(parents=True, exist_ok=True)
    PLIST.write_bytes(plistlib.dumps(_plist_body()))
    subprocess.run(["launchctl", "bootout", DOMAIN, str(PLIST)], capture_output=True)
    result = subprocess.run(
        ["launchctl", "bootstrap", DOMAIN, str(PLIST)], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit(f"launchctl bootstrap failed: {result.stderr.strip()}")
    return PLIST


def uninstall() -> bool:
    if not PLIST.exists():
        return False
    subprocess.run(["launchctl", "bootout", DOMAIN, str(PLIST)], capture_output=True)
    PLIST.unlink()
    return True


def installed() -> bool:
    return PLIST.exists()
