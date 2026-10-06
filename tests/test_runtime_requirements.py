from __future__ import annotations

import importlib.metadata
import importlib.util
import io
import json
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = "omnisonic" if (ROOT / "omnisonic").is_dir() else "omnivoice"
SPEC = importlib.util.spec_from_file_location(
    "_requirements_probe", ROOT / PACKAGE / "accelerator.py"
)
ACCELERATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ACCELERATOR
SPEC.loader.exec_module(ACCELERATOR)


class RuntimeRequirementsTests(unittest.TestCase):
    def check_requirements(self, text, version="1.2"):
        with (
            patch.object(Path, "read_text", return_value=text),
            patch.object(importlib.metadata, "version", return_value=version) as installed,
        ):
            ACCELERATOR.check_runtime_requirements("requirements.txt")
            return installed

    def test_accepts_matching_versions_without_importing_application(self):
        installed = self.check_requirements("# comment\nsample>=1.0,<2 # note\n\n")
        installed.assert_called_once_with("sample")

    def test_rejects_incompatible_dependency(self):
        with self.assertRaisesRegex(RuntimeError, "does not satisfy"):
            self.check_requirements("sample>=2")

    def test_rejects_missing_dependency(self):
        with (
            patch.object(Path, "read_text", return_value="missing-package"),
            patch.object(
                importlib.metadata,
                "version",
                side_effect=importlib.metadata.PackageNotFoundError("missing-package"),
            ),
            self.assertRaisesRegex(RuntimeError, "Missing application dependency"),
        ):
            ACCELERATOR.check_runtime_requirements("requirements.txt")

    def test_skips_inapplicable_platform_markers(self):
        installed = self.check_requirements('sample; python_version < "2.0"')
        installed.assert_not_called()

    def test_keeps_backend_specific_local_versions(self):
        self.check_requirements("torch>=2.9", "2.9.1+rocm7.2.1")

    def test_probe_json_preserves_unicode_names_in_legacy_shells(self):
        info = ACCELERATOR.AcceleratorInfo("cpu", "cpu", "Urządzenie 日本語", "2.9", None)
        stream = io.StringIO()
        with (
            patch.object(ACCELERATOR, "detect_accelerator", return_value=info),
            patch.object(ACCELERATOR, "_package_version", return_value="2.9"),
            redirect_stdout(stream),
        ):
            self.assertEqual(ACCELERATOR.main(["--json"]), 0)
        self.assertTrue(stream.getvalue().isascii())
        self.assertEqual(json.loads(stream.getvalue())["name"], info.name)

    def test_probe_json_preserves_unicode_errors_in_legacy_shells(self):
        message = "Brak pliku: C:/zażółć/模型.json"
        stream = io.StringIO()
        with (
            patch.object(ACCELERATOR, "detect_accelerator", side_effect=FileNotFoundError(message)),
            redirect_stdout(stream),
        ):
            self.assertEqual(ACCELERATOR.main(["--json"]), 1)
        self.assertTrue(stream.getvalue().isascii())
        self.assertEqual(json.loads(stream.getvalue())["error"], message)


if __name__ == "__main__":
    unittest.main()
