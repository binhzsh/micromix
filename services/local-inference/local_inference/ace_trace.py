"""Bounded call-boundary diagnostics for the pinned ACE adapter.

Instance-local hooks live only around one synchronous generation call in a
serial disposable worker. No tensors, prompts or exception text are retained.
This observes component entry points, NOT Metal kernels or internal bridges.
"""
from contextlib import ExitStack
from functools import wraps


class ACEExecutionTrace:
    def __init__(self, dit, lm):
        self.dit = dit
        self.lm = lm
        self.calls = {}
        self.unavailable = []
        self._restorations = ExitStack()

    def __enter__(self):
        self._hook(self.dit, '_mlx_run_diffusion', 'dit', 'mlx')
        self._hook(getattr(self.dit, 'model', None), 'generate_audio', 'dit', 'pytorch')
        self._hook(self.dit, '_mlx_vae_decode', 'vae', 'mlx')
        self._hook(getattr(self.dit, 'vae', None), 'decode', 'vae', 'pytorch')
        if self.lm is not None:
            # Only the PT planner is enabled by our pinned adapter. Do not infer
            # execution for a future planner with a different calling convention.
            if getattr(self.lm, 'llm_backend', None) == 'pt':
                self._hook(getattr(self.lm, 'llm', None), 'generate', 'planner', 'pytorch')
            else:
                self.unavailable.append('planner.generate')
        return self

    def __exit__(self, *exc):
        self._restorations.close()

    def _hook(self, target, name, component, backend):
        label = f'{component}.{backend}.{name}'
        original = getattr(target, name, None)
        if not callable(original) or not hasattr(target, '__dict__'):
            self.unavailable.append(label)
            return
        own_attribute = name in vars(target)
        own_value = vars(target).get(name)
        entry = {'component': component, 'backend': backend, 'method': name,
                 'attempted': 0, 'succeeded': 0, 'failed': 0,
                 'successful_input_devices': [], 'failed_input_devices': []}

        @wraps(original)
        def observe(*args, **kwargs):
            entry['attempted'] += 1
            # Device of an observed input is evidence, not a handler preference.
            values = args + tuple(kwargs.get(key) for key in ('latents', 'input_ids', 'src_latents'))
            devices = []
            for value in values:
                device = getattr(value, 'device', None)
                if device is not None:
                    device = str(device)
                    if device not in devices and len(devices) < 8:
                        devices.append(device)
            try:
                result = original(*args, **kwargs)
            except BaseException:
                entry['failed'] += 1
                self._record_devices(entry['failed_input_devices'], devices)
                raise
            entry['succeeded'] += 1
            self._record_devices(entry['successful_input_devices'], devices)
            return result

        try:
            setattr(target, name, observe)
        except (AttributeError, TypeError):
            self.unavailable.append(label)
            return
        self.calls[label] = entry

        def restore():
            if own_attribute:
                setattr(target, name, own_value)
            else:
                delattr(target, name)
        self._restorations.callback(restore)

    @staticmethod
    def _record_devices(destination, devices):
        for device in devices:
            if device not in destination and len(destination) < 8:
                destination.append(device)

    def snapshot(self):
        components = {}
        for component in ('dit', 'vae', 'planner'):
            if component == 'planner' and self.lm is None:
                components[component] = {'status': 'not_requested', 'successful_backends': []}
                continue
            successful = sorted({entry['backend'] for entry in self.calls.values()
                                 if entry['component'] == component and entry['succeeded']})
            components[component] = {'status': 'observed' if successful else 'unknown',
                                     'successful_backends': successful}
        return {'evidence': 'component-call-boundaries', 'components': components,
                'calls': [dict(entry, successful_input_devices=list(entry['successful_input_devices']),
                               failed_input_devices=list(entry['failed_input_devices']))
                          for entry in self.calls.values()],
                'unavailable_hooks': list(self.unavailable)}
