"""Authoritative voice-instruction contracts without importing model libraries."""

import ast
import builtins
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


def load_voice_design():
    spec = importlib.util.spec_from_file_location(
        "_voice_design_contract", ROOT / "omnivoice/utils/voice_design.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VoiceDesignContractTests(unittest.TestCase):
    def setUp(self):
        self.design = load_voice_design()

    def test_equivalent_repeated_items_are_not_false_conflicts(self):
        for raw, use_zh, expected in (
            ("male, male", False, "male"),
            ("male, 男, MALE", False, "male"),
            ("male, 男, MALE", True, "男"),
            ("male, whisper, 耳语, young adult, 青年", False, "male, whisper, young adult"),
            ("男，耳语，whisper，青年，young adult", True, "男，耳语，青年"),
        ):
            with self.subTest(raw=raw, use_zh=use_zh):
                self.assertEqual(self.design.resolve_instruct(raw, use_zh=use_zh), expected)

    def test_true_category_conflicts_are_still_rejected(self):
        for raw in ("male, female", "男, 女", "low pitch, high pitch", "young adult, elderly"):
            with self.subTest(raw=raw), self.assertRaisesRegex(ValueError, "Conflicting"):
                self.design.resolve_instruct(raw)

    def test_dialect_and_accent_conflict_is_not_hidden(self):
        with self.assertRaisesRegex(ValueError, "Cannot mix"):
            self.design.resolve_instruct("american accent, 河南话")

    def test_arbitrary_prose_remains_an_explicit_validation_error(self):
        for raw in ("Calm narrator", "Soft voice", "mal", "whispr"):
            with self.subTest(raw=raw), self.assertRaisesRegex(ValueError, "Unsupported instruct"):
                self.design.resolve_instruct(raw)

    def test_separators_empty_value_and_existing_valid_choices_keep_behavior(self):
        self.assertIsNone(self.design.resolve_instruct(None))
        self.assertIsNone(self.design.resolve_instruct(" \t"))
        self.assertEqual(self.design.resolve_instruct(", male，young adult, "), "male, young adult")
        self.assertEqual(
            self.design.resolve_instruct("male, american accent", use_zh=True),
            "male, american accent",
        )
        self.assertEqual(self.design.resolve_instruct("male, 河南话"), "男，河南话")

    def test_helper_source_requires_no_inference_dependencies(self):
        original_import = builtins.__import__

        def guarded_import(name, *args, **kwargs):
            if name.split(".", 1)[0] in {"torch", "torchaudio", "transformers", "numpy"}:
                self.fail(f"Voice-instruction validation imported {name}")
            return original_import(name, *args, **kwargs)

        with patch("builtins.__import__", side_effect=guarded_import):
            helper = load_voice_design()
            self.assertEqual(helper.resolve_instruct("male, whisper"), "male, whisper")

    def test_model_preserves_its_resolver_name_as_authoritative_alias(self):
        tree = ast.parse((ROOT / "omnivoice/models/omnivoice.py").read_text(encoding="utf-8"))
        imports = [
            node
            for node in tree.body
            if isinstance(node, ast.ImportFrom) and node.module == "omnivoice.utils.voice_design"
        ]
        self.assertTrue(
            any(
                alias.name == "resolve_instruct" and alias.asname == "_resolve_instruct"
                for node in imports
                for alias in node.names
            )
        )
        self.assertFalse(
            any(
                isinstance(node, ast.FunctionDef) and node.name == "_resolve_instruct"
                for node in tree.body
            )
        )


if __name__ == "__main__":
    unittest.main()
