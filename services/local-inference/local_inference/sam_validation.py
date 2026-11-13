"""Fail-closed validation for the pinned SAM-Audio large checkpoint."""
from __future__ import annotations

import copy
import re


def large_checkpoint_config(config: dict, weights: dict) -> dict:
    """Correct the published large snapshot's transformer config using its weights."""
    transformer = config.get('transformer', {})
    actual = tuple(transformer.get(key) for key in ('dim', 'n_heads', 'n_layers', 'context_dim'))
    if actual not in ((1536, 12, 12, 1536), (2816, 22, 22, 2816)):
        raise ValueError(f'Unsupported SAM-Audio large transformer configuration: {actual}')
    layers = {int(match.group(1)) for key in weights
              if (match := re.match(r'^transformer\.layers\.(\d+)\.', key))}
    if layers != set(range(22)):
        raise ValueError('SAM-Audio large checkpoint must contain transformer layers 0 through 21')
    expected = {'proj.weight': (2816, 768), 'memory_proj.weight': (2816, 768)}
    for i in range(22):
        expected[f'transformer.layers.{i}.attention.wq.weight'] = (2816, 2816)
        expected[f'transformer.layers.{i}.attention.q_norm.weight'] = (128,)
    for key, shape in expected.items():
        if key not in weights or tuple(weights[key].shape) != shape:
            raise ValueError(f'SAM-Audio large checkpoint has missing or incompatible {key}')
    result = copy.deepcopy(config)
    result['transformer'].update(dim=2816, n_heads=22, n_layers=22, context_dim=2816)
    return result


def validate_parameter_shapes(parameters: dict, weights: dict) -> None:
    """Match the pinned loader's supported layouts; watermark parameters are unused."""
    failures = []
    for key, parameter in parameters.items():
        if 'wm_model' in key:
            continue
        if key not in weights:
            failures.append(key)
            continue
        target, value = tuple(parameter.shape), tuple(weights[key].shape)
        compatible = value == target
        if len(target) == 2 and len(value) == 2:
            compatible |= value == target[::-1]
        elif len(target) == 3 and len(value) == 3:
            compatible |= value == (target[0], target[2], target[1])
            compatible |= value == (target[2], target[0], target[1])
            compatible |= value[1:] == (1, 1) and (1, 1, value[0]) == target
        if not compatible:
            failures.append(key)
    if failures:
        raise ValueError(f'SAM-Audio checkpoint missing or incompatible {len(failures)} required parameters: '
                         + ', '.join(sorted(failures)[:10]))
