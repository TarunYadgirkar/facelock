"""facelock command line."""

from __future__ import annotations

import argparse
import signal
import sys
import time

import numpy as np

from . import agent, config, control, enroll, identity, notify, session, vision
from .watcher import Decision, Event, Reading, State, run

STATE_GLYPH = {State.PRESENT: "+", State.AWAY: "-", State.STRANGER: "!"}


def _resolved_config(args: argparse.Namespace) -> config.Config:
    base = config.load()
    return config.with_overrides(
        base,
        camera=getattr(args, "camera", None),
        threshold=getattr(args, "threshold", None),
        timeout=getattr(args, "timeout", None),
        interval=getattr(args, "interval", None),
    )


def _status_line(text: str) -> None:
    sys.stdout.write(f"\r\033[K{text}")
    sys.stdout.flush()


def cmd_enroll(args: argparse.Namespace) -> int:
    cfg = _resolved_config(args)
    config.ensure_dirs()
    print(f"enrolling profile {args.profile!r} - {args.samples} samples")
    samples = enroll.capture(cfg, args.samples, _status_line)
    print()
    current = identity.load()
    updated = current.with_profile(args.profile, samples, append=args.add)
    path = updated.save()
    print(f"saved {len(updated)} samples across {len(updated.profiles)} profile(s) -> {path}")
    for name, count in updated.profiles.items():
        print(f"  {name}: {count}")
    print(enroll.quality_note(updated, cfg.threshold))
    return 0


def cmd_forget(args: argparse.Namespace) -> int:
    current = identity.load()
    if args.profile not in current.profiles:
        print(f"no profile named {args.profile!r}")
        return 1
    current.without_profile(args.profile).save()
    print(f"removed profile {args.profile!r}")
    return 0


def cmd_test(args: argparse.Namespace) -> int:
    cfg = _resolved_config(args)
    enrollment = identity.require()
    engine = vision.FaceEngine(cfg)
    scores: list[float] = []
    print(f"live scores against {len(enrollment)} samples, threshold {cfg.threshold:.3f}")
    print("ctrl-c to stop and see a threshold suggestion")
    deadline = time.monotonic() + args.seconds if args.seconds else float("inf")
    try:
        with vision.Camera(cfg) as camera:
            vision.warmup(camera)
            while time.monotonic() < deadline:
                frame = camera.read()
                if frame is None:
                    continue
                count, embeddings = engine.faces_and_embeddings(frame)
                match = enrollment.best(embeddings)
                scores.append(match.score)
                verdict = "ME" if match.accepted(cfg.threshold) else "not me"
                _status_line(
                    f"faces {count}  score {match.score:+.3f}  "
                    f"profile {match.profile or '-'}  -> {verdict}"
                )
                time.sleep(cfg.interval)
    except KeyboardInterrupt:
        pass
    print()
    hits = [s for s in scores if s > 0]
    if len(hits) < 5:
        print("not enough face frames to judge - stand in front of the camera and retry")
        return 1
    low = float(np.percentile(hits, 5))
    print(f"frames {len(scores)}, with a face {len(hits)}")
    print(f"score p05 {low:.3f}  median {float(np.median(hits)):.3f}  max {max(hits):.3f}")
    suggested = round(max(0.30, min(low - 0.04, 0.50)), 3)
    print(f"suggested threshold: {suggested:.3f} (current {cfg.threshold:.3f})")
    return 0


def cmd_watch(args: argparse.Namespace) -> int:
    cfg = _resolved_config(args)
    enrollment = identity.require()
    config.ensure_dirs()
    vision.silence_opencv_logs()
    log = control.setup_logging(args.verbose)
    control.write_pid()

    stopping = False

    def _stop(*_) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    mode = " [dry run]" if args.dry_run else ""
    print(
        f"watching{mode} - lock after {cfg.timeout:.1f}s away, "
        f"{cfg.unknown_face_timeout:.1f}s with a stranger in frame (threshold {cfg.threshold:.3f})"
    )
    log.info("watch started (timeout %.1fs threshold %.3f dry_run=%s)",
             cfg.timeout, cfg.threshold, args.dry_run)

    def observe(decision: Decision, reading: Reading) -> None:
        if args.verbose:
            _status_line(
                f"{STATE_GLYPH[decision.state]} score {reading.match.score:+.3f} "
                f"faces {reading.face_count} away {decision.away:4.1f}/{decision.deadline:.1f}s"
            )
        if decision.event is Event.WARN:
            if cfg.sound:
                notify.play()
            if cfg.notify:
                notify.banner("facelock", f"locking in {cfg.warn_before:.0f}s")
            log.debug("warn (state=%s away=%.1fs)", decision.state.value, decision.away)
        elif decision.event is Event.LOCK:
            verb = "would lock" if args.dry_run else "locking"
            print(f"\n{time.strftime('%H:%M:%S')} {verb} ({decision.state.value}, "
                  f"away {decision.away:.1f}s)")
            log.info("%s (state=%s away=%.1fs)", verb, decision.state.value, decision.away)

    try:
        run(
            cfg,
            enrollment,
            observe,
            dry_run=args.dry_run,
            paused=control.is_paused,
            should_stop=lambda: stopping,
        )
    finally:
        control.clear_pid()
        log.info("watch stopped")
        print("\nstopped")
    return 0


def cmd_pause(args: argparse.Namespace) -> int:
    seconds = control.parse_duration(args.duration)
    until = control.pause(seconds)
    when = "until resumed" if until is None else f"until {time.strftime('%H:%M:%S', time.localtime(until))}"
    print(f"paused {when}")
    return 0


def cmd_resume(_: argparse.Namespace) -> int:
    print("resumed" if control.resume() else "was not paused")
    return 0


def cmd_stop(_: argparse.Namespace) -> int:
    pid = control.stop_running()
    print(f"signalled watcher pid {pid}" if pid else "no watcher running")
    return 0


def cmd_status(_: argparse.Namespace) -> int:
    cfg = config.load()
    enrollment = identity.load()
    pid = control.running_pid()
    expiry = control.pause_expiry()
    print(f"watcher     : {'running pid ' + str(pid) if pid else 'not running'}")
    if expiry is None:
        print("paused      : no")
    elif expiry == control.FOREVER:
        print("paused      : until resumed")
    else:
        print(f"paused      : until {time.strftime('%H:%M:%S', time.localtime(expiry))}")
    print(f"login agent : {'installed' if agent.installed() else 'not installed'}")
    print(f"screen      : {'locked' if session.screen_locked() else 'unlocked'}")
    if len(enrollment):
        profiles = ", ".join(f"{n}({c})" for n, c in enrollment.profiles.items())
        print(f"enrolled    : {len(enrollment)} samples - {profiles}")
        print(f"              {enroll.quality_note(enrollment, cfg.threshold)}")
    else:
        print("enrolled    : nothing yet - run: facelock enroll")
    print(f"settings    : timeout {cfg.timeout}s  threshold {cfg.threshold}  "
          f"interval {cfg.interval}s  lock {cfg.lock_method}")
    recent = control.tail_log(5)
    if recent:
        print("recent      :")
        for line in recent:
            print(f"  {line}")
    return 0


def cmd_config(args: argparse.Namespace) -> int:
    if args.write:
        print(f"wrote {config.write_default()}")
        return 0
    print(f"config file : {config.CONFIG_FILE} "
          f"({'present' if config.CONFIG_FILE.exists() else 'absent, using defaults'})")
    for key, value in vars(config.load()).items():
        print(f"  {key} = {value}")
    return 0


def cmd_install_agent(_: argparse.Namespace) -> int:
    path = agent.install()
    print(f"installed {path}")
    print("the agent inherits camera permission from the python binary it runs - if it never "
          "sees your face, run `facelock watch` once in a terminal and approve the prompt")
    return 0


def cmd_uninstall_agent(_: argparse.Namespace) -> int:
    print("removed login agent" if agent.uninstall() else "no login agent installed")
    return 0


def cmd_menubar(args: argparse.Namespace) -> int:
    from . import menubar

    return menubar.main(_resolved_config(args), dry_run=args.dry_run)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="facelock", description=__doc__)
    parser.add_argument("--camera", type=int, help="camera index")
    parser.add_argument("--threshold", type=float, help="cosine match threshold")
    parser.add_argument("--interval", type=float, help="seconds between polls")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("enroll", help="capture reference samples of my face")
    p.add_argument("--profile", default="me", help="profile name (e.g. glasses, evening)")
    p.add_argument("--samples", type=int, default=25)
    p.add_argument("--add", action="store_true", help="append to the existing profile")
    p.set_defaults(func=cmd_enroll)

    p = sub.add_parser("forget", help="delete an enrolled profile")
    p.add_argument("profile")
    p.set_defaults(func=cmd_forget)

    p = sub.add_parser("test", help="print live match scores and suggest a threshold")
    p.add_argument("--seconds", type=float, default=0.0, help="stop after N seconds")
    p.set_defaults(func=cmd_test)

    p = sub.add_parser("watch", help="lock the screen when I am not in front of it")
    p.add_argument("--timeout", type=float, help="seconds away before locking")
    p.add_argument("--dry-run", action="store_true", help="log instead of locking")
    p.add_argument("-v", "--verbose", action="store_true")
    p.set_defaults(func=cmd_watch)

    p = sub.add_parser("menubar", help="run the watcher with a menu bar control")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=cmd_menubar)

    p = sub.add_parser("pause", help="suspend watching (15m, 45s, 2h, forever)")
    p.add_argument("duration", nargs="?", default="15m")
    p.set_defaults(func=cmd_pause)

    sub.add_parser("resume", help="undo a pause").set_defaults(func=cmd_resume)
    sub.add_parser("stop", help="stop a running watcher").set_defaults(func=cmd_stop)
    sub.add_parser("status", help="show watcher, enrollment and settings").set_defaults(
        func=cmd_status
    )

    p = sub.add_parser("config", help="show settings or write a config file")
    p.add_argument("--write", action="store_true", help="write a config.toml of the defaults")
    p.set_defaults(func=cmd_config)

    sub.add_parser("install-agent", help="start at login via launchd").set_defaults(
        func=cmd_install_agent
    )
    sub.add_parser("uninstall-agent", help="remove the login agent").set_defaults(
        func=cmd_uninstall_agent
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print()
        return 130
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
