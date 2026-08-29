"""Enrolled face embeddings, stored as named profiles."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import numpy as np

from . import config

EMBEDDING_DIM = 128


@dataclass(frozen=True)
class Match:
    score: float
    profile: str | None

    def accepted(self, threshold: float) -> bool:
        return self.score >= threshold


NO_MATCH = Match(0.0, None)


class Enrollment:
    """Immutable set of L2-normalized embeddings grouped by profile name."""

    def __init__(self, profiles: dict[str, np.ndarray]):
        self._profiles = {name: np.asarray(v, dtype=np.float32) for name, v in profiles.items()}
        for name, samples in self._profiles.items():
            if samples.ndim != 2 or samples.shape[1] != EMBEDDING_DIM:
                raise ValueError(f"profile {name!r} has malformed samples {samples.shape}")
        self._matrix = (
            np.vstack(list(self._profiles.values()))
            if self._profiles
            else np.empty((0, EMBEDDING_DIM), dtype=np.float32)
        )
        self._owners = [name for name, s in self._profiles.items() for _ in range(len(s))]

    @property
    def profiles(self) -> dict[str, int]:
        return {name: len(samples) for name, samples in self._profiles.items()}

    def __len__(self) -> int:
        return len(self._matrix)

    def best(self, embeddings: np.ndarray) -> Match:
        """Highest cosine similarity between any visible face and any enrolled sample."""
        if len(embeddings) == 0 or len(self._matrix) == 0:
            return NO_MATCH
        sims = np.asarray(embeddings, dtype=np.float32) @ self._matrix.T
        index = int(np.argmax(sims))
        return Match(float(sims.flat[index]), self._owners[index % sims.shape[1]])

    def with_profile(self, name: str, samples: np.ndarray, append: bool = False) -> Enrollment:
        merged = dict(self._profiles)
        samples = np.asarray(samples, dtype=np.float32)
        if append and name in merged:
            samples = np.vstack([merged[name], samples])
        merged[name] = samples
        return Enrollment(merged)

    def without_profile(self, name: str) -> Enrollment:
        return Enrollment({k: v for k, v in self._profiles.items() if k != name})

    def separation(self) -> tuple[float, float]:
        """(min, mean) similarity among enrolled samples - how consistent the enrollment is."""
        if len(self._matrix) < 2:
            return 0.0, 0.0
        sims = self._matrix @ self._matrix.T
        off = sims[~np.eye(len(self._matrix), dtype=bool)]
        return float(off.min()), float(off.mean())

    def save(self, path: Path = config.ENROLLMENT_FILE) -> Path:
        path.parent.mkdir(parents=True, exist_ok=True)
        np.savez_compressed(path, **self._profiles)
        path.chmod(0o600)
        return path


def load(path: Path = config.ENROLLMENT_FILE) -> Enrollment:
    if not path.exists():
        return Enrollment({})
    with np.load(path) as data:
        return Enrollment({name: data[name] for name in data.files})


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

    def best(self, embeddings: np.ndarray) -> Match:
        current = stamp(self._path)
        if current is not None and current != self._seen:
            self._enrollment = load(self._path)
            self._seen = current
        return self._enrollment.best(embeddings)

    def __len__(self) -> int:
        return len(self._enrollment)
