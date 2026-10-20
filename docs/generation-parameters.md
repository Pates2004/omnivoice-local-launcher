# Generation Parameters

Parameters can be passed as keyword arguments to `model.generate(...)` or via the `OmniVoiceGenerationConfig` dataclass. See below for the full list and which category each belongs to.

```python
# 1) Direct keyword arguments
audio = model.generate(text="Hello world", num_step=32, guidance_scale=2.0)

# 2) Via OmniVoiceGenerationConfig dataclass
from omnivoice import OmniVoiceGenerationConfig

config = OmniVoiceGenerationConfig(num_step=32, guidance_scale=2.0)
audio = model.generate(text="Hello world", generation_config=config)
```

## Decoding

| Parameter | Type | Default | Description |
|---|---|---|---|
| `num_step` | int | 32 | Number of iterative unmasking steps. Higher values improve quality but slow down generation. Use 16 for faster inference. |
| `denoise` | bool | True | Prepend the `<|denoise|>` token to the input, which signals the model to produce cleaner speech. |
| `guidance_scale` | float | 2.0 | Classifier-free guidance scale.|
| `t_shift` | float | 0.1 | Time-step shift for the noise schedule. Smaller values emphasise earlier steps in decoding. |

## Sampling

| Parameter | Type | Default | Description |
|---|---|---|---|
| `position_temperature` | float | 5.0 | Temperature for mask-position selection. 0 = greedy (deterministic). Higher values increase randomness. |
| `class_temperature` | float | 0.0 | Temperature for token sampling at each step. 0 = greedy (deterministic). Higher values increase randomness. |
| `layer_penalty_factor` | float | 5.0 | Penalty applied to deeper codebook layers, encouraging earlier (lower) layers to unmask first. |

## Duration & Speed

These accept a single value applied to all items, or a per-item list (useful in batch mode):

```python
# Request a 10-second conditioning budget
audio = model.generate(text="Hello, this is a test of duration control", duration=10.0)

# Faster speech (1.2x faster than estimated)
audio = model.generate(text="Hello, this is a test of duration control", speed=1.2)
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `duration` | float or list[float \| None] | None | Requested duration in seconds, quantized to codec frames. Overrides `speed` when set. |
| `speed` | float or list[float \| None] | None | Speed factor. Values > 1.0 produce shorter audio (faster); values < 1.0 produce longer audio (slower). Ignored when `duration` is set. Defaults to 1.0 when both are None. |

Priority: `duration` > `speed`.

The duration budget is shared across all long-form chunks; it is not applied
again to each chunk. Final waveform length can still differ because of codec
quantization, interchunk silence, edge padding, and optional silence removal.
`postprocess_output=False` disables silence removal, but does not disable chunk
joins or padding. For an unchunked, unpadded result, also set
`audio_chunk_duration=0` and `pad_duration=0`. No speech is cropped or stretched
to enforce a duration. A chunked request too short to allocate at least one codec
frame per chunk raises an error; increase duration or chunk size instead.

Po polsku: zadany czas jest wspólnym budżetem wszystkich fragmentów, nie czasem
każdego z nich osobno. Przerwy między fragmentami, marginesy ciszy, zaokrąglenie
do ramek kodeka i usuwanie ciszy mogą zmienić długość końcowego pliku. Samo
wyłączenie przetwarzania końcowego nie gwarantuje dokładnej długości. Program
nie ucina ani nie rozciąga wypowiedzi, aby wymusić zadany czas.

## Pre/Post Processing

| Parameter | Type | Default | Description |
|---|---|---|---|
| `preprocess_prompt` | bool | True | Whether to apply preprocessing to the voice-clone prompt audio (remove long silences in reference audio, add punctuation in the end of reference text). |
| `postprocess_output` | bool | True | Apply post-processing to generated audio (remove long silences). |
| `pad_duration` | float | 0.1 | Silence padding duration per side in seconds. Set to 0 to disable. |
| `fade_duration` | float | 0.1 | Fade-in/out curve duration in seconds. Set to 0 to disable. |

## Long-Form Generation

When estimated duration exceeds `audio_chunk_threshold`, text is split into
segments targeting `audio_chunk_duration`. Punctuation is preferred, with word
boundaries and a bounded fallback for long words or unpunctuated text. Bracketed
pronunciation/control spans stay intact and may exceed the soft text limit.
Chunking bounds per-call model memory; the complete output still needs host
memory. For automatic/designed voices, the first generated chunk conditions later
chunks without applying speaking speed a second time.

| Parameter | Type | Default | Description |
|---|---|---|---|
| `audio_chunk_duration` | float | 15.0 | Target chunk duration (seconds) when splitting long text. |
| `audio_chunk_threshold` | float | 30.0 | Estimated audio duration (seconds) above which chunking is activated. |
