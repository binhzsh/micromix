from mlx_audio.sts import SAMAudio, SAMAudioProcessor, save_audio

processor = SAMAudioProcessor.from_pretrained("mlx-community/sam-audio-large")
model = SAMAudio.from_pretrained("mlx-community/sam-audio-large")

batch = processor(
    descriptions=["speech"],
    audios=["/Users/binh/Projects/micromix/services/local-inference/data/test_minimax.wav"],
)

result = model.separate_long(
    audios=batch.audios,
    descriptions=batch.descriptions,
    chunk_seconds=10.0,
    overlap_seconds=3.0,
    ode_decode_chunk_size=50,
)

save_audio(result.target[0], "/Users/binh/Projects/micromix/services/local-inference/data/stem_vocals.wav", sample_rate=model.sample_rate)
save_audio(result.residual[0], "/Users/binh/Projects/micromix/services/local-inference/data/stem_accompaniment.wav", sample_rate=model.sample_rate)
print("vocal stem saved, residual saved")
print("peak memory GB:", result.peak_memory)
