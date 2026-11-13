"""Observe fake component calls and fallbacks, not real-model inference."""
import importlib.util
import unittest
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace

from local_inference.ace_trace import ACEExecutionTrace


class PTModel:
    def generate_audio(self, **kwargs):
        return kwargs


class VAE:
    def decode(self, latents):
        return latents


class Handler:
    def __init__(self):
        self.model = PTModel()
        self.vae = VAE()
        self.fail_mlx = False

    def _mlx_run_diffusion(self, **kwargs):
        if self.fail_mlx:
            raise RuntimeError('not retained in diagnostics')
        return kwargs

    def _mlx_vae_decode(self, latents):
        if self.fail_mlx:
            raise RuntimeError('not retained in diagnostics')
        return latents


class ACETraceTests(unittest.TestCase):
    def test_success_failure_fallback_and_restore_without_changing_results(self):
        handler = Handler()
        handler.fail_mlx = True
        planner = SimpleNamespace(llm_backend='pt', llm=SimpleNamespace(generate=lambda x: x))
        original_generate = planner.llm.generate
        latents = SimpleNamespace(device='mps')
        with ACEExecutionTrace(handler, planner) as trace:
            with self.assertRaises(RuntimeError):
                handler._mlx_run_diffusion(src_latents=latents)
            self.assertEqual(handler.model.generate_audio(src_latents=latents), {'src_latents': latents})
            with self.assertRaises(RuntimeError):
                handler._mlx_vae_decode(latents)
            self.assertIs(handler.vae.decode(latents), latents)
            self.assertEqual(planner.llm.generate('private prompt'), 'private prompt')
        snapshot = trace.snapshot()
        for component in ('dit', 'vae', 'planner'):
            self.assertEqual(snapshot['components'][component]['successful_backends'], ['pytorch'])
        failures = [call for call in snapshot['calls'] if call['failed']]
        self.assertEqual(len(failures), 2)
        self.assertTrue(all(call['backend'] == 'mlx' for call in failures))
        self.assertNotIn('private prompt', str(snapshot))
        self.assertNotIn('not retained', str(snapshot))
        self.assertTrue(any(call['successful_input_devices'] == ['mps'] for call in snapshot['calls']))
        self.assertNotIn('_mlx_run_diffusion', vars(handler))
        self.assertNotIn('decode', vars(handler.vae))
        self.assertIs(planner.llm.generate, original_generate)

    def test_mlx_success_and_unrequested_planner(self):
        handler = Handler()
        with ACEExecutionTrace(handler, None) as trace:
            handler._mlx_run_diffusion(seed=42)
            handler._mlx_vae_decode(None)
        snapshot = trace.snapshot()
        self.assertEqual(snapshot['components']['dit']['successful_backends'], ['mlx'])
        self.assertEqual(snapshot['components']['vae']['successful_backends'], ['mlx'])
        self.assertEqual(snapshot['components']['planner']['status'], 'not_requested')
        self.assertTrue(all(call['attempted'] <= 1 for call in snapshot['calls']))

    def test_restores_hooks_on_exception_and_resets_each_variation(self):
        handler = Handler()
        with self.assertRaises(KeyboardInterrupt):
            with ACEExecutionTrace(handler, None):
                handler.vae.decode(None)
                raise KeyboardInterrupt()
        self.assertNotIn('decode', vars(handler.vae))
        with ACEExecutionTrace(handler, None) as trace:
            for _ in range(1000):
                handler.vae.decode(None)
        calls = trace.snapshot()['calls']
        self.assertEqual(len(calls), 4)
        self.assertEqual(next(call['succeeded'] for call in calls if call['method'] == 'decode'), 1000)

    def test_missing_or_unpatchable_hooks_stay_unknown(self):
        with ACEExecutionTrace(object(), object()) as trace:
            pass
        snapshot = trace.snapshot()
        self.assertTrue(snapshot['unavailable_hooks'])
        self.assertTrue(all(value['status'] == 'unknown' for value in snapshot['components'].values()))

    @unittest.skipUnless(importlib.util.find_spec('torch') and importlib.util.find_spec('acestep'),
                         'run with .venv-ace for pinned upstream decode paths')
    def test_installed_decode_fallback_and_tiling_emit_actual_calls_without_weights(self):
        import torch
        package = importlib.util.find_spec('acestep')
        path = Path(package.origin).parent / 'core/generation/handler/generate_music_decode.py'
        spec = importlib.util.spec_from_file_location('micromix_decode_under_test', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        tiled_spec = importlib.util.spec_from_file_location('micromix_tiled_under_test', path.with_name('vae_decode.py'))
        tiled_module = importlib.util.module_from_spec(tiled_spec)
        tiled_spec.loader.exec_module(tiled_module)

        class Decoder:
            dtype = torch.float32

            def decode(self, latents):
                if str(latents.device) == 'mps':
                    raise RuntimeError('simulated MPS failure; no accelerator execution')
                return SimpleNamespace(sample=torch.zeros(1, 2, 8))

            def parameters(self):
                yield SimpleNamespace(device='cpu', dtype=torch.float32)

            def cpu(self):
                return self

            def float(self):
                return self

            def to(self, *args):
                return self

        class Host(module.GenerateMusicDecodeMixin, tiled_module.VaeDecodeMixin):
            device = 'cpu'
            use_mlx_vae = True
            mlx_vae = object()
            current_offload_cost = 0

            def __init__(self):
                self.vae = Decoder()

            def _load_model_context(self, name):
                return nullcontext()

            def _empty_cache(self):
                pass

            def _memory_allocated(self):
                return 0

            def _max_memory_allocated(self):
                return 0

            def _mlx_vae_decode(self, latents):
                raise RuntimeError('synthetic fallback')

            def _get_auto_decode_chunk_size(self):
                return 32

            def _should_offload_wav_to_cpu(self):
                return False

            def _tiled_decode_inner(self, latents, *args):
                # Simulate an accelerator failure at the chunk boundary, while
                # running upstream's real tiled policy and CPU fallback. No MPS
                # tensors, weights, or model inference are used by this test.
                return self.vae.decode(SimpleNamespace(device='mps')).sample

        for tiled in (False, True):
            with self.subTest(tiled=tiled):
                host = Host()
                host.device = 'mps' if tiled else 'cpu'
                with ACEExecutionTrace(host, None) as trace:
                    host._decode_generate_music_pred_latents(
                        torch.zeros(1, 2, 3), None, tiled, {'total_time_cost': 0})
                snapshot = trace.snapshot()
                self.assertEqual(snapshot['components']['vae']['successful_backends'], ['pytorch'])
                self.assertTrue(host.use_mlx_vae)  # This flag alone would misreport MLX.
                attempts = {entry['backend']: entry for entry in snapshot['calls'] if entry['component'] == 'vae'}
                self.assertEqual(attempts['mlx']['failed'], 1)
                self.assertEqual(attempts['pytorch']['successful_input_devices'], ['cpu'])
                self.assertEqual(attempts['pytorch']['failed_input_devices'], ['mps'] if tiled else [])
                self.assertEqual(attempts['pytorch']['failed'], 1 if tiled else 0)

    @unittest.skipUnless(importlib.util.find_spec('torch'), 'run with .venv-ace for Torch module hooks')
    def test_torch_module_method_hooks_restore_descriptors_without_weights(self):
        from torch import nn

        class Decoder(nn.Module):
            def decode(self, value):
                return value

        handler = Handler()
        handler.vae = Decoder()
        with ACEExecutionTrace(handler, None) as trace:
            self.assertEqual(handler.vae.decode(42), 42)
        self.assertNotIn('decode', vars(handler.vae))
        self.assertEqual(trace.snapshot()['components']['vae']['successful_backends'], ['pytorch'])
