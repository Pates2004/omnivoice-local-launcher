"""Exercise real distlib launchers only inside a disposable Python under trash.

Run with that disposable interpreter and --root pointing at its sys.prefix.
Creates a uniquely named synthetic helper package; no SDK/package download,
system-runtime edit, model import, or GPU operation takes place.
"""

from __future__ import annotations

import argparse
import base64
import csv
import hashlib
import json
import subprocess
import sys
import uuid
from pathlib import Path


def _hash(data: bytes) -> str:
    return "sha256=" + base64.urlsafe_b64encode(hashlib.sha256(data).digest()).decode().rstrip("=")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    args = parser.parse_args()
    project = Path(__file__).resolve().parents[1]
    root = args.root.resolve(strict=True)
    if not root.is_relative_to(project / "trash") or root != Path(sys.prefix).resolve():
        raise RuntimeError(
            "This smoke test requires an explicitly selected disposable Python under trash."
        )
    from pip._vendor.distlib.scripts import ScriptMaker

    key = uuid.uuid4().hex
    module_name = "relocation_fixture_" + key
    command = "offload-arch-fixture-" + key
    site = root / "Lib" / "site-packages"
    metadata = site / (module_name + "-0.dist-info")
    metadata.mkdir()
    source = site / (module_name + ".py")
    source.write_text(
        "def main():\n    print('synthetic-native-helper-entry-point-ok')\n    return 0\n",
        encoding="utf-8",
    )
    entry = metadata / "entry_points.txt"
    entry.write_text(f"[console_scripts]\n{command}={module_name}:main\n", encoding="utf-8")
    meta = metadata / "METADATA"
    meta.write_text(f"Metadata-Version: 2.1\nName: {module_name}\nVersion: 0\n", encoding="utf-8")
    maker = ScriptMaker(None, str(root / "Scripts"))
    maker.executable = str(root / ".missing-staging-interpreter" / "python.exe")
    maker.variants = {""}
    generated = [Path(path) for path in maker.make(f"{command} = {module_name}:main")]
    executable = root / "Scripts" / (command + ".exe")
    if generated != [executable]:
        raise RuntimeError(f"Unexpected fixture entry point: {generated}")
    record = metadata / "RECORD"
    with record.open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream, lineterminator="\n")
        for path in (source, entry, meta, executable):
            relative = (
                "../../Scripts/" + path.name
                if path.parent == root / "Scripts"
                else path.relative_to(site).as_posix()
            )
            contents = path.read_bytes()
            writer.writerow([relative, _hash(contents), str(len(contents))])
        writer.writerow([record.relative_to(site).as_posix(), "", ""])

    def run(*command_parts):
        return subprocess.run(command_parts, capture_output=True, text=True, timeout=30)

    native = root / "Scripts" / "ruff.exe"
    native_hash = _hash(native.read_bytes()) if native.exists() else None
    before = run(str(executable))
    if before.returncode == 0:
        raise AssertionError("The stale-interpreter fixture unexpectedly ran.")
    helper = project / "installer_runtime.py"
    repaired = run(
        sys.executable, "-I", "-B", str(helper), "--root", str(root), "--repair", "--json"
    )
    if repaired.returncode:
        raise RuntimeError(repaired.stdout + repaired.stderr)
    details = json.loads(repaired.stdout)
    assert str(executable.relative_to(root)) in details["changed_files"]
    after = run(str(executable))
    assert after.returncode == 0, after.stderr
    assert after.stdout.strip() == "synthetic-native-helper-entry-point-ok"
    checked = run(sys.executable, "-I", "-B", str(helper), "--root", str(root), "--check", "--json")
    assert checked.returncode == 0 and not json.loads(checked.stdout)["needs_repair"]
    versioned_pip = f"pip{sys.version_info.major}.{sys.version_info.minor}.exe"
    for name in ("pip.exe", "pip3.exe", versioned_pip):
        result = run(str(root / "Scripts" / name), "--version")
        assert result.returncode == 0 and "pip " in result.stdout, (name, result.stderr)
    with record.open(encoding="utf-8", newline="") as stream:
        for relative, checksum, size in csv.reader(stream):
            if checksum:
                contents = (site / relative).read_bytes()
                assert checksum == _hash(contents) and int(size) == len(contents)
    if native_hash is not None:
        assert _hash(native.read_bytes()) == native_hash
    assert not list(root.glob(".runtime-relocation-backup-*"))
    print(
        json.dumps(
            {
                "ok": True,
                "fixture": command,
                "stale_exit": before.returncode,
                "repaired_exit": after.returncode,
                "pip_aliases": "passed",
                "record_hashes": "passed",
                "native_executable": "unchanged",
                "repeat_check": "no repair needed",
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
