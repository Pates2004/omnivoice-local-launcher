"""Repair generated Windows entry points after an owned runtime is relocated.

Only metadata-owned distlib launchers with a recognized generated Python body are
changed. Native executables, package code, and the base interpreter configuration
are never rewritten. Run with the managed interpreter, not a system helper::

    env/python.exe -I -B installer_runtime.py --root env --repair --json

Use --check for a read-only plan. This module has no third-party dependencies.
"""

from __future__ import annotations

import argparse
import ast
import base64
import configparser
import csv
import hashlib
import io
import json
import ntpath
import os
import re
import stat
import struct
import sys
import tempfile
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path


class RuntimeRepairError(RuntimeError):
    """A repair was rejected or rolled back; recovery copies may be retained."""


@dataclass(frozen=True)
class Change:
    path: Path
    before: bytes
    after: bytes
    mode: int


def _redirects(path: Path) -> bool:
    info = path.lstat()
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_reparse_tag", 0) & 0x20000000)


def _checked_path(root: Path, path: Path, *, directory: bool = False) -> Path:
    """Reject traversal and redirecting links before opening a runtime member."""
    absolute = Path(os.path.abspath(path))
    try:
        relative = absolute.relative_to(root)
    except ValueError as exc:
        raise RuntimeRepairError(f"Path is outside the managed runtime: {path}") from exc
    current = root
    for part in relative.parts:
        current /= part
        if _redirects(current):
            raise RuntimeRepairError(f"Runtime member is a redirecting link: {current}")
    if directory:
        valid = absolute.is_dir()
    else:
        valid = absolute.is_file()
    if not valid or not absolute.resolve().is_relative_to(root):
        raise RuntimeRepairError(f"Unexpected runtime member: {absolute}")
    return absolute


def _runtime_root(root: Path) -> tuple[Path, Path]:
    original = Path(os.path.abspath(root))
    if _redirects(original):
        raise RuntimeRepairError("The runtime root must not be a redirecting link.")
    root = original.resolve(strict=True)
    if root == Path(root.anchor) or root != Path(sys.prefix).resolve():
        raise RuntimeRepairError("Run this helper with the interpreter belonging to --root.")
    python = Path(sys.executable).resolve(strict=True)
    if python not in (root / "python.exe", root / "Scripts" / "python.exe"):
        raise RuntimeRepairError("The current interpreter is not a managed Windows Python.")
    _checked_path(root, python)
    _checked_path(root, root / "Scripts", directory=True)
    _checked_path(root, root / "Lib" / "site-packages", directory=True)
    return root, python


def _entry_bodies(value: str) -> set[str]:
    match = re.fullmatch(
        r"\s*([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*):"
        r"([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*(?:\[[\w., -]+\])?\s*",
        value,
    )
    if match is None:
        return set()
    module, function = match.groups()
    statement = f"from {module} import {function.split('.')[0]}"
    bodies = []
    for inline_import in (False, True):
        bodies.append(
            "import re\nimport sys\n"
            + ("" if inline_import else statement + "\n")
            + "if __name__ == '__main__':\n"
            + ("    " + statement + "\n" if inline_import else "")
            + "    sys.argv[0] = re.sub(r'(-script\\.pyw|\\.exe)?$', '', sys.argv[0])\n"
            + f"    sys.exit({function}())\n"
        )
    bodies.append(
        "import sys\n" + statement + "\nif __name__ == '__main__':\n"
        "    sys.argv[0] = sys.argv[0].removesuffix('.exe')\n" + f"    sys.exit({function}())\n"
    )
    return {ast.dump(ast.parse(body), include_attributes=False) for body in bodies}


def _pe_layout(stub: bytes) -> tuple[int, int]:
    """Return the exact native-image boundary and PE subsystem."""
    if len(stub) < 64 or stub[:2] != b"MZ":
        raise RuntimeRepairError("Not a PE script launcher.")
    offset = struct.unpack_from("<I", stub, 60)[0]
    if offset < 64 or offset + 24 > len(stub) or stub[offset : offset + 4] != b"PE\0\0":
        raise RuntimeRepairError("Invalid PE script launcher header.")
    machine, sections = struct.unpack_from("<HH", stub, offset + 4)
    optional_size, characteristics = struct.unpack_from("<HH", stub, offset + 20)
    optional = offset + 24
    table = optional + optional_size
    if (
        machine not in (0x14C, 0x8664, 0xAA64)
        or not characteristics & 2
        or not 0 < sections <= 96
        or optional_size < 72
        or table + sections * 40 > len(stub)
        or struct.unpack_from("<H", stub, optional)[0] not in (0x10B, 0x20B)
    ):
        raise RuntimeRepairError("Unsupported PE script launcher structure.")
    end = struct.unpack_from("<I", stub, optional + 60)[0]
    for section in range(sections):
        size, start = struct.unpack_from("<II", stub, table + section * 40 + 16)
        end = max(end, start + size)
    if not table + sections * 40 <= end <= len(stub):
        raise RuntimeRepairError("Invalid native-image boundary in script launcher.")
    subsystem = struct.unpack_from("<H", stub, optional + 68)[0]
    if subsystem not in (2, 3):
        raise RuntimeRepairError("Unsupported PE launcher subsystem.")
    return end, subsystem


def _rewrite_launcher(data: bytes, bodies: dict[str, set[str]], python: Path) -> bytes | None:
    """Return a rebased known wrapper, or None for an ordinary native executable."""
    if not zipfile.is_zipfile(io.BytesIO(data)):
        if re.search(rb'#![^\r\n\0]{1,1000}pythonw?\.exe"?\r?\nPK', data):
            raise RuntimeRepairError("Malformed Python launcher ZIP payload.")
        return None
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as archive:
            entries = archive.infolist()
            if len(entries) != 1 or entries[0].filename != "__main__.py":
                raise RuntimeRepairError("Unknown executable ZIP payload; not rewriting it.")
            entry = entries[0]
            if entry.file_size > 65536 or entry.flag_bits & 1:
                raise RuntimeRepairError("Unsupported executable Python payload.")
            body = ast.dump(
                ast.parse(archive.read(entry).decode("utf-8-sig")), include_attributes=False
            )
            zip_start = entry.header_offset
    except (OSError, ValueError, SyntaxError, UnicodeError, zipfile.BadZipFile) as exc:
        raise RuntimeRepairError("Cannot validate the generated Python launcher.") from exc
    prefix = data[:zip_start]
    line_start, subsystem = _pe_layout(prefix)
    if (
        prefix[line_start : line_start + 2] != b"#!"
        or data[zip_start : zip_start + 4] != b"PK\x03\x04"
    ):
        raise RuntimeRepairError("Executable has no recognized distlib interpreter line.")
    group = "gui_scripts" if subsystem == 2 else "console_scripts"
    if body not in bodies[group]:
        raise RuntimeRepairError("Executable body does not match its distribution entry points.")
    try:
        line = prefix[line_start:].decode("utf-8")
    except UnicodeError as exc:
        raise RuntimeRepairError("Unknown launcher interpreter encoding.") from exc
    match = re.fullmatch(r'#!(?:"([^"\r\n]+)"|([^"\r\n]+))\r?\n', line)
    if match is None:
        raise RuntimeRepairError("Unknown launcher interpreter line; not rewriting it.")
    old = match.group(1) or match.group(2)
    name = "pythonw.exe" if group == "gui_scripts" else "python.exe"
    if ntpath.basename(old).lower() != name or not (ntpath.isabs(old) or os.path.isabs(old)):
        raise RuntimeRepairError(
            "Launcher does not target the expected absolute Python interpreter."
        )
    target = str(python.with_name(name))
    if any(char in target for char in '\r\n"\0'):
        raise RuntimeRepairError("The runtime path cannot be safely encoded in a launcher.")
    if not python.with_name(name).is_file():
        raise RuntimeRepairError(f"Required interpreter is missing: {python.with_name(name)}")
    owner = python.parent.parent if python.parent.name.lower() == "scripts" else python.parent
    _checked_path(owner, python.with_name(name))
    if " " in target or "\t" in target:
        target = '"' + target + '"'
    return prefix[:line_start] + b"#!" + target.encode("utf-8") + b"\n" + data[zip_start:]


def _digest(data: bytes) -> str:
    encoded = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b"=")
    return "sha256=" + encoded.decode("ascii")


def _verify_record(data: bytes, checksum: str, size: str) -> None:
    if size and (not size.isdecimal() or int(size) != len(data)):
        raise RuntimeRepairError("Installed launcher size differs from its RECORD.")
    if checksum:
        algorithm, separator, expected = checksum.partition("=")
        if not separator or algorithm not in ("sha256", "sha384", "sha512"):
            raise RuntimeRepairError("Unsupported installed launcher RECORD checksum.")
        actual = base64.urlsafe_b64encode(hashlib.new(algorithm, data).digest()).rstrip(b"=")
        if actual.decode("ascii") != expected:
            raise RuntimeRepairError("Installed launcher differs from its RECORD; preserving it.")


def _activation_changes(root: Path) -> list[Change]:
    if not (root / "pyvenv.cfg").is_file():
        return []
    changes = []
    for name in ("activate.bat", "activate"):
        path = root / "Scripts" / name
        if not path.exists():
            continue
        _checked_path(root, path)
        before = path.read_bytes()
        text = before.decode("utf-8")
        if len(before) > 65536 or "_OLD_VIRTUAL_PATH" not in text:
            raise RuntimeRepairError(f"Unrecognized venv activation script: {path}")
        if name == "activate.bat":
            pattern = r'^set "VIRTUAL_ENV=([^\r\n"]+)"(\r?)$'
            matches = list(re.finditer(pattern, text, re.MULTILINE))
            dynamic = 'for %%I in ("%~dp0..") do set "VIRTUAL_ENV=%%~fI"'
            if not matches and dynamic in text:
                continue
            if len(matches) != 1:
                raise RuntimeRepairError(f"Unknown activation environment assignment: {path}")
            match = matches[0]
            after_text = text[: match.start()] + dynamic + match.group(2) + text[match.end() :]
        else:
            # CPython changed both the layout and quoting of this script across
            # supported releases. Rebase only its known generated assignments,
            # not arbitrary path appearances in custom code or pyvenv.cfg.
            escaped_apostrophe = "'" + chr(34) + "'" + chr(34) + "'"
            value = "'" + str(root).replace("'", escaped_apostrophe) + "'"
            single_literal = r"'(?:[^'\r\n]|" + re.escape(escaped_apostrophe) + r")*'"
            literal = "(?:" + single_literal + r'|"[^"\r\n]+")'
            pattern = (
                r"(?m)^([ \t]*(?:export VIRTUAL_ENV=|VIRTUAL_ENV=\$\(cygpath |VIRTUAL_ENV=))("
                + literal
                + r")(\)?)[ \t]*\r?$"
            )
            matches = list(re.finditer(pattern, text))
            assignments = {(match.group(1).lstrip(), match.group(3)) for match in matches}
            legacy = (
                len(matches) == 1
                and assignments == {("VIRTUAL_ENV=", "")}
                and re.search(r"(?m)^export VIRTUAL_ENV\r?$", text) is not None
            )
            modern = len(matches) == 2 and assignments == {
                ("VIRTUAL_ENV=$(cygpath ", ")"),
                ("export VIRTUAL_ENV=", ""),
            }
            if not (legacy or modern) or len({match.group(2) for match in matches}) != 1:
                raise RuntimeRepairError(f"Unknown activation environment assignments: {path}")
            after_text = re.sub(
                pattern,
                lambda match, replacement=value: (
                    match.group(1)
                    + replacement
                    + match.group(3)
                    + ("\r" if match.group(0).endswith("\r") else "")
                ),
                text,
            )
        after = after_text.encode("utf-8")
        if after != before:
            changes.append(Change(path, before, after, path.stat().st_mode))
    return changes


def plan_repair(root: Path) -> tuple[Path, list[Change], list[str]]:
    root, python = _runtime_root(root)
    retained = [
        path
        for path in root.glob(".runtime-relocation-backup-*")
        if re.fullmatch(r"\.runtime-relocation-backup-[0-9a-f]{32}", path.name)
    ]
    if retained:
        paths = "; ".join(str(path) for path in retained)
        raise RuntimeRepairError(
            f"Recovery copies from an earlier runtime repair remain: {paths}. "
            "Inspect or restore them before continuing; they were not modified."
        )
    site = root / "Lib" / "site-packages"
    scripts = root / "Scripts"
    changes: dict[Path, Change] = {}
    skipped = []
    records = []
    for metadata in sorted(site.glob("*.dist-info")):
        _checked_path(root, metadata, directory=True)
        record = metadata / "RECORD"
        if not record.exists():
            continue
        _checked_path(root, record)
        raw = record.read_bytes()
        rows = list(csv.reader(io.StringIO(raw.decode("utf-8"), newline=""), strict=True))
        if any(len(row) != 3 for row in rows):
            raise RuntimeRepairError(f"Malformed distribution RECORD: {record}")
        bodies: dict[str, set[str]] = {"console_scripts": set(), "gui_scripts": set()}
        entry_file = metadata / "entry_points.txt"
        if entry_file.exists():
            _checked_path(root, entry_file)
            parser = configparser.ConfigParser(interpolation=None)
            parser.optionxform = str
            parser.read_string(entry_file.read_text(encoding="utf-8"))
            for group in bodies:
                if parser.has_section(group):
                    for _, value in parser.items(group):
                        bodies[group].update(_entry_bodies(value))
        records.append((record, raw, rows))
        for row in rows:
            path = Path(os.path.abspath(site / row[0]))
            if path.parent != scripts or path.suffix.lower() != ".exe":
                continue
            try:
                path.lstat()
            except FileNotFoundError:
                continue
            _checked_path(root, path)
            if not any(bodies.values()) or path.stat().st_size > 4 * 1024 * 1024:
                skipped.append(str(path.relative_to(root)))
                continue
            before = path.read_bytes()
            after = _rewrite_launcher(before, bodies, python)
            if after is None:
                skipped.append(str(path.relative_to(root)))
                continue
            _verify_record(before, row[1], row[2])
            if after != before:
                changes[path] = Change(path, before, after, path.stat().st_mode)
    for path, raw, rows in records:
        updated = False
        for row in rows:
            target = Path(os.path.abspath(site / row[0]))
            if target in changes:
                _verify_record(changes[target].before, row[1], row[2])
                row[1:] = [_digest(changes[target].after), str(len(changes[target].after))]
                updated = True
        if updated:
            stream = io.StringIO(newline="")
            csv.writer(stream, lineterminator="\n").writerows(rows)
            changes[path] = Change(
                path, raw, stream.getvalue().encode("utf-8"), path.stat().st_mode
            )
    for change in _activation_changes(root):
        changes[change.path] = change
    return root, list(changes.values()), sorted(set(skipped))


def _atomic_replace(root: Path, change: Change, data: bytes) -> None:
    _checked_path(root, change.path)
    descriptor, name = tempfile.mkstemp(prefix=".runtime-relocation-", dir=change.path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, stat.S_IMODE(change.mode))
        os.replace(temporary, change.path)
    finally:
        if temporary.exists():
            temporary.unlink()


def _discard_backup(root: Path, backup: Path, count: int) -> None:
    for name in [*(f"{index:04d}.bin" for index in range(count)), "manifest.json"]:
        path = backup / name
        if path.exists():
            _checked_path(root, path).unlink()
    _checked_path(root, backup, directory=True).rmdir()


def repair_runtime(root: Path, *, check: bool = False) -> dict:
    root, changes, skipped = plan_repair(root)
    result = {
        "ok": True,
        "needs_repair": bool(changes) if check else False,
        "pending_files": [str(change.path.relative_to(root)) for change in changes]
        if check
        else [],
        "changed_files": []
        if check
        else [str(change.path.relative_to(root)) for change in changes],
        "skipped_native_files": skipped,
        "check_only": check,
        "backup_directory": None,
    }
    if check or not changes:
        return result
    # Recovery copies exist only during the transaction. Preserve them if a
    # rollback cannot restore every original; never discard the only originals.
    backup = root / (".runtime-relocation-backup-" + uuid.uuid4().hex)
    backup.mkdir()
    applied = []
    try:
        manifest = []
        for index, change in enumerate(changes):
            with (backup / f"{index:04d}.bin").open("xb") as stream:
                stream.write(change.before)
                stream.flush()
                os.fsync(stream.fileno())
            manifest.append(
                {
                    "path": str(change.path.relative_to(root)),
                    "backup": f"{index:04d}.bin",
                    "before": _digest(change.before),
                    "after": _digest(change.after),
                }
            )
        with (backup / "manifest.json").open("x", encoding="utf-8") as stream:
            json.dump(manifest, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        for change in changes:
            _checked_path(root, change.path)
            if change.path.read_bytes() != change.before:
                raise RuntimeRepairError(f"Runtime member changed during repair: {change.path}")
            applied.append(change)
            _atomic_replace(root, change, change.after)
    except Exception as exc:
        failures = []
        for change in reversed(applied):
            try:
                _checked_path(root, change.path)
                current = change.path.read_bytes()
                if current == change.before:
                    continue
                if current != change.after:
                    raise RuntimeRepairError(
                        "File changed outside this repair; refusing to overwrite it."
                    )
                _atomic_replace(root, change, change.before)
            except Exception as rollback_error:
                failures.append(f"{change.path}: {rollback_error}")
        if failures:
            raise RuntimeRepairError(
                f"Runtime repair failed: {exc}. Incomplete rollback: {'; '.join(failures)}. "
                f"Recovery copies: {backup}"
            ) from exc
        try:
            _discard_backup(root, backup, len(changes))
        except Exception:
            raise RuntimeRepairError(
                f"Runtime repair rolled back: {exc}. Recovery copies: {backup}"
            ) from exc
        raise RuntimeRepairError(f"Runtime repair rolled back: {exc}") from exc
    try:
        _discard_backup(root, backup, len(changes))
    except Exception:
        result["backup_directory"] = str(backup)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", "--runtime", dest="runtime", required=True, type=Path)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="Plan repairs without writing any file.")
    mode.add_argument("--repair", action="store_true", help="Apply the checked repair transaction.")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    try:
        result = repair_runtime(args.runtime, check=args.check)
    except Exception as exc:
        result = {"ok": False, "error": str(exc), "error_type": type(exc).__name__}
    if args.json:
        print(json.dumps(result, ensure_ascii=True))
    elif result["ok"]:
        verb = "Would repair" if args.check else "Repaired"
        count = len(result["pending_files"] if args.check else result["changed_files"])
        print(f"{verb} {count} runtime files.")
        if result["backup_directory"]:
            print(f"Recovery copies retained: {result['backup_directory']}")
    else:
        print(result["error"], file=sys.stderr)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
