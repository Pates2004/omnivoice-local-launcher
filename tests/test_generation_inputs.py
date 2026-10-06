"""Generation argument alignment and chunk routing without torch or model weights."""

import ast
import logging
import math
import re
import unittest
from dataclasses import dataclass, fields
from numbers import Real
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

ROOT = Path(__file__).resolve().parents[1]


class Prompt:
    def __init__(self, source, transcript=None):
        self.ref_text = transcript if transcript is not None else f"transcript:{source}"
        self.ref_audio_tokens = SimpleNamespace(source=source, size=lambda axis: 4)
        self.ref_rms = 0.1
        self.validate = Mock()


def load_engine():
    source = ROOT / "omnivoice/models/omnivoice.py"
    tree = ast.parse(source.read_text(encoding="utf-8"))
    names = {
        "GenerationTask",
        "OmniVoiceGenerationConfig",
        "generate",
        "_preprocess_all",
        "_ensure_list",
        "_ensure_timing_list",
        "_estimate_target_tokens",
    }
    nodes = [
        node
        for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.ClassDef)) and node.name in names
    ]
    for node in nodes:
        if isinstance(node, ast.FunctionDef):
            node.decorator_list = []
    module = ast.Module(
        body=[ast.ImportFrom(module="__future__", names=[ast.alias(name="annotations")], level=0)]
        + nodes,
        type_ignores=[],
    )
    namespace = dict(
        __name__=__name__,
        dataclass=dataclass,
        Real=Real,
        math=math,
        fields=fields,
        VoiceClonePrompt=Prompt,
        logger=logging.getLogger(__name__),
        _ZH_RE=re.compile("[\\u4e00-\\u9fff]"),
        _resolve_language=Mock(side_effect=lambda language: language),
        _resolve_instruct=Mock(side_effect=lambda instruction, **kwargs: instruction),
        _normalize_text=Mock(side_effect=lambda text, language: text),
    )
    exec(compile(ast.fix_missing_locations(module), str(source), "exec"), namespace)
    return namespace


class GenerationInputTests(unittest.TestCase):
    def setUp(self):
        self.engine = load_engine()
        self.model = SimpleNamespace(
            duration_estimator=SimpleNamespace(estimate_duration=Mock(return_value=100)),
            audio_tokenizer=SimpleNamespace(config=SimpleNamespace(frame_rate=25)),
            create_voice_clone_prompt=Mock(
                side_effect=lambda ref_audio, ref_text, preprocess_prompt: Prompt(
                    ref_audio, ref_text
                )
            ),
        )
        for name in (
            "_preprocess_all",
            "_ensure_list",
            "_ensure_timing_list",
            "_estimate_target_tokens",
        ):
            setattr(self.model, name, self.engine[name].__get__(self.model))

    def preprocess(self, **kwargs):
        return self.model._preprocess_all(text=["First.", "Second."], **kwargs)

    def test_distinct_audio_references_with_no_transcripts_each_create_a_prompt(self):
        task = self.preprocess(ref_audio=["first.wav", "second.wav"])
        calls = self.model.create_voice_clone_prompt.call_args_list
        self.assertEqual([call.kwargs["ref_audio"] for call in calls], ["first.wav", "second.wav"])
        self.assertEqual([call.kwargs["ref_text"] for call in calls], [None, None])
        self.assertEqual(task.ref_texts, ["transcript:first.wav", "transcript:second.wav"])

    def test_scalar_audio_is_paired_with_each_explicit_transcript(self):
        task = self.preprocess(ref_audio="voice.wav", ref_text=["One.", "Two."])
        calls = self.model.create_voice_clone_prompt.call_args_list
        self.assertEqual([call.kwargs["ref_audio"] for call in calls], ["voice.wav", "voice.wav"])
        self.assertEqual(task.ref_texts, ["One.", "Two."])

    def test_scalar_transcript_is_broadcast_to_distinct_audio(self):
        task = self.preprocess(ref_audio=["first.wav", "second.wav"], ref_text="Same words.")
        calls = self.model.create_voice_clone_prompt.call_args_list
        self.assertEqual([call.kwargs["ref_audio"] for call in calls], ["first.wav", "second.wav"])
        self.assertEqual(task.ref_texts, ["Same words.", "Same words."])

    def test_two_per_item_reference_lists_preserve_pairing(self):
        self.preprocess(ref_audio=["first.wav", "second.wav"], ref_text=["One.", "Two."])
        calls = self.model.create_voice_clone_prompt.call_args_list
        self.assertEqual(
            [(call.kwargs["ref_audio"], call.kwargs["ref_text"]) for call in calls],
            [("first.wav", "One."), ("second.wav", "Two.")],
        )

    def test_scalar_and_singleton_references_reuse_one_prompt(self):
        for audio, text in (("voice.wav", None), (["voice.wav"], [None]), ("voice.wav", "Words.")):
            with self.subTest(audio=audio, text=text):
                self.model.create_voice_clone_prompt.reset_mock()
                task = self.preprocess(ref_audio=audio, ref_text=text, preprocess_prompt=False)
                self.model.create_voice_clone_prompt.assert_called_once()
                self.assertFalse(
                    self.model.create_voice_clone_prompt.call_args.kwargs["preprocess_prompt"]
                )
                self.assertIs(task.ref_audio_tokens[0], task.ref_audio_tokens[1])

    def test_waveform_rate_tuple_is_one_reference_not_a_batch(self):
        reference = (object(), 24000)
        self.preprocess(ref_audio=reference, ref_text="Reference.")
        self.model.create_voice_clone_prompt.assert_called_once()
        self.assertIs(self.model.create_voice_clone_prompt.call_args.kwargs["ref_audio"], reference)

    def test_explicit_prompt_still_overrides_unused_reference_arguments(self):
        prompt = Prompt("preset.pt", "Preset words.")
        with self.assertLogs(__name__, "WARNING"):
            task = self.preprocess(
                voice_clone_prompt=prompt,
                ref_audio=["unused"] * 5,
                ref_text=["unused"] * 4,
            )
        self.model.create_voice_clone_prompt.assert_not_called()
        self.assertEqual(task.ref_texts, ["Preset words.", "Preset words."])

    def assert_mixed_prompts_rejected(self, prompts):
        with self.assertRaisesRegex(ValueError, "must not mix prompts with None"):
            self.preprocess(voice_clone_prompt=prompts, normalize_text=True)
        self.model.create_voice_clone_prompt.assert_not_called()
        self.engine["_normalize_text"].assert_not_called()
        self.engine["_resolve_language"].assert_not_called()
        self.model.duration_estimator.estimate_duration.assert_not_called()

    def test_none_followed_by_prompt_does_not_silently_drop_the_prompt(self):
        self.assert_mixed_prompts_rejected([None, Prompt("preset")])

    def test_prompt_followed_by_none_reports_validation_error(self):
        self.assert_mixed_prompts_rejected([Prompt("preset"), None])

    def test_all_none_prompts_preserve_unconditioned_generation(self):
        for prompts in (None, [None], [None, None]):
            with self.subTest(prompts=prompts):
                task = self.preprocess(voice_clone_prompt=prompts)
                self.assertEqual(task.ref_texts, [None, None])
                self.assertEqual(task.ref_audio_tokens, [None, None])
        self.model.create_voice_clone_prompt.assert_not_called()

    def test_inconsistent_argument_lengths_fail_before_prompt_creation_or_normalization(self):
        for argument in (
            "language",
            "instruct",
            "ref_audio",
            "ref_text",
            "speed",
            "duration",
            "voice_clone_prompt",
        ):
            for count in (0, 2, 4):
                values = [Prompt("preset") if argument == "voice_clone_prompt" else 1] * count
                kwargs = dict(ref_audio="voice.wav", normalize_text=True)
                kwargs[argument] = values
                with self.subTest(argument=argument, count=count), self.assertRaises(ValueError):
                    self.model._preprocess_all(text=["One.", "Two.", "Three."], **kwargs)
                self.model.create_voice_clone_prompt.assert_not_called()
                self.engine["_normalize_text"].assert_not_called()
                self.engine["_resolve_language"].assert_not_called()
                self.model.duration_estimator.estimate_duration.assert_not_called()

    def test_invalid_text_fails_before_side_effects(self):
        for text in (None, 123, [], "", "  ", ["Valid.", None], ["Valid.", " "]):
            with self.subTest(text=text), self.assertRaises(ValueError):
                self.model._preprocess_all(text=text, ref_audio="voice.wav", normalize_text=True)
        self.model.create_voice_clone_prompt.assert_not_called()
        self.engine["_normalize_text"].assert_not_called()

    def test_none_speed_means_normal_speed_for_that_item(self):
        task = self.preprocess(speed=[None, 1.25])
        self.assertEqual(task.target_lens, [100, 80])
        self.assertEqual(task.speed, [1.0, 1.25])

    def test_scalar_singleton_tuple_and_iterable_speed_keep_broadcast(self):
        for speed in (2, [2], (2,), iter([2])):
            with self.subTest(speed=speed):
                task = self.preprocess(speed=speed)
                self.assertEqual(task.target_lens, [50, 50])
        self.assertEqual(self.preprocess(speed=[None]).target_lens, [100, 100])

    def test_optional_durations_override_only_their_own_speed(self):
        task = self.preprocess(speed=[None, 2], duration=[2, None])
        self.assertEqual(task.target_lens, [50, 50])
        self.assertEqual(task.speed, [2.0, 2])

    def test_scalar_and_singleton_duration_keep_broadcast(self):
        for duration in (2, [2], (2,), iter([2])):
            with self.subTest(duration=duration):
                self.assertEqual(self.preprocess(duration=duration).target_lens, [50, 50])
        self.assertEqual(self.preprocess(duration=[None]).target_lens, [100, 100])

    def test_invalid_timing_fails_before_reference_or_normalization_work(self):
        invalid_values = (0, -1, float("nan"), float("inf"), True, "2", b"2", 1j, 10**400)
        for argument in ("speed", "duration"):
            for value in invalid_values:
                for values in (value, [None, value]):
                    with self.subTest(argument=argument, values=values):
                        with self.assertRaisesRegex(ValueError, argument):
                            self.preprocess(
                                ref_audio="voice.wav", normalize_text=True, **{argument: values}
                            )
                        self.model.create_voice_clone_prompt.assert_not_called()
                        self.engine["_normalize_text"].assert_not_called()
                        self.engine["_resolve_language"].assert_not_called()
                        self.model.duration_estimator.estimate_duration.assert_not_called()

    def test_invalid_timing_container_has_an_actionable_error(self):
        for argument in ("speed", "duration"):
            for values in (object(), {2: None}):
                with self.subTest(argument=argument, values=values):
                    with self.assertRaisesRegex(ValueError, argument):
                        self.preprocess(**{argument: values})

    def test_broadcast_helpers_do_not_mutate_caller_lists(self):
        instructions = ["calm", "quiet"]
        self.engine["_resolve_instruct"].side_effect = lambda value, **kwargs: value.upper()
        task = self.preprocess(instruct=instructions)
        self.assertEqual(task.instructs, ["CALM", "QUIET"])
        self.assertEqual(instructions, ["calm", "quiet"])
        self.assertIsNot(task.instructs, instructions)
        for repeat in (False, True):
            values = [1, 2]
            self.assertIsNot(self.model._ensure_list(values, 2, auto_repeat=repeat), values)

    def test_other_scalar_options_still_broadcast(self):
        task = self.preprocess(language=["en"], instruct=["calm"])
        self.assertEqual(task.langs, ["en", "en"])
        self.assertEqual(task.instructs, ["calm", "calm"])

    def test_zero_chunk_duration_routes_every_item_to_direct_generation(self):
        task = self.preprocess(duration=[40, 2])
        config = self.engine["OmniVoiceGenerationConfig"](audio_chunk_duration=0)
        self.assertEqual(task.get_indices(config, 25), ([0, 1], []))

    def test_positive_chunk_duration_retains_threshold_boundary(self):
        task = self.preprocess(duration=[40, 30])
        config = self.engine["OmniVoiceGenerationConfig"](audio_chunk_duration=15)
        self.assertEqual(task.get_indices(config, 25), ([1], [0]))

    def test_generate_does_not_call_chunked_worker_when_chunking_is_disabled(self):
        self.model.text_tokenizer = object()
        self.model.eval = Mock()
        self.model._generate_iterative = Mock(return_value=["tokens:first", "tokens:second"])
        self.model._generate_chunked = Mock()
        self.model._decode_and_post_process = Mock(side_effect=lambda tokens, *args: tokens)
        config = self.engine["OmniVoiceGenerationConfig"](audio_chunk_duration=0)
        result = self.engine["generate"](
            self.model, text=["First.", "Second."], duration=40, generation_config=config
        )
        self.assertEqual(result, ["tokens:first", "tokens:second"])
        self.model._generate_iterative.assert_called_once()
        self.model._generate_chunked.assert_not_called()


if __name__ == "__main__":
    unittest.main()
