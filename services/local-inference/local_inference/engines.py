"""Disposable local model adapters. Heavy libraries are imported only in workers.

API source revisions and manual setup are documented in ../MODELS.md.
"""
from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
from pathlib import Path

# Runtime workers may load only artifacts already present in the local model cache.
# Model setup is an explicit, separate network operation.
os.environ.setdefault('HF_HUB_OFFLINE', '1')
os.environ.setdefault('HF_HUB_DISABLE_TELEMETRY', '1')

ACE_REVISION = 'ca1e85fe9430179831e6bc6be790c332190a3866'
MUSCRIPTOR_REVISION = '7f213afecf23bd6a1b8672aa223690ee9807cefb'
MLX_AUDIO_REVISION = '40b27a2157150bf87a1f25958f049bdcd0861235'
RVC_REVISION = 'f26633539f1aa935337d8ca5e96c78784698bd7a'
TRANSCRIPTION_INSTRUMENTS = (
    'acoustic_piano', 'electric_piano', 'chromatic_percussion', 'organ',
    'acoustic_guitar', 'clean_electric_guitar', 'distorted_electric_guitar',
    'acoustic_bass', 'electric_bass', 'violin', 'viola', 'cello', 'contrabass',
    'orchestral_harp', 'timpani', 'string_ensemble', 'synth_strings', 'voice',
    'orchestra_hit', 'trumpet', 'trombone', 'tuba', 'french_horn', 'brass_section',
    'soprano_and_alto_sax', 'tenor_sax', 'baritone_sax', 'oboe', 'english_horn',
    'bassoon', 'clarinet', 'flutes', 'synth_lead', 'synth_pad', 'drums',
)


def _output(path: Path, name: str, media_type: str = 'audio/wav') -> dict:
    return {'path': str(path.resolve()), 'filename': path.name,
            'media_type': media_type, 'name': name}


def _source(manifest: dict) -> str:
    source = manifest['parameters'].get('source_path')
    if source is None:
        source = next((item['path'] for item in manifest.get('inputs', [])
                       if item.get('name') in ('source', 'reference')), None)
    if not source or not Path(source).is_file():
        raise ValueError('A resolved local source audio file is required')
    return str(source)


def variation_seeds(parameters: dict) -> list[int]:
    count = parameters.get('variation_count', 1)
    if not isinstance(count, int) or not 1 <= count <= 4:
        raise ValueError('variation_count must be between 1 and 4')
    seed = parameters.get('seed')
    seeds = parameters.get('seeds')
    if seeds is None:
        if not isinstance(seed, int) or not 0 <= seed <= 0xFFFFFFFF:
            raise ValueError('A persisted unsigned 32-bit seed is required')
        seeds = [(seed + offset) % (2**32) for offset in range(count)]
    if len(seeds) != count or any(type(s) is not int or not 0 <= s <= 0xFFFFFFFF for s in seeds):
        raise ValueError('Persisted seeds must match variation_count')
    return seeds


def _load_ace(preset: str, thinking: bool):
    from acestep.handler import AceStepHandler
    from acestep.llm_inference import LLMHandler
    from acestep.inference import GenerationParams, GenerationConfig, generate_music

    root = Path(os.environ.get('MICROMIX_ACE_ROOT', '~/.cache/micromix/ace')).expanduser()
    checkpoints = Path(os.environ.get('ACESTEP_CHECKPOINTS_DIR', root / 'checkpoints')).expanduser()
    dit = AceStepHandler()
    model = 'acestep-v15-xl-turbo' if preset == 'turbo' else 'acestep-v15-xl-sft'
    message, success = dit.initialize_service(project_root=str(root), config_path=model,
        device='mps', use_flash_attention=False, compile_model=False, use_mlx_dit=True)
    if not success:
        raise RuntimeError(f'ACE-Step initialization failed: {message}. See services/local-inference/MODELS.md')
    lm = None
    if thinking:
        lm = LLMHandler()
        message, success = lm.initialize(checkpoint_dir=str(checkpoints),
            lm_model_path='acestep-5Hz-lm-4B', backend='pt', device='mps')
        if not success:
            raise RuntimeError(f'ACE-Step 4B planner initialization failed: {message}. See services/local-inference/MODELS.md')
    return dit, lm, GenerationParams, GenerationConfig, generate_music


def _ace(manifest: dict, directory: Path) -> dict:
    p = manifest['parameters']
    operation = manifest['operation']
    thinking = operation in ('generation', 'reference-generation')
    dit, lm, Params, Config, generate = _load_ace(p.get('preset', 'turbo'), thinking)
    task = {'generation': 'text2music', 'reference-generation': 'text2music',
            'remix': 'cover', 'repaint': 'repaint'}[operation]
    seeds = variation_seeds(p)
    outputs = []
    instrumental = operation == 'generation' and not p.get('lyrics')
    lyrics = p.get('lyrics') or ('[Instrumental]' if instrumental else '')
    for position, seed in enumerate(seeds):
        destination = directory / f'variation-{position + 1}'
        destination.mkdir(parents=True, exist_ok=True)
        params = Params(task_type=task, caption=p.get('prompt', ''), lyrics=lyrics,
            instrumental=instrumental, bpm=p.get('bpm'), keyscale=p.get('key') or '',
            timesignature=str(p.get('time_signature') or '').split('/')[0],
            vocal_language=p.get('vocal_language') or 'unknown', duration=p.get('duration_seconds', 30),
            inference_steps=8 if p.get('preset', 'turbo') == 'turbo' else 50, seed=seed,
            reference_audio=_source(manifest) if operation == 'reference-generation' else None,
            src_audio=_source(manifest) if operation in ('remix', 'repaint') else None,
            audio_cover_strength=p.get('source_strength', p.get('strength', p.get('audio_cover_strength', 1.0))),
            repaint_strength=p.get('repaint_strength', 0.5),
            repainting_start=p.get('start_seconds', 0), repainting_end=p.get('end_seconds', -1),
            thinking=thinking, use_cot_metas=thinking, use_cot_caption=thinking, use_cot_language=thinking)
        config = Config(batch_size=1, use_random_seed=False, seeds=[seed], audio_format='wav')
        result = generate(dit, lm, params, config, save_dir=str(destination))
        if not result.success or len(result.audios) != 1:
            raise RuntimeError(f'ACE-Step generation failed: {getattr(result, "error", None)}')
        produced = Path(result.audios[0]['path'])
        target = directory / f'variation-{position + 1}.wav'
        shutil.copyfile(produced, target)
        outputs.append(_output(target, f'variation-{position + 1}'))
    return {'outputs': outputs, 'provenance': {'engine': 'ace-step', 'revision': ACE_REVISION,
            'seeds': seeds, 'planner': 'acestep-5Hz-lm-4B' if thinking else None}}


def _decode_audio(source: str, directory: Path) -> Path:
    """Use ffmpeg for WAV/MP3/M4A/FLAC/OGG consistently, without a shell."""
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise RuntimeError('ffmpeg is required; install it with brew install ffmpeg')
    target = directory / 'decoded-source.wav'
    subprocess.run([ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
                    '-i', source, '-vn', '-ac', '1', '-ar', '16000', str(target)], check=True)
    return target


def _load_muscriptor():
    from muscriptor import TranscriptionModel
    return TranscriptionModel.load_model(os.environ.get('MICROMIX_MUSCRIPTOR_MODEL', 'medium'), device='mps')


def _transcription(manifest: dict, directory: Path) -> dict:
    p = manifest['parameters']
    instruments = p.get('instruments')
    if instruments in ([], ['all']):
        instruments = None
    if instruments and any(i not in TRANSCRIPTION_INSTRUMENTS for i in instruments):
        raise ValueError('Unknown MuScriptor instrument group')
    audio = _decode_audio(_source(manifest), directory)
    model = _load_muscriptor()
    midi, grid = model.transcribe_and_postprocess(audio=str(audio), instruments=instruments,
        detect_tempo=p.get('detect_tempo', 'best-effort'))
    target = directory / 'transcription.mid'
    target.write_bytes(midi)
    return {'outputs': [_output(target, 'midi', 'audio/midi')], 'provenance': {
        'engine': 'muscriptor', 'revision': MUSCRIPTOR_REVISION,
        'tempo_detected': grid is not None}}


def _load_rvc(model_path: str):
    from mlx_rvc import RVCPipeline
    return RVCPipeline.from_pretrained(model_path)


def _vocal_swap(manifest: dict, directory: Path) -> dict:
    p = manifest['parameters']
    model_path = p.get('model_path')
    if not model_path or not Path(model_path).is_file():
        raise ValueError('A resolved private voice model is required')
    index = p.get('index_path')
    if index and not Path(index).is_file():
        raise ValueError('Selected voice index does not exist')
    if p.get('index_rate', 0) > 0 and not index:
        raise ValueError('index_rate requires a selected voice index')
    for selected, revision in ((model_path, p.get('model_revision')),
                               (index, p.get('voice_index_revision'))):
        if selected and revision:
            with Path(selected).open('rb') as stream:
                actual = 'sha256:' + hashlib.file_digest(stream, 'sha256').hexdigest()
            if actual != revision:
                raise ValueError('Selected voice model or index changed since submission; submit again')
    pipeline = _load_rvc(model_path)
    target = directory / 'vocal-swap.wav'
    pipeline.convert(input_path=_source(manifest), output_path=str(target),
        f0_shift=p.get('pitch_shift', 0), f0_method='rmvpe',
        index_path=index, index_rate=p.get('index_rate', 0))
    return {'outputs': [_output(target, 'vocals')], 'provenance': {
        'engine': 'mlx-rvc', 'revision': RVC_REVISION, 'model_revision': p.get('model_revision'),
        'voice_index_revision': p.get('voice_index_revision')}}


def _load_sam():
    from mlx_audio.sts import SAMAudio, SAMAudioProcessor, save_audio
    model_id = 'mlx-community/sam-audio-large'
    return SAMAudio.from_pretrained(model_id), SAMAudioProcessor.from_pretrained(model_id), save_audio


def _stem_split(manifest: dict, directory: Path) -> dict:
    model, processor, save = _load_sam()
    p = manifest['parameters']
    batch = processor(descriptions=[p['description']], audios=[_source(manifest)])
    result = model.separate_long(audios=batch.audios, descriptions=batch.descriptions,
        chunk_seconds=10.0, overlap_seconds=3.0, ode_decode_chunk_size=50, seed=p.get('seed', 42))
    outputs = []
    for name, arrays in (('target', result.target), ('residual', result.residual)):
        if len(arrays) != 1:
            raise RuntimeError(f'SAM-Audio did not produce {name}')
        target = directory / f'{name}.wav'
        save(arrays[0], str(target), sample_rate=model.sample_rate)
        outputs.append(_output(target, name))
    return {'outputs': outputs, 'provenance': {'engine': 'sam-audio', 'revision': MLX_AUDIO_REVISION}}


def stt_text(result) -> str | None:
    """Whisper returns STTOutput, not an iterable of segments."""
    text = getattr(result, 'text', None)
    return text.strip() or None if isinstance(text, str) else None


def _minimax(manifest: dict, directory: Path) -> dict:
    p = manifest['parameters']
    if manifest['operation'] != 'generation':
        raise ValueError('MiniMax supports basic generation only; use turbo or quality for Reimagine')
    if any(p.get(field) is not None for field in ('bpm', 'key', 'time_signature', 'vocal_language')):
        raise ValueError('MiniMax does not support musical metadata controls')
    if p.get('variation_count', 1) != 1:
        raise ValueError('MiniMax supports one variation')
    from mlx_audio.music.utils import load_model
    from mlx_audio.audio_io import write
    import mlx.core as mx
    model = load_model('mlx-community/MiniMax-Music3-mxfp8')
    chunks = list(model.generate(text=p['prompt'], lyrics=p.get('lyrics') or '[instrumental]',
        duration=p.get('duration_seconds', 30), seed=variation_seeds(p)[0], steps=30))
    if not chunks:
        raise RuntimeError('MiniMax produced no audio')
    target = directory / 'generation.wav'
    audio = chunks[0].audio if len(chunks) == 1 else mx.concatenate([c.audio for c in chunks], axis=0)
    write(target, audio, chunks[0].sample_rate)
    return {'outputs': [_output(target, 'output')], 'provenance': {'engine': 'minimax', 'revision': MLX_AUDIO_REVISION}}


def run_manifest(manifest: dict) -> dict:
    directory = Path(manifest['output_dir']).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    operation = manifest['operation']
    try:
        if operation in ('generation', 'reference-generation', 'remix', 'repaint'):
            preset = manifest['parameters'].get('preset', 'turbo')
            if preset == 'minimax-cover':
                return _minimax(manifest, directory)
            if preset not in ('turbo', 'quality'):
                raise ValueError(f'Unknown generation preset: {preset}')
            return _ace(manifest, directory)
        adapter = {'transcription': _transcription, 'vocal-swap': _vocal_swap, 'stem-split': _stem_split}.get(operation)
        if adapter is None:
            raise ValueError(f'Unknown operation: {operation}')
        return adapter(manifest, directory)
    except ImportError as exc:
        engine = 'muscriptor' if operation == 'transcription' else ('ace' if operation in ('generation', 'reference-generation', 'remix', 'repaint') and manifest['parameters'].get('preset') != 'minimax-cover' else 'mlx')
        raise RuntimeError(f'Missing local model dependency ({exc}). Run bash scripts/setup-local-models.sh --engine {engine}; see services/local-inference/MODELS.md') from exc
