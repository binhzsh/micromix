from __future__ import annotations

import pytest
from pydantic import ValidationError

from micromix_api.generation import resolve_variation_seeds
from micromix_api.models import (
    ReferenceGenerationRequest,
    RemixRequest,
    RepaintRequest,
)


def test_explicit_variation_seeds_are_consecutive_and_wrap():
    assert resolve_variation_seeds(4_294_967_295, 3) == [4_294_967_295, 0, 1]


def test_random_variation_seeds_are_valid_and_independent(monkeypatch):
    values = iter([11, 22])
    monkeypatch.setattr(
        "micromix_api.generation.secrets.randbelow",
        lambda _: next(values),
    )

    assert resolve_variation_seeds(None, 2) == [11, 22]


def test_reference_and_remix_defaults_are_concise():
    reference = ReferenceGenerationRequest(
        reference_asset_id="reference",
        prompt="dream pop",
    )
    remix = RemixRequest(source_asset_id="source", prompt="heavy rock")

    assert reference.variation_count == 2
    assert reference.duration_seconds == 30
    assert remix.variation_count == 2
    assert remix.source_strength == 0.6


def test_repaint_accepts_three_to_ninety_second_intervals():
    shortest = RepaintRequest(
        source_asset_id="source",
        prompt="piano bridge",
        start_seconds=4,
        end_seconds=7,
    )
    longest = RepaintRequest(
        source_asset_id="source",
        prompt="piano bridge",
        start_seconds=4,
        end_seconds=94,
    )

    assert shortest.repaint_strength == 0.5
    assert longest.end_seconds - longest.start_seconds == 90


@pytest.mark.parametrize(
    ("start", "end"),
    [(4, 4), (4, 6.99), (4, 94.01)],
)
def test_repaint_rejects_invalid_intervals(start: float, end: float):
    with pytest.raises(ValidationError):
        RepaintRequest(
            source_asset_id="source",
            prompt="piano bridge",
            start_seconds=start,
            end_seconds=end,
        )


@pytest.mark.parametrize(
    "build_request",
    [
        lambda: ReferenceGenerationRequest(
            reference_asset_id="reference",
            prompt="dream pop",
            variation_count=5,
        ),
        lambda: RemixRequest(
            source_asset_id="source",
            prompt="heavy rock",
            source_strength=1.01,
        ),
        lambda: RepaintRequest(
            source_asset_id="source",
            prompt="bridge",
            start_seconds=0,
            end_seconds=3,
            repaint_strength=-0.01,
        ),
    ],
)
def test_reimagine_requests_reject_out_of_range_controls(build_request):
    with pytest.raises(ValidationError):
        build_request()
