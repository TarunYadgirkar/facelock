"""Everything that talks to macOS: session state, locking, alerts, the login agent.

One module so the platform surface is easy to see and easy to swap.
"""

from __future__ import annotations

import ctypes
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

from . import config

try:  # pyobjc is optional at import time so the tests run anywhere
    from Quartz import CGSessionCopyCurrentDictionary
except ImportError:  # pragma: no cover
    CGSessionCopyCurrentDictionary = None

LOGIN_FRAMEWORK = "/System/Library/PrivateFrameworks/login.framework/login"
LOCK_COMMANDS = {
    "sleep": ["pmset", "displaysleepnow"],
}
WARN_SOUND = "/System/Library/Sounds/Tink.aiff"

AGENT_LABEL = "com.tarunyadgirkar.facelock"
AGENT_PLIST = Path.home() / "Library" / "LaunchAgents" / f"{AGENT_LABEL}.plist"
APP_BUNDLE = Path.home() / "Applications" / "FaceLock.app"


def _spawn(command: list[str]) -> None:
    """Fire and forget. Alerts are best-effort and must never stall the watch loop."""
    try:
        subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


# --- session ---------------------------------------------------------------

def screen_locked() -> bool:
    """True when the login window is up or this session is not on the console."""
    if CGSessionCopyCurrentDictionary is None:  # pragma: no cover
        return False
    info = CGSessionCopyCurrentDictionary() or {}
    if info.get("CGSSessionScreenIsLocked", 0):
        return True
    return not bool(info.get("kCGSSessionOnConsoleKey", True))


def lock(method: str = "suspend") -> None:
    if method == "suspend":
        # The old CGSession -suspend binary is gone as of macOS 26.
        try:
            ctypes.CDLL(LOGIN_FRAMEWORK).SACLockScreenImmediate()
            return
        except (OSError, AttributeError):
            method = "sleep"  # locks too, given require-password-immediately
    command = LOCK_COMMANDS.get(method)
    if command is None:
        raise ValueError(f"unknown lock method {method!r}")
    subprocess.run(command, check=False, capture_output=True)


# --- alerts ----------------------------------------------------------------

def play(sound: str = WARN_SOUND) -> None:
    _spawn(["afplay", "-v", "0.3", sound])


def banner(title: str, message: str) -> None:
    script = f"display notification {shlex.quote(message)} with title {shlex.quote(title)}"
    _spawn(["osascript", "-e", script])


def warn(cfg: config.Config, message: str) -> None:
    if cfg.sound:
        play()
    if cfg.notify:
        banner("facelock", message)


# --- login agent -----------------------------------------------------------

def _domain() -> str:
    return f"gui/{os.getuid()}"


def _plist_body(command: str) -> dict:
    return {
        "Label": AGENT_LABEL,
        "ProgramArguments": [sys.executable, "-m", "facelock", command],
        "WorkingDirectory": str(Path(__file__).resolve().parent.parent),
        "RunAtLoad": True,
        "KeepAlive": {"SuccessfulExit": False},
        "ThrottleInterval": 10,
        "ProcessType": "Interactive",
        "StandardOutPath": str(config.STATE_DIR / "agent.out.log"),
        "StandardErrorPath": str(config.STATE_DIR / "agent.err.log"),
    }


def install_agent(command: str = "menubar") -> Path:
    """Start facelock at login. The menu bar app by default; "watch" for headless."""
    config.ensure_dirs()
    AGENT_PLIST.parent.mkdir(parents=True, exist_ok=True)
    AGENT_PLIST.write_bytes(plistlib.dumps(_plist_body(command)))
    subprocess.run(["launchctl", "bootout", _domain(), str(AGENT_PLIST)], capture_output=True)
    result = subprocess.run(
        ["launchctl", "bootstrap", _domain(), str(AGENT_PLIST)], capture_output=True, text=True
    )
    if result.returncode != 0:
        raise SystemExit(f"launchctl bootstrap failed: {result.stderr.strip()}")
    return AGENT_PLIST


def uninstall_agent() -> bool:
    if not AGENT_PLIST.exists():
        return False
    subprocess.run(["launchctl", "bootout", _domain(), str(AGENT_PLIST)], capture_output=True)
    AGENT_PLIST.unlink()
    return True


def agent_installed() -> bool:
    return AGENT_PLIST.exists()


# --- app bundle -------------------------------------------------------------

APP_PLIST = {
    "CFBundleName": "FaceLock",
    "CFBundleDisplayName": "FaceLock",
    "CFBundleIdentifier": f"{AGENT_LABEL}.app",
    "CFBundleExecutable": "FaceLock",
    "CFBundlePackageType": "APPL",
    "LSUIElement": True,  # menu bar only, no Dock icon
    "NSCameraUsageDescription": "FaceLock watches for your face to know when to lock the screen.",
}


def install_app(bundle: Path = APP_BUNDLE) -> Path:
    """Write a double-clickable FaceLock.app that opens the menu bar watcher."""
    macos_dir = bundle / "Contents" / "MacOS"
    macos_dir.mkdir(parents=True, exist_ok=True)
    (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps(APP_PLIST))
    launcher = macos_dir / "FaceLock"
    # Trampoline, not exec: a process that IS the LSUIElement bundle gets its
    # NSStatusItem window parked offscreen at the wrong layer (observed on macOS 26).
    # Detached, the watcher runs exactly like a terminal launch, which renders fine.
    launcher.write_text(
        '#!/bin/zsh\n'
        f'nohup {shlex.quote(sys.executable)} -m facelock menubar '
        f'>> {shlex.quote(str(config.LOG_FILE))} 2>&1 &\n'
    )
    launcher.chmod(0o755)
    return bundle


def uninstall_app(bundle: Path = APP_BUNDLE) -> bool:
    if not bundle.exists():
        return False
    shutil.rmtree(bundle)
    return True
