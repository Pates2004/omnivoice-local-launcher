"""Locations for disposable test fixtures and useful verification artifacts.

These are assistant materials, not application data. Keep application paths
inside the synthetic program directory selected by each test.
"""

from __future__ import annotations

import ctypes
import os
import tempfile
from pathlib import Path


_CATEGORIES = {name.casefold(): name for name in ("Forme", "Workspace", "Trash", "Snapshots")}


def _windows_logical_drives() -> int:
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.GetLogicalDrives.restype = ctypes.c_uint32
    drives = kernel.GetLogicalDrives()
    if not drives:
        raise ctypes.WinError(ctypes.get_last_error())
    return drives


def _work_directory() -> Path:
    if os.name == "nt":
        # D: is preferred based only on its existence. Permission and I/O
        # failures below must remain visible instead of redirecting to C:.
        drive = "D:/" if _windows_logical_drives() & (1 << 3) else "C:/"
        return Path(drive) / "work"
    return Path(tempfile.gettempdir()) / "omnivoice-test-materials"


def material_directory(category: str, project_root: Path | None = None) -> Path:
    """Return a category-first material directory without creating it."""
    canonical = _CATEGORIES.get(category.casefold())
    if canonical is None:
        raise ValueError(f"Unknown assistant material category: {category!r}")
    project = (
        Path(project_root) if project_root is not None else Path(__file__).resolve().parents[1]
    )
    project = project.resolve()
    if not project.name:
        raise ValueError("A project directory is required, not a filesystem root.")
    return _work_directory() / canonical / project.name


def scratch_directory(prefix: str) -> Path:
    """Create a unique synthetic fixture in central Trash; never delete it."""
    if not prefix or any(char in prefix for char in ("/", "\\", ":")):
        raise ValueError("A scratch prefix must be a nonempty filename prefix.")
    parent = material_directory("Trash")
    parent.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix=prefix, dir=parent))
