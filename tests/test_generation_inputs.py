"""Generation argument alignment and chunk routing without torch or model weights."""

import ast
import importlib.util
import logging
import math
import re
import unittest
from dataclasses import dataclass, fields
from numbers import Integral, Real
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
        "_generate_chunked",
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
        Integral=Integral,
        math=math,
        fields=fields,
        VoiceClonePrompt=Prompt,
        logger=logging.getLogger(__name__),
        _ZH_RE=re.compile("[\\u4e00-\\u9fff]"),
        _resolve_language=Mock(side_effect=lambda language: language),
        _resolve_instruct=Mock(side_effect=lambda instruction, **kwargs: instruction),
        _normalize_text=Mock(side_effect=lambda text, language: text),
    )
    text_spec = importlib.util.spec_from_file_location(
        "_generation_chunking", ROOT / "omnivoice/utils/text.py"
    )
    text_module = importlib.util.module_from_spec(text_spec)
    text_spec.loader.exec_module(text_module)
    namespace["chunk_text_punctuation"] = text_module.chunk_text_punctuation
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

    def test_normalization_cannot_turn_valid_input_into_empty_generation(self):
        for normalized in ("", " \n", None, 123):
            self.engine["_normalize_text"].return_value = normalized
            self.engine["_normalize_text"].side_effect = None
            with (
                self.subTest(normalized=normalized),
                self.assertRaisesRegex(ValueError, "normalized text"),
            ):
                self.preprocess(ref_audio="voice.wav", normalize_text=True)
            self.model.create_voice_clone_prompt.assert_not_called()
            self.model.duration_estimator.estimate_duration.assert_not_called()

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

    def test_generation_configuration_rejects_invalid_values_without_model_work(self):
        config_type = self.engine["OmniVoiceGenerationConfig"]
        invalid = {
            "num_step": (0, -1, True, 1.5, "2"),
            "t_shift": (0, -1, True, "0.1", float("nan"), float("inf")),
            "guidance_scale": (-1, True, "2", float("nan"), float("inf")),
            "layer_penalty_factor": (-1, True, "2", float("nan")),
            "position_temperature": (-1, True, "2", float("inf")),
            "class_temperature": (-1, True, "2", float("nan")),
            "audio_chunk_duration": (-1, True, "2", float("inf")),
            "audio_chunk_threshold": (-1, True, "2", float("nan")),
            "pad_duration": (-1, True, "2", float("inf")),
            "fade_duration": (-1, True, "2", float("nan")),
            "denoise": (None, 0, "false"),
            "preprocess_prompt": (None, 1, "true"),
            "postprocess_output": (None, 0, "false"),
        }
        for field, values in invalid.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    with self.assertRaisesRegex(ValueError, field):
                        config_type(**{field: value})
        self.model.create_voice_clone_prompt.assert_not_called()

    def test_generation_configuration_preserves_supported_zero_values(self):
        config = self.engine["OmniVoiceGenerationConfig"](
            num_step=1,
            guidance_scale=0,
            layer_penalty_factor=0,
            position_temperature=0,
            class_temperature=0,
            audio_chunk_duration=0,
            audio_chunk_threshold=0,
            pad_duration=0,
            fade_duration=0,
            denoise=False,
            preprocess_prompt=False,
            postprocess_output=False,
        )
        config.validate()

    def test_modified_configuration_is_validated_before_eval_or_reference_encoding(self):
        self.model.text_tokenizer = object()
        self.model.eval = Mock()
        config = self.engine["OmniVoiceGenerationConfig"]()
        config.num_step = 0
        with self.assertRaisesRegex(ValueError, "num_step"):
            self.engine["generate"](
                self.model, "Text.", ref_audio="reference.wav", generation_config=config
            )
        self.model.eval.assert_not_called()
        self.model.create_voice_clone_prompt.assert_not_called()

    def test_long_punctuation_free_text_reaches_multiple_small_inference_calls(self):
        text = " ".join(["alpha", "beta", "gamma", "delta"] * 30)
        self.model.duration_estimator.estimate_duration.side_effect = (
            lambda text, reference, tokens: len(text)
        )
        task = self.model._preprocess_all(text=text)
        self.model._generate_iterative = Mock(
            side_effect=lambda task, config: [SimpleNamespace(size=lambda axis: 50)]
        )
        config = self.engine["OmniVoiceGenerationConfig"](audio_chunk_duration=1)
        result = self.engine["_generate_chunked"](self.model, task, config)
        self.assertGreater(len(result[0]), 15)
        pieces = [call.args[0].texts[0] for call in self.model._generate_iterative.call_args_list]
        self.assertTrue(all(len(piece) <= 25 for piece in pieces))
        self.assertEqual(" ".join(pieces).split(), text.split())

    def test_subcharacter_chunk_estimate_still_makes_forward_progress(self):
        task = self.model._preprocess_all(text="abcd", duration=40)
        self.model._generate_iterative = Mock(
            side_effect=lambda task, config: [SimpleNamespace(size=lambda axis: 50)]
        )
        config = self.engine["OmniVoiceGenerationConfig"](audio_chunk_duration=0.01)
        result = self.engine["_generate_chunked"](self.model, task, config)
        self.assertEqual(len(result[0]), 4)
        pieces = [call.args[0].texts[0] for call in self.model._generate_iterative.call_args_list]
        self.assertEqual(pieces, list("abcd"))

    def exact_chunk_generator(self, task, config):
        return [
            SimpleNamespace(size=lambda axis, length=length: length) for length in task.target_lens
        ]

    def test_explicit_chunk_duration_keeps_one_exact_frame_budget_per_item(self):
        task = self.model._preprocess_all(
            text=["A short sentence.", "Another somewhat longer sentence."],
            duration=[40, 60],
            speed=[2, 0.5],
        )
        self.model._generate_iterative = Mock(side_effect=self.exact_chunk_generator)
        config = self.engine["OmniVoiceGenerationConfig"]()
        result = self.engine["_generate_chunked"](self.model, task, config)
        self.assertEqual(
            [sum(tokens.size(-1) for tokens in chunks) for chunks in result], [1000, 1500]
        )
        self.assertTrue(all(tokens.size(-1) > 0 for chunks in result for tokens in chunks))
        sliced = task.slice_task([1])
        self.assertEqual(sliced.durations, [60])

    def test_explicit_chunk_budgets_preserve_distinct_original_clone_references(self):
        task = self.model._preprocess_all(
            text=["A short sentence.", "Another somewhat longer sentence."],
            ref_audio=["first.wav", "second.wav"],
            ref_text=["First reference.", "Different reference words."],
            duration=[40, 60],
            speed=[2, 0.5],
        )
        self.model._generate_iterative = Mock(side_effect=self.exact_chunk_generator)
        config = self.engine["OmniVoiceGenerationConfig"]()
        result = self.engine["_generate_chunked"](self.model, task, config)
        self.assertEqual(
            [sum(tokens.size(-1) for tokens in chunks) for chunks in result], [1000, 1500]
        )
        for call in self.model._generate_iterative.call_args_list:
            for text, tokens in zip(
                call.args[0].ref_texts, call.args[0].ref_audio_tokens, strict=True
            ):
                original = task.ref_texts.index(text)
                self.assertIs(tokens, task.ref_audio_tokens[original])

    def test_mixed_explicit_and_estimated_chunk_targets_remain_independent(self):
        task = self.model._preprocess_all(
            text=["A short sentence.", "Another somewhat longer sentence."],
            duration=[40, None],
            speed=[2, 0.5],
        )
        self.model._generate_iterative = Mock(side_effect=self.exact_chunk_generator)
        config = self.engine["OmniVoiceGenerationConfig"](audio_chunk_duration=0.1)
        result = self.engine["_generate_chunked"](self.model, task, config)
        self.assertEqual(sum(tokens.size(-1) for tokens in result[0]), 1000)
        self.assertGreater(sum(tokens.size(-1) for tokens in result[1]), 0)

    def test_impossibly_short_chunk_budget_fails_before_generation(self):
        task = self.model._preprocess_all(text="one two three four", duration=0.04)
        self.model._generate_iterative = Mock(side_effect=self.exact_chunk_generator)
        config = self.engine["OmniVoiceGenerationConfig"](audio_chunk_duration=0.0001)
        with self.assertRaisesRegex(ValueError, "duration.*chunk"):
            self.engine["_generate_chunked"](self.model, task, config)
        self.model._generate_iterative.assert_not_called()

    def test_auto_reference_does_not_apply_speaking_speed_twice(self):
        task = self.model._preprocess_all(text="one two three four five six seven eight", speed=2)
        self.model._generate_iterative = Mock(side_effect=self.exact_chunk_generator)
        estimate = Mock(wraps=self.model._estimate_target_tokens)
        self.model._estimate_target_tokens = estimate
        config = self.engine["OmniVoiceGenerationConfig"](audio_chunk_duration=0.5)
        self.engine["_generate_chunked"](self.model, task, config)
        self.assertGreater(estimate.call_count, 1)
        self.assertEqual(estimate.call_args_list[0].kwargs["speed"], 2)
        self.assertTrue(all(call.kwargs["speed"] == 1 for call in estimate.call_args_list[1:]))
        generated = self.model._generate_iterative.call_args_list
        first_tokens = generated[0].args[0].target_lens[0]
        self.assertTrue(
            all(call.args[0].ref_audio_tokens[0].size(-1) == first_tokens for call in generated[1:])
        )

    def test_clone_chunks_keep_original_reference_and_apply_speed_once(self):
        task = self.model._preprocess_all(
            text="one two three four five six seven eight", ref_audio="voice.wav", speed=2
        )
        self.model._generate_iterative = Mock(side_effect=self.exact_chunk_generator)
        estimate = Mock(wraps=self.model._estimate_target_tokens)
        self.model._estimate_target_tokens = estimate
        config = self.engine["OmniVoiceGenerationConfig"](audio_chunk_duration=0.5)
        self.engine["_generate_chunked"](self.model, task, config)
        self.assertGreater(estimate.call_count, 1)
        self.assertTrue(all(call.kwargs["speed"] == 2 for call in estimate.call_args_list))
        for call in self.model._generate_iterative.call_args_list:
            self.assertIs(call.args[0].ref_audio_tokens[0], task.ref_audio_tokens[0])


if __name__ == "__main__":
    unittest.main()
