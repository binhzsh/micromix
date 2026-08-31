from __future__ import annotations

import secrets


_SEED_SPACE = 2**32


def resolve_variation_seeds(seed: int | None, count: int) -> list[int]:
    if seed is None:
        return [secrets.randbelow(_SEED_SPACE) for _ in range(count)]
    return [(seed + offset) % _SEED_SPACE for offset in range(count)]
