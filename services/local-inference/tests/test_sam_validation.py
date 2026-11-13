import unittest
from types import SimpleNamespace

from local_inference.sam_validation import large_checkpoint_config, validate_parameter_shapes


def tensor(*shape):
    return SimpleNamespace(shape=shape)


def large_weights():
    weights = {'proj.weight': tensor(2816, 768), 'memory_proj.weight': tensor(2816, 768)}
    for index in range(22):
        weights[f'transformer.layers.{index}.attention.wq.weight'] = tensor(2816, 2816)
        weights[f'transformer.layers.{index}.attention.q_norm.weight'] = tensor(128)
    return weights


class SAMValidationTests(unittest.TestCase):
    def test_corrects_published_config_without_mutating_it(self):
        config = {'transformer': {'dim': 1536, 'n_heads': 12, 'n_layers': 12, 'context_dim': 1536,
                                  'dropout': 0.1}}
        corrected = large_checkpoint_config(config, large_weights())
        self.assertEqual(config['transformer']['dim'], 1536)
        self.assertEqual(corrected['transformer'], {'dim': 2816, 'n_heads': 22, 'n_layers': 22,
                                                    'context_dim': 2816, 'dropout': 0.1})
        self.assertEqual(large_checkpoint_config(corrected, large_weights()), corrected)

    def test_rejects_unknown_config_and_incomplete_or_incompatible_checkpoint(self):
        config = {'transformer': {'dim': 1536, 'n_heads': 12, 'n_layers': 12, 'context_dim': 1536}}
        for change in ('config', 'layer', 'shape', 'norm'):
            with self.subTest(change=change):
                weights = large_weights()
                candidate = {'transformer': dict(config['transformer'])}
                if change == 'config':
                    candidate['transformer']['n_heads'] = 8
                elif change == 'layer':
                    weights = {k: v for k, v in weights.items() if '.21.' not in k}
                elif change == 'shape':
                    weights['proj.weight'] = tensor(1536, 768)
                else:
                    weights['transformer.layers.3.attention.q_norm.weight'] = tensor(64)
                with self.assertRaises(ValueError):
                    large_checkpoint_config(candidate, weights)

    def test_shape_audit_matches_supported_layouts_and_allows_only_watermark_missing(self):
        params = {'a': tensor(2, 3), 'b': tensor(2, 3, 4), 'wm_model.x': tensor(1)}
        validate_parameter_shapes(params, {'a': tensor(3, 2), 'b': tensor(4, 2, 3)})
        for weights in ({'a': tensor(3, 2)}, {'a': tensor(2, 4), 'b': tensor(4, 2, 3)},
                        {'a': tensor(3, 2), 'b': tensor(4, 1, 1)}):
            with self.assertRaises(ValueError):
                validate_parameter_shapes(params, weights)


if __name__ == '__main__':
    unittest.main()
