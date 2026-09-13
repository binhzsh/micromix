from basic_pitch.inference import predict
import os

model_output, midi_data, note_events = predict(
    "/Users/binh/Projects/micromix/services/local-inference/data/test_minimax.wav",
    "/Users/binh/Projects/micromix/services/local-inference/.venv/lib/python3.12/site-packages/basic_pitch/saved_models/icassp_2022/nmp.onnx",
    onset_threshold=0.4,
    frame_threshold=0.3,
    minimum_note_length=100.0,
)

os.makedirs("/Users/binh/Projects/micromix/services/local-inference/data/basic_pitch_out", exist_ok=True)
midi_data.write("/Users/binh/Projects/micromix/services/local-inference/data/basic_pitch_out/mix.mid")
print("MIDI saved, notes:", len(note_events))
for n in note_events[:5]:
    print("  ", n)
