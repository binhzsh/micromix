"""Lightweight engine contracts shared by API advertisement and worker dispatch.

No model imports, filesystem probes or network access. Preset IDs are persisted
in existing jobs; keep them stable even when their display names change.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class GenerationEngine:
    id: str
    label: str
    model: str
    inference_steps: int
    environment: str
    operations: tuple[str, ...]
    max_duration_seconds: int
    max_variations: int
    musical_metadata: bool
    health_model: str

    def catalog_entry(self) -> dict:
        return {
            'id': self.id, 'label': self.label, 'model': self.model,
            'inference_steps': self.inference_steps,
            'operations': list(self.operations),
            'max_duration_seconds': self.max_duration_seconds,
            'max_variations': self.max_variations,
            'musical_metadata': self.musical_metadata,
            'health_model': self.health_model,
        }


MUSIC_OPERATIONS = ('generation', 'reference-generation', 'remix', 'repaint')
GENERATION_ENGINES = (
    GenerationEngine('turbo', 'XL Turbo', 'acestep-v15-xl-turbo', 8,
                     '.venv-ace', MUSIC_OPERATIONS, 600, 4, True, 'ace_step'),
    GenerationEngine('quality', 'XL Quality', 'acestep-v15-xl-sft', 50,
                     '.venv-ace', MUSIC_OPERATIONS, 600, 4, True, 'ace_step'),
    GenerationEngine('minimax-cover', 'MiniMax (text only)', 'MiniMax-Music3-mxfp8', 30,
                     '.venv-mlx', ('generation',), 360, 1, False, 'minimax_music3'),
)


def generation_engine(preset: str, operation: str = 'generation') -> GenerationEngine:
    engine = next((item for item in GENERATION_ENGINES if item.id == preset), None)
    if engine is None:
        raise ValueError(f'Unknown generation preset: {preset}')
    if operation not in engine.operations:
        raise ValueError('Reference, Remix and Repaint require the local Turbo or Quality model; '
                         'MiniMax supports basic generation only')
    return engine


def worker_environment(operation: str, parameters: dict) -> str:
    if operation in MUSIC_OPERATIONS:
        return generation_engine(parameters.get('preset', 'turbo'), operation).environment
    environments = {
        'transcription': '.venv-muscriptor',
        'lyrics-transcription': '.venv-mlx',
        'vocal-swap': '.venv-mlx',
        'stem-split': '.venv-mlx',
    }
    if operation not in environments:
        raise ValueError(f'Unknown operation: {operation}')
    return environments[operation]
