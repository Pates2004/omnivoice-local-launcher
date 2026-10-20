"""Regression coverage for centralized, project-scoped test artifacts."""

import unittest
from pathlib import Path, PureWindowsPath
from unittest.mock import patch

from tests import materials


class MaterialDirectoryTests(unittest.TestCase):
    def test_categories_precede_the_real_project_name(self):
        project = Path(__file__).resolve().parents[1]
        with patch.object(materials, "_work_directory", return_value=Path("central")):
            for category in ("Forme", "Workspace", "Trash", "Snapshots"):
                with self.subTest(category=category):
                    self.assertEqual(
                        materials.material_directory(category.lower(), project),
                        Path("central") / category / project.name,
                    )
            self.assertEqual(
                materials.material_directory("Trash"), Path("central") / "Trash" / project.name
            )

    def test_unknown_categories_cannot_escape_the_material_root(self):
        for category in ("", "../Trash", "Trash/other", "Installfiles"):
            with self.subTest(category=category), self.assertRaises(ValueError):
                materials.material_directory(category)

    def test_windows_drive_selection_depends_only_on_drive_presence(self):
        for mask, expected in ((1 << 3, "D:/work"), (1 << 2, "C:/work")):
            with (
                self.subTest(mask=mask),
                patch.object(materials.os, "name", "nt"),
                patch.object(materials, "Path", PureWindowsPath),
                patch.object(materials, "_windows_logical_drives", return_value=mask),
            ):
                self.assertEqual(materials._work_directory(), PureWindowsPath(expected))

    def test_failed_drive_detection_is_not_a_c_drive_fallback(self):
        with (
            patch.object(materials.os, "name", "nt"),
            patch.object(materials, "_windows_logical_drives", side_effect=OSError("drive query")),
            self.assertRaisesRegex(OSError, "drive query"),
        ):
            materials._work_directory()

    def test_scratch_creates_missing_parents_and_retains_prior_results(self):
        base = materials.scratch_directory("material-helper-")
        parent = base / "missing" / "Trash" / "Fixture"
        with patch.object(materials, "material_directory", return_value=parent):
            first = materials.scratch_directory("run-")
            marker = first / "retained.txt"
            marker.write_text("Synthetic prior test result.", encoding="utf-8")
            second = materials.scratch_directory("run-")
        self.assertEqual(first.parent, parent)
        self.assertTrue(first.is_dir() and second.is_dir())
        self.assertNotEqual(first, second)
        self.assertEqual(marker.read_text(encoding="utf-8"), "Synthetic prior test result.")

    def test_storage_access_failure_is_reported_without_another_destination(self):
        with (
            patch.object(Path, "mkdir", side_effect=PermissionError("central denied")),
            patch.object(materials.tempfile, "mkdtemp") as create,
            self.assertRaisesRegex(PermissionError, "central denied"),
        ):
            materials.scratch_directory("denied-")
        create.assert_not_called()

    def test_scratch_prefix_cannot_redirect_to_another_project(self):
        for prefix in ("", "../other", "other\\child", "D:alternate"):
            with self.subTest(prefix=prefix), self.assertRaises(ValueError):
                materials.scratch_directory(prefix)
