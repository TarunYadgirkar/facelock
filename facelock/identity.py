"""Enrolled face embeddings, stored as named profiles, plus threshold calibration."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import config

MODEL_KEY = "__recognizer__"  # npz entry naming the recognizer the samples came from
TOP_K = 3  # a probe is scored as the mean of its closest K enrolled views
# Calibration: the threshold sits this far above the strongest impostor in the bank, and is
# never set below the recognizer's default nor above a ceiling that would reject real poses.
CALIBRATION_MARGIN = 0.08
CALIBRATION_CEILING = 0.55


def embedding_dim(recognizer: str) -> int:
    return config.RECOGNIZERS[recognizer][1]


@dataclass(frozen=True)
class Match:
    score: float
    profile: str | None

    def accepted(self, threshold: float) -> bool:
        return self.score >= threshold


NO_MATCH = Match(0.0, None)


class Enrollment:
    """Immutable set of L2-normalized embeddings grouped by profile name."""

    def __init__(self, profiles: dict[str, np.ndarray],
                 recognizer: str = config.DEFAULT_RECOGNIZER):
        if recognizer not in config.RECOGNIZERS:
            raise ValueError(f"unknown recognizer {recognizer!r}")
        self.recognizer = recognizer
        dim = embedding_dim(recognizer)
        self._profiles = {name: np.asarray(v, dtype=np.float32) for name, v in profiles.items()}
        for name, samples in self._profiles.items():
            if samples.ndim != 2 or samples.shape[1] != dim:
                raise ValueError(f"profile {name!r} has malformed samples {samples.shape}")
        self._matrix = (
            np.vstack(list(self._profiles.values()))
            if self._profiles
            else np.empty((0, dim), dtype=np.float32)
        )
        self._owners = [name for name, s in self._profiles.items() for _ in range(len(s))]

    @property
    def profiles(self) -> dict[str, int]:
        return {name: len(samples) for name, samples in self._profiles.items()}

    @property
    def templates(self) -> np.ndarray:
        return self._matrix

    def __len__(self) -> int:
        return len(self._matrix)

    def scores(self, embeddings: np.ndarray) -> np.ndarray:
        """One score per probe: mean similarity to its TOP_K closest enrolled views.

        Taking the single best of many templates lets a stranger win on one lucky view;
        averaging the closest few asks them to resemble me from several angles at once.
        """
        sims = np.asarray(embeddings, dtype=np.float32) @ self._matrix.T
        k = min(TOP_K, sims.shape[1])
        return np.sort(sims, axis=1)[:, -k:].mean(axis=1)

    def best(self, embeddings: np.ndarray) -> Match:
        """Highest-scoring visible face, with the profile owning its closest view."""
        if len(embeddings) == 0 or len(self._matrix) == 0:
            return NO_MATCH
        probes = np.asarray(embeddings, dtype=np.float32)
        scores = self.scores(probes)
        winner = int(np.argmax(scores))
        nearest = int(np.argmax(probes[winner] @ self._matrix.T))
        return Match(float(scores[winner]), self._owners[nearest])

    def with_profile(self, name: str, samples: np.ndarray, append: bool = False) -> Enrollment:
        merged = dict(self._profiles)
        samples = np.asarray(samples, dtype=np.float32)
        if append and name in merged:
            samples = np.vstack([merged[name], samples])
        merged[name] = samples
        return Enrollment(merged, self.recognizer)

    def without_profile(self, name: str) -> Enrollment:
        return Enrollment({k: v for k, v in self._profiles.items() if k != name}, self.recognizer)

    def separation(self) -> tuple[float, float]:
        """(min, mean) similarity among enrolled samples - how consistent the enrollment is."""
        if len(self._matrix) < 2:
            return 0.0, 0.0
        sims = self._matrix @ self._matrix.T
        off = sims[~np.eye(len(self._matrix), dtype=bool)]
        return float(off.min()), float(off.mean())

    def leave_one_out(self) -> np.ndarray:
        """Each enrolled view scored against the others - how my own frames would fare."""
        n = len(self._matrix)
        if n < 2:
            return np.empty(0, dtype=np.float32)
        sims = self._matrix @ self._matrix.T
        np.fill_diagonal(sims, -np.inf)
        k = min(TOP_K, n - 1)
        return np.sort(sims, axis=1)[:, -k:].mean(axis=1)

    def save(self, path: Path = config.ENROLLMENT_FILE) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(path, **self._profiles, **{MODEL_KEY: np.array(self.recognizer)})
        path.chmod(0o600)
        return path


def load(path: Path = config.ENROLLMENT_FILE) -> Enrollment:
    if not path.exists():
        return Enrollment({})
    with np.load(path) as data:
        # files written before 0.4 carry no tag and are SFace
        recognizer = str(data[MODEL_KEY]) if MODEL_KEY in data.files else "sface"
        return Enrollment({name: data[name] for name in data.files if name != MODEL_KEY},
                          recognizer)


def require(path: Path = config.ENROLLMENT_FILE) -> Enrollment:
    enrollment = load(path)
    if len(enrollment) == 0:
        raise SystemExit(f"nothing enrolled yet ({path})\nrun: facelock enroll")
    return enrollment


def stamp(path: Path = config.ENROLLMENT_FILE) -> tuple[int, int] | None:
    try:
        stat = path.stat()
    except FileNotFoundError:
        return None
    return stat.st_mtime_ns, stat.st_size


class Live:
    """An enrollment that picks up samples `facelock learn` adds while the watcher runs."""

    def __init__(self, path: Path = config.ENROLLMENT_FILE):
        self._path = path
        self._enrollment = require(path)
        self._seen = stamp(path)

    def refresh(self) -> Enrollment:
        current = stamp(self._path)
        if current is not None and current != self._seen:
            self._enrollment = load(self._path)
            self._seen = current
        return self._enrollment

    @property
    def recognizer(self) -> str:
        return self.refresh().recognizer

    def best(self, embeddings: np.ndarray) -> Match:
        return self.refresh().best(embeddings)

    def __len__(self) -> int:
        return len(self._enrollment)


# --- calibration -----------------------------------------------------------

@dataclass(frozen=True)
class Calibration:
    threshold: float  # what to run with
    stranger_max: float  # strongest impostor in the bank against this enrollment
    stranger_p99: float
    own_p05: float  # 5th percentile of my own views, leave-one-out
    bank_size: int

    @property
    def gap(self) -> float:
        return self.own_p05 - self.stranger_max

    def note(self) -> str:
        head = (f"threshold {self.threshold:.3f} - strongest of {self.bank_size} strangers "
                f"scores {self.stranger_max:.3f}, your own views {self.own_p05:.3f}+")
        if self.gap < 2 * CALIBRATION_MARGIN:
            return head + " - thin margin, teach more poses or improve the light"
        return head


def load_bank(recognizer: str, path: Path = config.IMPOSTOR_BANK) -> np.ndarray:
    """Embeddings of a few thousand different people, one face each, for the recognizer."""
    with np.load(path) as data:
        if recognizer not in data.files:
            raise ValueError(f"impostor bank has no {recognizer!r} entries")
        return data[recognizer].astype(np.float32)


def calibrate(enrollment: Enrollment, bank: np.ndarray | None = None) -> Calibration:
    """Pick a threshold that no banked stranger reaches, with a margin, for this enrollment."""
    if len(enrollment) == 0:
        raise ValueError("nothing enrolled to calibrate against")
    if bank is None:
        bank = load_bank(enrollment.recognizer)
    strangers = enrollment.scores(bank)
    own = enrollment.leave_one_out()
    floor = config.default_threshold(enrollment.recognizer)
    threshold = min(CALIBRATION_CEILING, max(floor, float(strangers.max()) + CALIBRATION_MARGIN))
    return Calibration(
        threshold=round(threshold, 3),
        stranger_max=float(strangers.max()),
        stranger_p99=float(np.quantile(strangers, 0.99)),
        own_p05=float(np.quantile(own, 0.05)) if len(own) else 0.0,
        bank_size=len(bank),
    )
