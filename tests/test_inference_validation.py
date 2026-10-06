"""Inference boundary regressions without model weights or accelerator hardware."""

import ast
import importlib.util
import io
import math
import unittest
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


class TensorStub:
    def __init__(self, values, dtype="int64", layout="strided", device="cpu"):
        self.values = np.asarray(values)
        self.dtype = dtype
        self.layout = layout
        self.device = SimpleNamespace(type=device)
        self.ndim = self.values.ndim
        self.shape = self.values.shape
        self.to = Mock(return_value=self)

    def numel(self):
        return self.values.size

    def min(self):
        return self.values.min()

    def max(self):
        return self.values.max()

    def __eq__(self, other):
        return self.values == other


def engine_namespace(torch_module=None):
    if torch_module is None:
        torch_module = SimpleNamespace(
            Tensor=TensorStub,
            strided="strided",
            uint8="uint8",
            int8="int8",
            int16="int16",
            int32="int32",
            int64="int64",
            load=Mock(),
            save=Mock(),
        )
    source = ROOT / "omnivoice/models/omnivoice.py"
    tree = ast.parse(source.read_text(encoding="utf-8"))
    names = {
        "_validate_audio_tokens",
        "_validate_generated_audio",
        "VoiceClonePrompt",
        "_prepare_inference_inputs",
        "_decode_and_post_process",
        "_post_process_audio",
    }
    nodes = [
        node
        for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names
    ]
    module = ast.Module(
        body=[ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)]
        + nodes,
        type_ignores=[],
    )
    namespace = dict(
        __name__=__name__,
        torch=torch_module,
        np=np,
        math=math,
        dataclass=dataclass,
        _VOICE_CLONE_PROMPT_FORMAT_VERSION=1,
        remove_silence=Mock(side_effect=lambda audio, *args, **kwargs: np.nan_to_num(audio)),
        fade_and_pad_audio=Mock(side_effect=lambda audio, **kwargs: audio),
        cross_fade_chunks=Mock(side_effect=lambda chunks, rate: np.concatenate(chunks, axis=-1)),
    )
    exec(compile(ast.fix_missing_locations(module), str(source), "exec"), namespace)
    return namespace


class PromptValidationTests(unittest.TestCase):
    def setUp(self):
        self.engine = engine_namespace()
        self.torch = self.engine["torch"]
        self.prompt_type = self.engine["VoiceClonePrompt"]
        self.tokens = TensorStub(np.ones((8, 3), dtype=np.int64))
        self.payload = dict(
            format_version=1, ref_audio_tokens=self.tokens, ref_text="", ref_rms=0.0
        )

    def load(self, payload):
        self.torch.load.return_value = payload
        return self.prompt_type.load("preset.pt", map_location="cuda:0")

    def test_valid_prompt_keeps_empty_transcript_and_loads_on_cpu_before_transfer(self):
        prompt = self.load(self.payload)
        self.torch.load.assert_called_once_with("preset.pt", map_location="cpu", weights_only=True)
        self.tokens.to.assert_called_once_with("cuda:0")
        self.assertEqual(prompt.ref_text, "")
        self.assertEqual(prompt.ref_rms, 0.0)

    def test_bad_schema_is_rejected_before_transfer(self):
        for payload in (
            [],
            None,
            dict(self.payload, format_version=True),
            dict(self.payload, format_version=2),
            {key: value for key, value in self.payload.items() if key != "ref_text"},
        ):
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                self.load(payload)
        self.tokens.to.assert_not_called()

    def test_non_tensor_and_non_integer_tokens_are_rejected(self):
        for tokens in (
            [[1, 2]],
            TensorStub([[1.5]], dtype="float32"),
            TensorStub([[1]], dtype="bool"),
            TensorStub([[1]], layout="sparse"),
            TensorStub([[1]], device="meta"),
        ):
            with self.subTest(tokens=tokens), self.assertRaises(ValueError):
                self.load(dict(self.payload, ref_audio_tokens=tokens))
            if isinstance(tokens, TensorStub):
                tokens.to.assert_not_called()

    def test_empty_wrong_rank_and_negative_tokens_are_rejected(self):
        for values in ([], [1, 2], np.zeros((8, 0)), np.zeros((8, 2, 1)), [[-1]]):
            tokens = TensorStub(values)
            with self.subTest(shape=tokens.shape), self.assertRaises(ValueError):
                self.load(dict(self.payload, ref_audio_tokens=tokens))
            tokens.to.assert_not_called()

    def test_invalid_metadata_is_rejected_before_transfer(self):
        for key, values in (
            ("ref_text", (None, 7, ["reference"])),
            ("ref_rms", (None, True, "0.1", -0.1, np.nan, np.inf, -np.inf)),
        ):
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    self.load(dict(self.payload, **{key: value}))
        self.tokens.to.assert_not_called()

    def test_invalid_prompt_cannot_be_saved(self):
        prompt = self.prompt_type(self.tokens, None, 0.1)
        with self.assertRaises(ValueError):
            prompt.save("preset.pt")
        self.torch.save.assert_not_called()

    def test_incompatible_tokens_fail_before_tokenization_or_device_transfer(self):
        model = SimpleNamespace(
            config=SimpleNamespace(num_audio_codebook=8, audio_vocab_size=1025, audio_mask_id=1024),
            text_tokenizer=Mock(),
        )
        prepare = self.engine["_prepare_inference_inputs"]
        for tokens in (
            TensorStub(np.ones((7, 2))),
            TensorStub(np.full((8, 2), 1024)),
            TensorStub(np.full((8, 2), 1000000)),
            TensorStub(np.full((8, 2), -1)),
        ):
            with self.subTest(values=tokens.values), self.assertRaises(ValueError):
                prepare(model, "Hello.", 10, ref_text="", ref_audio_tokens=tokens)
            tokens.to.assert_not_called()
        model.text_tokenizer.assert_not_called()

    def test_compatible_token_range_and_integer_dtypes_remain_supported(self):
        validate = self.engine["_validate_audio_tokens"]
        for dtype in ("uint8", "int8", "int16", "int32", "int64"):
            with self.subTest(dtype=dtype):
                validate(TensorStub([[0, 1]], dtype=dtype), 1, 1025, 1024)
        validate(TensorStub([[0, 1023]]), 1, 1025, 1024)


class OutputValidationTests(unittest.TestCase):
    def setUp(self):
        self.engine = engine_namespace()
        self.model = SimpleNamespace(sampling_rate=24000)
        self.config = SimpleNamespace(postprocess_output=True, pad_duration=0.0, fade_duration=0.0)

    def test_nonfinite_decoded_audio_is_rejected_before_pcm_conversion(self):
        for enabled in (False, True):
            self.config.postprocess_output = enabled
            for value in (np.nan, np.inf, -np.inf):
                samples = np.array([[0.25, value, -0.25]], dtype=np.float32)
                with self.subTest(enabled=enabled, value=value), self.assertRaises(ValueError):
                    self.engine["_post_process_audio"](self.model, samples, None, self.config)
        self.engine["remove_silence"].assert_not_called()
        self.engine["fade_and_pad_audio"].assert_not_called()

    def test_empty_or_non_mono_output_is_rejected(self):
        for samples in (
            [],
            [0.25],
            np.zeros((1, 0)),
            np.zeros((2, 3)),
            [["invalid"]],
            [[1j]],
            [[True]],
        ):
            with self.subTest(samples=samples), self.assertRaises(ValueError):
                self.engine["_post_process_audio"](self.model, samples, None, self.config)
        self.engine["remove_silence"].assert_not_called()

    def test_empty_output_after_silence_removal_has_a_clear_error(self):
        self.engine["remove_silence"].side_effect = lambda audio, *args, **kwargs: audio[:, :0]
        with self.assertRaisesRegex(ValueError, "finite, non-empty mono"):
            self.engine["_post_process_audio"](self.model, np.ones((1, 10)), None, self.config)

    def test_valid_audio_keeps_existing_peak_normalization(self):
        audio = np.array([[0.25, -0.25]], dtype=np.float32)
        result = self.engine["_post_process_audio"](self.model, audio, None, self.config)
        np.testing.assert_array_equal(result, [[0.5, -0.5]])
        np.testing.assert_array_equal(audio, [[0.25, -0.25]])

    def test_each_decoded_chunk_is_checked_before_crossfade(self):
        for value in (np.nan, np.inf, -np.inf):
            decoded = Mock()
            decoded.cpu.return_value.numpy.return_value = np.array([[value, 0.25]])
            tokenizer = SimpleNamespace(
                device="cpu", decode=Mock(return_value=SimpleNamespace(audio_values=[decoded]))
            )
            model = SimpleNamespace(audio_tokenizer=tokenizer, sampling_rate=24000)
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.engine["_decode_and_post_process"](model, [Mock()], None, self.config)
        self.engine["cross_fade_chunks"].assert_not_called()

    def test_empty_chunk_list_is_rejected(self):
        model = SimpleNamespace(audio_tokenizer=SimpleNamespace(device="cpu"))
        with self.assertRaisesRegex(ValueError, "No audio chunks"):
            self.engine["_decode_and_post_process"](model, [], None, self.config)


@unittest.skipUnless(importlib.util.find_spec("pydub"), "Optional real PCM conversion validation")
class PcmConversionTests(unittest.TestCase):
    def test_invalid_samples_cannot_be_hidden_by_real_silence_processing(self):
        from pydub import AudioSegment
        from pydub.silence import detect_leading_silence, split_on_silence

        engine = engine_namespace()
        engine.update(
            AudioSegment=AudioSegment,
            detect_leading_silence=detect_leading_silence,
            split_on_silence=split_on_silence,
        )
        source = ROOT / "omnivoice/utils/audio.py"
        names = {
            "numpy_to_audiosegment",
            "audiosegment_to_numpy",
            "remove_silence_edges",
            "remove_silence",
            "fade_and_pad_audio",
        }
        nodes = [
            node
            for node in ast.parse(source.read_text(encoding="utf-8")).body
            if isinstance(node, ast.FunctionDef) and node.name in names
        ]
        exec(compile(ast.Module(body=nodes, type_ignores=[]), str(source), "exec"), engine)
        config = SimpleNamespace(postprocess_output=True, pad_duration=0, fade_duration=0)
        model = SimpleNamespace(sampling_rate=24000)
        for value in (np.nan, np.inf, -np.inf):
            audio = np.full((1, 24000), 0.25, dtype=np.float32)
            audio[0, 12000] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                engine["_post_process_audio"](model, audio, None, config)
        valid = np.full((1, 24000), 0.25, dtype=np.float32)
        output = engine["_post_process_audio"](model, valid, None, config)
        self.assertEqual(output.shape, valid.shape)
        np.testing.assert_array_equal(output, 0.5)


@unittest.skipUnless(importlib.util.find_spec("torch"), "Optional real CPU tensor validation")
class SerializedPromptTests(unittest.TestCase):
    def setUp(self):
        import torch

        self.torch = torch
        self.engine = engine_namespace(torch)
        self.prompt_type = self.engine["VoiceClonePrompt"]

    def test_real_cpu_roundtrip_preserves_tokens_and_empty_transcript(self):
        tokens = self.torch.arange(16, dtype=self.torch.int64).reshape(8, 2)
        prompt = self.prompt_type(tokens, "", 0.125)
        buffer = io.BytesIO()
        prompt.save(buffer)
        buffer.seek(0)
        restored = self.prompt_type.load(buffer)
        self.assertTrue(self.torch.equal(restored.ref_audio_tokens, tokens))
        self.assertEqual(restored.ref_audio_tokens.device.type, "cpu")
        self.assertEqual(restored.ref_text, "")
        self.assertEqual(restored.ref_rms, 0.125)

    def test_real_serialized_bad_tokens_cannot_reach_an_unavailable_device(self):
        for tokens in (
            self.torch.full((8, 2), -1, dtype=self.torch.long),
            self.torch.full((8, 2), 1.5),
        ):
            buffer = io.BytesIO()
            self.torch.save(
                dict(format_version=1, ref_audio_tokens=tokens, ref_text="", ref_rms=0.1), buffer
            )
            buffer.seek(0)
            with self.subTest(dtype=tokens.dtype), self.assertRaises(ValueError):
                self.prompt_type.load(buffer, map_location="cuda:123")

    def test_real_cpu_token_bounds_are_checked_before_any_model_operation(self):
        validate = self.engine["_validate_audio_tokens"]
        for value in (-1, 1024, 1025, 1000000):
            with self.subTest(value=value), self.assertRaises(ValueError):
                validate(self.torch.full((8, 2), value), 8, 1025, 1024)
        validate(self.torch.full((8, 2), 1023), 8, 1025, 1024)


if __name__ == "__main__":
    unittest.main()
