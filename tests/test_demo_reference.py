"""Web UI and Whisper regressions without loading Gradio or neural network weights."""

import ast
import logging
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def load_function(relative_path, name, namespace):
    tree = ast.parse((ROOT / relative_path).read_text(encoding="utf-8"))
    method = next(n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name == name)
    method.decorator_list = []
    method.returns = None
    for arg in method.args.args:
        arg.annotation = None
    exec(compile(ast.Module(body=[method], type_ignores=[]), name, "exec"), namespace)
    return namespace[name]


class DemoTests(unittest.TestCase):
    def setUp(self):
        self.model = SimpleNamespace(
            create_voice_clone_prompt=Mock(return_value="prompt"),
            generate=Mock(return_value=[np.array([0.1, -0.2], dtype=np.float32)]),
        )
        self.generate = load_function(
            "omnivoice/cli/demo.py",
            "_gen_core",
            {
                "model": self.model,
                "np": np,
                "logging": logging,
                "sampling_rate": 24000,
                "OmniVoiceGenerationConfig": SimpleNamespace,
            },
        )
        self.args = dict(
            text=" Test. ",
            language="Auto",
            ref_audio="reference.wav",
            instruct=None,
            num_step=4,
            guidance_scale=2,
            denoise=True,
            speed=1,
            duration=None,
            preprocess_prompt=False,
            postprocess_output=True,
            mode="clone",
            ref_text="   ",
        )

    def test_clone_options_and_empty_transcript_are_forwarded(self):
        for preprocess in (False, True):
            result, status = self.generate(**dict(self.args, preprocess_prompt=preprocess))
            self.assertEqual(status, "Done.")
            self.assertEqual(result[0], 24000)
            self.model.create_voice_clone_prompt.assert_called_with(
                ref_audio="reference.wav",
                ref_text=None,
                preprocess_prompt=preprocess,
            )
            self.assertEqual(self.model.generate.call_args.kwargs["voice_clone_prompt"], "prompt")

    def test_manual_transcript_is_kept_and_trimmed(self):
        self.generate(**dict(self.args, ref_text=" My reference. "))
        self.assertEqual(
            self.model.create_voice_clone_prompt.call_args.kwargs["ref_text"], "My reference."
        )

    def test_clone_preparation_error_is_shown_in_status(self):
        self.model.create_voice_clone_prompt.side_effect = ValueError("bad reference")
        with self.assertLogs(level="ERROR"):
            audio, status = self.generate(**self.args)
        self.assertIsNone(audio)
        self.assertIn("bad reference", status)
        self.model.generate.assert_not_called()

    def test_loud_pcm_samples_saturate_instead_of_wrapping(self):
        self.model.generate.return_value = [np.array([-2, -1, 0, 1, 2])]
        audio, status = self.generate(**dict(self.args, mode="design"))
        np.testing.assert_array_equal(audio[1], [-32767, -32767, 0, 32767, 32767])
        self.assertEqual(audio[1].dtype, np.int16)
        self.assertEqual(status, "Done.")
        self.model.create_voice_clone_prompt.assert_not_called()

    def test_invalid_generated_audio_does_not_escape_handler(self):
        for samples in ([], [np.nan], [np.inf], [[0, 1], [1, 0]]):
            self.model.generate.return_value = [np.array(samples)]
            with self.assertLogs(level="ERROR"):
                audio, status = self.generate(**self.args)
            self.assertIsNone(audio)
            self.assertIn("Error: ValueError", status)

    def test_missing_input_does_not_call_model(self):
        for overrides in ({"text": " "}, {"ref_audio": None}):
            audio, status = self.generate(**dict(self.args, **overrides))
            self.assertIsNone(audio)
            self.assertIn("Please", status)
        self.model.create_voice_clone_prompt.assert_not_called()
        self.model.generate.assert_not_called()


class WhisperInputTests(unittest.TestCase):
    def setUp(self):
        self.pipe = Mock(return_value={"text": " full transcript "})
        self.holder = SimpleNamespace(_asr_pipe=self.pipe)
        self.transcribe = load_function(
            "omnivoice/models/omnivoice.py",
            "transcribe",
            {"np": np, "torch": SimpleNamespace(Tensor=type("Tensor", (), {}))},
        )

    def test_long_file_enables_timestamps(self):
        self.assertEqual(self.transcribe(self.holder, "long.wav"), "full transcript")
        self.pipe.assert_called_once_with("long.wav", return_timestamps=True)

    def test_long_stereo_array_is_float32_mono_with_timestamps(self):
        samples = np.ones((2, 16000 * 31), dtype=np.float64)
        samples[0] *= 0.25
        samples[1] *= 0.75
        self.transcribe(self.holder, (samples, 16000))
        audio = self.pipe.call_args.args[0]
        self.assertEqual(audio["array"].shape, (16000 * 31,))
        self.assertEqual(audio["array"].dtype, np.float32)
        np.testing.assert_array_equal(audio["array"], 0.5)
        self.assertTrue(self.pipe.call_args.kwargs["return_timestamps"])

    def test_invalid_reference_is_rejected_before_asr(self):
        for samples in ([], [np.nan], [np.inf], np.zeros((1, 2, 3))):
            with self.assertRaisesRegex(ValueError, "finite, non-empty"):
                self.transcribe(self.holder, (np.asarray(samples), 16000))
        self.pipe.assert_not_called()


if __name__ == "__main__":
    unittest.main()
