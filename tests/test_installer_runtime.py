"""Regression coverage for bounded, transactional runtime entry-point repair."""

import contextlib
import csv
import importlib.util
import io
import json
import stat
import struct
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "tested_installer_runtime", PROJECT_ROOT / "installer_runtime.py"
)
runtime = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = runtime
SPEC.loader.exec_module(runtime)


def launcher_bytes(old_python, *, gui=False, variant="modern", body=None):
    """A non-executable synthetic PE image, sufficient for structural testing."""
    stub = bytearray(1024)
    stub[:2] = b"MZ"
    struct.pack_into("<I", stub, 60, 128)
    stub[128:132] = b"PE\0\0"
    struct.pack_into("<HH", stub, 132, 0x8664, 1)
    struct.pack_into("<HH", stub, 148, 240, 2)
    struct.pack_into("<H", stub, 152, 0x20B)
    struct.pack_into("<I", stub, 212, 512)
    struct.pack_into("<H", stub, 220, 2 if gui else 3)
    struct.pack_into("<II", stub, 408, 512, 512)
    if body is None:
        if variant == "modern":
            body = (
                "import sys\nfrom sample.cli import main\n"
                "if __name__ == '__main__':\n"
                "    sys.argv[0] = sys.argv[0].removesuffix('.exe')\n"
                "    sys.exit(main())\n"
            )
        else:
            statement = "from sample.cli import main\n"
            body = "import re\nimport sys\n"
            if variant == "legacy":
                body += statement
            body += "if __name__ == '__main__':\n"
            if variant == "inline":
                body += "    " + statement
            body += (
                "    sys.argv[0] = re.sub(r'(-script\\.pyw|\\.exe)?$', '', sys.argv[0])\n"
                "    sys.exit(main())\n"
            )
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, "w") as archive:
        archive.writestr("__main__.py", body)
    return bytes(stub) + ("#!" + old_python + "\n").encode("utf-8") + stream.getvalue()


class RuntimeRepairTests(unittest.TestCase):
    def setUp(self):
        trash = PROJECT_ROOT / "trash"
        trash.mkdir(exist_ok=True)
        self.scratch = Path(tempfile.mkdtemp(prefix="runtime-relocation-", dir=trash))
        self.root = self.scratch / "runtime żółć ' space#!"
        self.scripts = self.root / "Scripts"
        self.site = self.root / "Lib" / "site-packages"
        self.scripts.mkdir(parents=True)
        self.site.mkdir(parents=True)
        self.python = self.root / "python.exe"
        self.python.write_bytes(b"Synthetic interpreter fixture, not executable")
        self.python.with_name("pythonw.exe").write_bytes(b"Synthetic GUI interpreter fixture")
        self.prefix_patch = mock.patch.object(runtime.sys, "prefix", str(self.root))
        self.exe_patch = mock.patch.object(runtime.sys, "executable", str(self.python))
        self.prefix_patch.start()
        self.exe_patch.start()
        self.addCleanup(self.exe_patch.stop)
        self.addCleanup(self.prefix_patch.stop)
        self.metadata = self.site / "sample-1.0.dist-info"
        self.metadata.mkdir()
        self.record = self.metadata / "RECORD"
        self.entries = self.metadata / "entry_points.txt"
        self.entries.write_text(
            "[console_scripts]\nsample=sample.cli:main\n"
            "[gui_scripts]\nsample-gui=sample.cli:main\n",
            encoding="utf-8",
        )
        self.rows = []

    def add_launcher(self, name="sample.exe", **kwargs):
        old = kwargs.pop("old_python", r"C:\previous runtime#!\env.new\python.exe")
        path = self.scripts / name
        path.write_bytes(launcher_bytes(old, **kwargs))
        self.rows.append(
            ["../../Scripts/" + name, runtime._digest(path.read_bytes()), str(path.stat().st_size)]
        )
        self.write_record()
        return path

    def write_record(self):
        with self.record.open("w", encoding="utf-8", newline="") as stream:
            csv.writer(stream, lineterminator="\n").writerows(
                self.rows + [["sample-1.0.dist-info/RECORD", "", ""]]
            )

    def contents(self):
        return {
            path.relative_to(self.root): path.read_bytes()
            for path in self.root.rglob("*")
            if path.is_file()
        }

    def assert_record_valid(self):
        with self.record.open(encoding="utf-8", newline="") as stream:
            rows = list(csv.reader(stream))
        for name, digest, size in rows:
            if not digest:
                continue
            data = (self.site / name).read_bytes()
            self.assertEqual(digest, runtime._digest(data))
            self.assertEqual(int(size), len(data))

    def test_check_is_read_only_and_reports_pending_files(self):
        self.add_launcher()
        original = self.contents()
        result = runtime.repair_runtime(self.root, check=True)
        self.assertTrue(result["needs_repair"])
        self.assertEqual(result["changed_files"], [])
        self.assertEqual(len(result["pending_files"]), 2)
        self.assertEqual(original, self.contents())

    def test_repair_preserves_native_stub_payload_and_updates_record(self):
        path = self.add_launcher()
        before = path.read_bytes()
        result = runtime.repair_runtime(self.root)
        after = path.read_bytes()
        self.assertEqual(before[:1024], after[:1024])
        with zipfile.ZipFile(io.BytesIO(before)) as old, zipfile.ZipFile(io.BytesIO(after)) as new:
            self.assertEqual(old.read("__main__.py"), new.read("__main__.py"))
        expected = ("#!" + chr(34) + str(self.python) + chr(34) + "\n").encode("utf-8")
        self.assertEqual(after[1024 : 1024 + len(expected)], expected)
        self.assertEqual(len(result["changed_files"]), 2)
        self.assertFalse(result["needs_repair"])
        self.assert_record_valid()
        self.assertEqual(list(self.root.glob(".runtime-relocation*")), [])

    def test_gui_and_pip_aliases_are_rebased(self):
        paths = [self.add_launcher(name) for name in ("pip.exe", "pip3.exe", "pip3.12.exe")]
        gui = self.add_launcher(
            "sample-gui.exe",
            gui=True,
            old_python=chr(34) + r"C:\older żółć\env.new\pythonw.exe" + chr(34),
        )
        runtime.repair_runtime(self.root)
        for path in paths:
            self.assertIn(str(self.python).encode(), path.read_bytes())
        self.assertIn(str(self.python.with_name("pythonw.exe")).encode(), gui.read_bytes())
        self.assert_record_valid()

    def test_supported_distlib_template_versions(self):
        for variant in ("legacy", "inline", "modern"):
            self.add_launcher(variant + ".exe", variant=variant)
        self.assertEqual(len(runtime.repair_runtime(self.root)["changed_files"]), 4)
        self.assert_record_valid()

    def test_second_run_is_idempotent(self):
        self.add_launcher()
        runtime.repair_runtime(self.root)
        first = self.contents()
        result = runtime.repair_runtime(self.root)
        self.assertEqual(result["changed_files"], [])
        self.assertEqual(first, self.contents())

    def test_unowned_executable_is_not_touched(self):
        path = self.scripts / "unrelated.exe"
        path.write_bytes(launcher_bytes(r"C:\unrelated\python.exe"))
        original = path.read_bytes()
        self.assertEqual(runtime.repair_runtime(self.root)["changed_files"], [])
        self.assertEqual(path.read_bytes(), original)

    def test_owned_native_executable_is_not_touched(self):
        path = self.add_launcher()
        path.write_bytes(b"MZ" + b"native program" * 25)
        self.rows[0][1:] = [runtime._digest(path.read_bytes()), str(path.stat().st_size)]
        self.write_record()
        original = self.contents()
        result = runtime.repair_runtime(self.root)
        self.assertEqual(result["changed_files"], [])
        self.assertEqual(result["skipped_native_files"], [str(path.relative_to(self.root))])
        self.assertEqual(self.contents(), original)

    def test_unrecognized_python_body_fails_before_any_write(self):
        self.add_launcher("first.exe")
        self.add_launcher("unknown.exe", body="print('not a generated entry point')\n")
        before = self.contents()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "body does not match"):
            runtime.repair_runtime(self.root)
        self.assertEqual(before, self.contents())

    def test_malformed_zip_fails_closed(self):
        path = self.add_launcher()
        path.write_bytes(path.read_bytes()[:-12])
        self.rows[0][1:] = [runtime._digest(path.read_bytes()), str(path.stat().st_size)]
        self.write_record()
        before = self.contents()
        with self.assertRaises(runtime.RuntimeRepairError):
            runtime.repair_runtime(self.root)
        self.assertEqual(before, self.contents())

    def test_invalid_pe_boundary_fails_closed(self):
        path = self.add_launcher()
        data = bytearray(path.read_bytes())
        struct.pack_into("<I", data, 60, 0xFFFFFFFF)
        path.write_bytes(data)
        before = self.contents()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "PE"):
            runtime.repair_runtime(self.root)
        self.assertEqual(before, self.contents())

    def test_hash_mismatch_preserves_modified_launcher(self):
        path = self.add_launcher()
        self.rows[0][1] = "sha256=" + "A" * 43
        self.write_record()
        original = path.read_bytes()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "differs from its RECORD"):
            runtime.repair_runtime(self.root)
        self.assertEqual(path.read_bytes(), original)

    def test_size_mismatch_preserves_modified_launcher(self):
        self.add_launcher()
        self.rows[0][2] = "1"
        self.write_record()
        before = self.contents()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "size differs"):
            runtime.repair_runtime(self.root)
        self.assertEqual(before, self.contents())

    def test_unknown_interpreter_is_not_rewritten(self):
        self.add_launcher(old_python=r"C:\tools\custom-runtime.exe")
        before = self.contents()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "expected absolute Python"):
            runtime.repair_runtime(self.root)
        self.assertEqual(before, self.contents())

    def test_record_path_outside_runtime_is_not_opened(self):
        outside = self.scratch / "outside.exe"
        outside.write_bytes(b"not runtime data")
        self.rows = [["../../../outside.exe", "sha256=invalid", "100"]]
        self.write_record()
        result = runtime.repair_runtime(self.root)
        self.assertEqual(result["changed_files"], [])
        self.assertEqual(outside.read_bytes(), b"not runtime data")

    def test_redirecting_launcher_is_rejected(self):
        path = self.add_launcher()
        original = runtime._redirects
        with mock.patch.object(
            runtime, "_redirects", side_effect=lambda item: item == path or original(item)
        ):
            with self.assertRaisesRegex(runtime.RuntimeRepairError, "redirecting link"):
                runtime.repair_runtime(self.root)

    def test_dangling_launcher_link_is_rejected_before_opening_target(self):
        path = self.add_launcher()
        path.unlink()
        original = Path.lstat

        def dangling_metadata(target, *args, **kwargs):
            if target == path:
                return SimpleNamespace(st_mode=stat.S_IFLNK, st_reparse_tag=0)
            return original(target, *args, **kwargs)

        with mock.patch.object(Path, "lstat", new=dangling_metadata):
            with self.assertRaisesRegex(runtime.RuntimeRepairError, "redirecting link"):
                runtime.repair_runtime(self.root)
        self.assertFalse(path.exists())

    def test_redirecting_site_directory_is_rejected(self):
        self.add_launcher()
        original = runtime._redirects
        with mock.patch.object(
            runtime, "_redirects", side_effect=lambda item: item == self.site or original(item)
        ):
            with self.assertRaisesRegex(runtime.RuntimeRepairError, "redirecting link"):
                runtime.repair_runtime(self.root)

    def test_other_runtime_cannot_be_selected(self):
        self.add_launcher()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "belonging"):
            runtime.repair_runtime(self.scratch)

    def test_missing_gui_python_prevents_all_changes(self):
        self.add_launcher("console.exe")
        self.add_launcher("gui.exe", gui=True, old_python=r"C:\old\pythonw.exe")
        self.python.with_name("pythonw.exe").unlink()
        before = self.contents()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "Required interpreter is missing"):
            runtime.repair_runtime(self.root)
        self.assertEqual(before, self.contents())

    def test_redirecting_gui_interpreter_is_rejected(self):
        self.add_launcher("gui.exe", gui=True, old_python=r"C:\old\pythonw.exe")
        original = runtime._redirects
        target = self.python.with_name("pythonw.exe")
        with mock.patch.object(
            runtime, "_redirects", side_effect=lambda path: path == target or original(path)
        ):
            with self.assertRaisesRegex(runtime.RuntimeRepairError, "redirecting link"):
                runtime.repair_runtime(self.root)

    def test_unhashed_record_entry_gains_valid_hash(self):
        self.add_launcher()
        self.rows[0][1:] = ["", ""]
        self.write_record()
        runtime.repair_runtime(self.root)
        self.assert_record_valid()
        with self.record.open(encoding="utf-8", newline="") as stream:
            self.assertTrue(next(csv.reader(stream))[1].startswith("sha256="))

    def test_staging_shebang_with_literal_hash_bang_in_path(self):
        path = self.add_launcher(old_python=chr(34) + r"C:\old#! unicode ż\python.exe" + chr(34))
        runtime.repair_runtime(self.root)
        self.assertIn(str(self.python).encode("utf-8"), path.read_bytes())
        self.assert_record_valid()

    def add_activation(self):
        (self.root / "pyvenv.cfg").write_bytes(
            b"home = C:\\base-python\r\nexecutable = C:\\base-python\\python.exe\r\n"
        )
        (self.scripts / "activate.bat").write_bytes(
            b'@echo off\r\nset "VIRTUAL_ENV=C:\\old\\venv.new"\r\n'
            b'set _OLD_VIRTUAL_PATH=%PATH%\r\nset "PATH=%VIRTUAL_ENV%\\Scripts;%PATH%"\r\n'
        )
        (self.scripts / "activate").write_text(
            "_OLD_VIRTUAL_PATH=\n"
            "        VIRTUAL_ENV=$(cygpath 'C:/old/venv.new')\n"
            "        export VIRTUAL_ENV='C:/old/venv.new'\n",
            encoding="utf-8",
        )

    def test_activation_paths_and_apostrophes_preserve_base_configuration(self):
        self.add_activation()
        config = (self.root / "pyvenv.cfg").read_bytes()
        result = runtime.repair_runtime(self.root)
        self.assertEqual(len(result["changed_files"]), 2)
        batch = (self.scripts / "activate.bat").read_bytes()
        self.assertIn(b'for %%I in ("%~dp0..") do set "VIRTUAL_ENV=%%~fI"\r\n', batch)
        self.assertNotIn(b"venv.new", batch)
        escaped = "'" + chr(34) + "'" + chr(34) + "'"
        self.assertIn(
            str(self.root).replace("'", escaped),
            (self.scripts / "activate").read_text(encoding="utf-8"),
        )
        self.assertEqual((self.root / "pyvenv.cfg").read_bytes(), config)
        self.assertEqual(runtime.repair_runtime(self.root)["changed_files"], [])

    def test_activation_malformed_assignment_is_not_overwritten(self):
        self.add_activation()
        path = self.scripts / "activate.bat"
        path.write_bytes(b"_OLD_VIRTUAL_PATH\ncustom activation instructions\n")
        before = self.contents()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "Unknown activation"):
            runtime.repair_runtime(self.root)
        self.assertEqual(self.contents(), before)

    def test_supported_cpython_activation_layouts_are_rebased(self):
        # CPython 3.10.11/3.11.9 use a single double-quoted assignment;
        # 3.13.0 uses two double-quoted branches, newer builds single quotes.
        self.add_activation()
        path = self.scripts / "activate"
        for layout in (
            'VIRTUAL_ENV="C:/old/venv.new"\nexport VIRTUAL_ENV\n',
            '        VIRTUAL_ENV=$(cygpath "C:/old/venv.new")\n'
            '        export VIRTUAL_ENV="C:/old/venv.new"\n',
        ):
            with self.subTest(layout=layout):
                path.write_bytes(("_OLD_VIRTUAL_PATH=\n" + layout).encode("utf-8"))
                config = (self.root / "pyvenv.cfg").read_bytes()
                result = runtime.repair_runtime(self.root)
                self.assertIn(str(path.relative_to(self.root)), result["changed_files"])
                self.assertNotIn(b"venv.new", path.read_bytes())
                self.assertEqual((self.root / "pyvenv.cfg").read_bytes(), config)
                self.assertEqual(runtime.repair_runtime(self.root)["changed_files"], [])

    def test_incomplete_or_mixed_activation_layout_is_preserved(self):
        self.add_activation()
        path = self.scripts / "activate"
        for layout in (
            'VIRTUAL_ENV="C:/old/venv.new"\n',
            'export VIRTUAL_ENV="C:/old/venv.new"\n',
            'VIRTUAL_ENV="C:/old/venv.new"\nexport VIRTUAL_ENV\n'
            '        export VIRTUAL_ENV="C:/old/venv.new"\n',
            '        VIRTUAL_ENV=$(cygpath "C:/one")\n        export VIRTUAL_ENV="C:/two"\n',
        ):
            with self.subTest(layout=layout):
                path.write_bytes(("_OLD_VIRTUAL_PATH=\n" + layout).encode("utf-8"))
                before = self.contents()
                with self.assertRaisesRegex(runtime.RuntimeRepairError, "Unknown activation"):
                    runtime.repair_runtime(self.root)
                self.assertEqual(self.contents(), before)

    def test_failure_rolls_back_scripts_and_records(self):
        self.add_launcher("one.exe")
        self.add_launcher("two.exe")
        before = self.contents()
        replace = runtime._atomic_replace
        calls = 0

        def fail_second(root, change, data):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise PermissionError("synthetic locked executable")
            return replace(root, change, data)

        with mock.patch.object(runtime, "_atomic_replace", side_effect=fail_second):
            with self.assertRaisesRegex(runtime.RuntimeRepairError, "rolled back"):
                runtime.repair_runtime(self.root)
        self.assertEqual(self.contents(), before)
        self.assertEqual(list(self.root.glob(".runtime-relocation*")), [])

    def test_rollback_failure_keeps_recovery_copies(self):
        self.add_launcher("one.exe")
        self.add_launcher("two.exe")
        before = self.contents()
        replace = runtime._atomic_replace
        calls = 0

        def fail_after_first(root, change, data):
            nonlocal calls
            calls += 1
            if calls > 1:
                raise PermissionError("synthetic rollback lock")
            return replace(root, change, data)

        with mock.patch.object(runtime, "_atomic_replace", side_effect=fail_after_first):
            with self.assertRaisesRegex(
                runtime.RuntimeRepairError, "Incomplete rollback.*Recovery copies"
            ):
                runtime.repair_runtime(self.root)
        backups = list(self.root.glob(".runtime-relocation-backup-*"))
        self.assertEqual(len(backups), 1)
        manifest = json.loads((backups[0] / "manifest.json").read_text(encoding="utf-8"))
        for entry in manifest:
            self.assertEqual(
                (backups[0] / entry["backup"]).read_bytes(), before[Path(entry["path"])]
            )
        retained = self.contents()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "earlier runtime repair"):
            runtime.repair_runtime(self.root)
        self.assertEqual(self.contents(), retained)

    def test_interrupted_repair_backup_is_never_discarded(self):
        self.add_launcher()
        backup = self.root / (".runtime-relocation-backup-" + "a" * 32)
        backup.mkdir()
        (backup / "0000.bin").write_bytes(b"interrupted original")
        before = self.contents()
        with self.assertRaisesRegex(runtime.RuntimeRepairError, "earlier runtime repair"):
            runtime.repair_runtime(self.root, check=True)
        self.assertEqual(self.contents(), before)

    def test_atomic_failure_after_record_change_restores_all_hashes(self):
        self.add_launcher()
        before = self.contents()
        replace = runtime._atomic_replace

        def fail_after_record(root, change, data):
            result = replace(root, change, data)
            if change.path == self.record and data == change.after:
                raise PermissionError("synthetic interruption after RECORD replacement")
            return result

        with mock.patch.object(runtime, "_atomic_replace", side_effect=fail_after_record):
            with self.assertRaisesRegex(runtime.RuntimeRepairError, "rolled back"):
                runtime.repair_runtime(self.root)
        self.assertEqual(self.contents(), before)
        self.assert_record_valid()

    def test_concurrent_external_change_is_preserved(self):
        self.add_launcher("one.exe")
        second = self.add_launcher("two.exe")
        first_before = (self.scripts / "one.exe").read_bytes()
        record_before = self.record.read_bytes()
        replace = runtime._atomic_replace
        called = False

        def external_change(root, change, data):
            nonlocal called
            result = replace(root, change, data)
            if not called:
                called = True
                second.write_bytes(b"external modification")
            return result

        with mock.patch.object(runtime, "_atomic_replace", side_effect=external_change):
            with self.assertRaisesRegex(runtime.RuntimeRepairError, "changed during repair"):
                runtime.repair_runtime(self.root)
        self.assertEqual(second.read_bytes(), b"external modification")
        self.assertEqual((self.scripts / "one.exe").read_bytes(), first_before)
        self.assertEqual(self.record.read_bytes(), record_before)

    def test_missing_mode_is_rejected_by_cli(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
            runtime.main(["--root", str(self.root), "--json"])
        self.assertEqual(caught.exception.code, 2)

    def test_json_check_output_is_ascii_and_read_only(self):
        self.add_launcher()
        before = self.contents()
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            code = runtime.main(["--root", str(self.root), "--check", "--json"])
        self.assertEqual(code, 0)
        self.assertTrue(stream.getvalue().isascii())
        self.assertTrue(json.loads(stream.getvalue())["needs_repair"])
        self.assertEqual(before, self.contents())


if __name__ == "__main__":
    unittest.main()
