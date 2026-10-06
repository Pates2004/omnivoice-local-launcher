"""Lightweight normalization contracts plus optional real-library checks."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from contextlib import ExitStack
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
HAS_NUM2WORDS = importlib.util.find_spec("num2words") is not None


def load_source(name, relative_path):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class NormalizationTestCase(unittest.TestCase):
    def setUp(self):
        self.context = ExitStack()
        self.addCleanup(self.context.close)
        self.text = load_source("_normalization_text", "omnivoice/utils/text.py")
        languages = load_source("_normalization_languages", "omnivoice/utils/lang_map.py")
        self.context.enter_context(patch.dict(sys.modules, {"omnivoice.utils.lang_map": languages}))
        self.context.enter_context(patch.object(importlib.util, "find_spec", return_value=None))

    def assert_error(self, key, language, callback, *args):
        with self.assertRaises(self.text.TextNormalizationError) as caught:
            callback(*args)
        self.assertEqual(caught.exception.message_key, key)
        self.assertEqual(caught.exception.language, language)
        self.assertIsInstance(caught.exception, ValueError)
        self.assertIn(language, str(caught.exception))


class NormalizationTests(NormalizationTestCase):
    def setUp(self):
        super().setUp()
        self.words = ModuleType("num2words")
        self.words.CONVERTER_CLASSES = {
            language: SimpleNamespace(negword="minus ")
            for language in ("en", "en_IN", "pl", "pt_BR", "ja", "no")
        }
        self.words.num2words = Mock(side_effect=lambda number, lang: f"{lang}:{number}")
        self.context.enter_context(patch.dict(sys.modules, {"num2words": self.words}))

    def test_capability_resolves_names_codes_and_locales(self):
        for language in ("Polish", "pl", "English", "en", "Japanese", "ja", "PL_pl", "pt-br"):
            with self.subTest(language=language):
                self.assertEqual(self.text.check_normalization_support(language), "num2words")
        self.words.num2words.assert_not_called()

    def test_regional_converter_is_selected_before_base(self):
        self.assertEqual(self.text.normalize_text("12", "en-IN"), "en_IN:12")
        self.assertEqual(self.text.normalize_text("12", "pl-PL"), "pl:12")

    def test_unknown_names_do_not_accidentally_select_two_letter_language(self):
        self.assert_error(
            "normalization_unsupported_language",
            "notalanguage",
            self.text.check_normalization_support,
            "notalanguage",
        )

    def test_unsupported_language_has_visible_structured_error(self):
        self.assert_error(
            "normalization_unsupported_language",
            "bo",
            self.text.normalize_text,
            "There are 12 items.",
            "Tibetan",
        )

    def test_chinese_without_native_library_reports_dependency(self):
        self.assert_error(
            "normalization_missing_dependency",
            "zh",
            self.text.check_normalization_support,
            "Chinese",
        )

    def test_missing_basic_library_reports_dependency(self):
        with patch.dict(sys.modules, {"num2words": None}):
            self.assert_error(
                "normalization_missing_dependency",
                "pl",
                self.text.normalize_text,
                "Mam 12 kotow.",
                "Polish",
            )

    def test_fast_wetext_probe_never_constructs_fsts(self):
        with (
            patch.object(importlib.util, "find_spec", return_value=object()),
            patch.object(self.text, "_get_en_normalizer") as english,
            patch.object(self.text, "_get_zh_normalizer") as chinese,
        ):
            self.assertEqual(self.text.check_normalization_support("English"), "wetext")
            self.assertEqual(self.text.check_normalization_support("Chinese"), "wetext")
        english.assert_not_called()
        chinese.assert_not_called()
        self.words.num2words.assert_not_called()

    def test_cached_wetext_normalizer_counts_as_available(self):
        self.text._EN_NORMALIZER = SimpleNamespace(normalize=Mock())
        self.assertEqual(self.text.check_normalization_support("en"), "wetext")
        self.text._EN_NORMALIZER.normalize.assert_not_called()

    def test_broken_optional_spec_uses_basic_fallback(self):
        for error in (ImportError("missing"), ValueError("no spec")):
            with (
                self.subTest(error=error),
                patch.object(importlib.util, "find_spec", side_effect=error),
            ):
                self.assertEqual(self.text.check_normalization_support("en"), "num2words")

    def test_standalone_integers_and_signs_are_converted(self):
        self.assertEqual(
            self.text.normalize_text("0 cats, +12 dogs; (-12) birds!", "en"),
            "en:0 cats, en:12 dogs; (en:-12) birds!",
        )

    def test_negative_polish_works_around_upstream_integer_bug(self):
        self.assertEqual(self.text.normalize_text("-12", "pl"), "minus pl:12")
        self.words.num2words.assert_called_once_with(12, lang="pl")

    def test_compound_numbers_and_identifiers_are_not_partially_rewritten(self):
        values = (
            "3.14",
            "-3.14",
            "1,234.50",
            "1.234,50",
            "2026-10-01",
            "01/10/2026",
            "12:30",
            "1 234",
            "1\u00a0234",
            "1\u202f234",
            "A123",
            "123B",
            "NI3",
            "3.14kg",
            "1.2abc",
            "1e12",
            "1E-12",
            "ref-123",
            "part_123",
            "12%",
            "$12",
            "12$",
            "€12",
            "12€",
            "1'234",
            "1’234",
        )
        for value in values:
            with self.subTest(value=value):
                self.assertEqual(self.text.normalize_text(value, "pl"), value)
        self.words.num2words.assert_not_called()

    def test_plain_numbers_next_to_sentence_punctuation_still_convert(self):
        self.assertEqual(
            self.text.normalize_text("(12), 5. 6! 7?", "en"),
            "(en:12), en:5. en:6! en:7?",
        )

    def test_control_tags_and_pronunciation_are_preserved(self):
        self.assertEqual(
            self.text.normalize_text("  12 [laughter] [B EY1 S] 3\n", "en"),
            "  en:12 [laughter] [B EY1 S] en:3\n",
        )

    def test_optional_rich_normalizer_is_preferred_for_english(self):
        normalizer = SimpleNamespace(normalize=Mock(return_value="January first"))
        self.text._EN_NORMALIZER = normalizer
        self.assertEqual(self.text.normalize_text("  01/01  ", "en"), "  January first  ")
        normalizer.normalize.assert_called_once_with("01/01")
        self.words.num2words.assert_not_called()

    def test_chinese_pinyin_controls_are_protected_from_rich_normalizer(self):
        normalizer = SimpleNamespace(
            normalize=Mock(side_effect=lambda value: value.replace("3", "three"))
        )
        self.text._ZH_NORMALIZER = normalizer
        self.assertEqual(
            self.text.normalize_text("3 NI3 [laughter] [B EY1 S] 3", "zh"),
            "three NI3 [laughter] [B EY1 S] three",
        )
        self.assertEqual(normalizer.normalize.call_count, 2)

    def test_wetext_native_import_failure_falls_back_on_english(self):
        for error in (ImportError("pynini"), OSError("native DLL unavailable")):
            with (
                self.subTest(error=error),
                patch.object(importlib.util, "find_spec", return_value=object()),
                patch.object(self.text, "_get_en_normalizer", side_effect=error),
            ):
                self.assertEqual(self.text.normalize_text("12", "en"), "en:12")

    def test_wetext_native_import_failure_for_chinese_is_visible(self):
        with (
            patch.object(importlib.util, "find_spec", return_value=object()),
            patch.object(self.text, "_get_zh_normalizer", side_effect=ImportError("pynini")),
        ):
            self.assert_error(
                "normalization_missing_dependency",
                "zh",
                self.text.normalize_text,
                "12",
                "zh",
            )

    def test_wetext_build_failure_is_not_reported_as_success(self):
        with (
            patch.object(importlib.util, "find_spec", return_value=object()),
            patch.object(self.text, "_get_en_normalizer", side_effect=RuntimeError("FST failed")),
        ):
            self.assert_error(
                "normalization_failed",
                "en",
                self.text.normalize_text,
                "12",
                "en",
            )

    def test_wetext_runtime_failure_is_not_swallowed(self):
        self.text._EN_NORMALIZER = SimpleNamespace(
            normalize=Mock(side_effect=RuntimeError("bad text"))
        )
        self.assert_error(
            "normalization_failed",
            "en",
            self.text.normalize_text,
            "12",
            "en",
        )

    def test_basic_converter_unsupported_operation_is_visible(self):
        self.words.num2words.side_effect = NotImplementedError("unsupported")
        self.assert_error(
            "normalization_unsupported_language",
            "en",
            self.text.normalize_text,
            "12",
            "en",
        )

    def test_basic_converter_runtime_failure_is_visible(self):
        self.words.num2words.side_effect = OverflowError("too large")
        self.assert_error(
            "normalization_failed",
            "pl",
            self.text.normalize_text,
            "12",
            "pl",
        )

    def test_auto_api_retains_chinese_english_script_heuristic(self):
        self.text._ZH_NORMALIZER = SimpleNamespace(
            normalize=Mock(return_value="Chinese normalized")
        )
        for language in (None, "Auto", "none", ""):
            with self.subTest(language=language):
                self.assertEqual(self.text.normalize_text("12", language), "en:12")
                self.assertEqual(self.text.normalize_text("中文12", language), "Chinese normalized")

    def test_empty_text_needs_no_normalization_library(self):
        with patch.dict(sys.modules, {"num2words": None}):
            for text in ("", " \n\t "):
                with self.subTest(text=text):
                    self.assertEqual(self.text.normalize_text(text, "pl"), text)


@unittest.skipUnless(HAS_NUM2WORDS, "Install num2words to run real-library checks")
class RealNormalizationTests(NormalizationTestCase):
    def test_real_polish_integer(self):
        self.assertEqual(
            self.text.normalize_text("Mam 123 koty.", "Polish"),
            "Mam sto dwadzieścia trzy koty.",
        )

    def test_real_polish_signed_integers(self):
        self.assertEqual(
            self.text.normalize_text("-12 kotów i +5 psów, 0 ptaków.", "pl"),
            "minus dwanaście kotów i pięć psów, zero ptaków.",
        )

    def test_real_english_integer(self):
        self.assertEqual(
            self.text.normalize_text("-12 cats and 123 dogs.", "English"),
            "minus twelve cats and one hundred and twenty-three dogs.",
        )

    def test_real_structured_values_and_controls_survive(self):
        self.assertEqual(
            self.text.normalize_text("12 3.14 2026-10-01 12:30 A123 123B [B EY1 S] NI3", "pl"),
            "dwanaście 3.14 2026-10-01 12:30 A123 123B [B EY1 S] NI3",
        )

    def test_real_languages_are_not_limited_to_polish_and_english(self):
        from num2words import num2words

        for language in ("de", "es", "ja", "pt_BR"):
            with self.subTest(language=language):
                self.assertEqual(self.text.check_normalization_support(language), "num2words")
                self.assertEqual(
                    self.text.normalize_text("12", language), num2words(12, lang=language)
                )

    def test_real_unsupported_language_is_visible(self):
        self.assert_error(
            "normalization_unsupported_language",
            "bo",
            self.text.normalize_text,
            "12",
            "Tibetan",
        )


if __name__ == "__main__":
    unittest.main()
