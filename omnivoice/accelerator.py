"""Backend-neutral accelerator detection, validation, and diagnostics.

ROCm deliberately uses PyTorch's ``torch.cuda`` API and the ``cuda:0`` device
string.  The backend name describes the installed runtime; it is not a torch
device type.
"""

from __future__ import annotations

import argparse
import ctypes
import importlib.metadata
import json
import os
import platform
import sys
from dataclasses import asdict, dataclass
from typing import Any


@dataclass(frozen=True)
class AcceleratorInfo:
    backend: str
    device: str
    name: str
    torch_version: str
    runtime_version: str | None


def _torch(torch_module=None):
    if torch_module is not None:
        return torch_module
    import torch

    return torch


def _version_attribute(torch_module, name: str) -> str | None:
    value = getattr(getattr(torch_module, "version", None), name, None)
    return str(value) if value is not None else None


def _xpu_name(torch_module) -> str:
    try:
        return str(torch_module.xpu.get_device_name(0))
    except (AttributeError, RuntimeError):
        try:
            return str(torch_module.xpu.get_device_properties(0).name)
        except (AttributeError, RuntimeError):
            return "Intel GPU"


def detect_accelerator(torch_module=None) -> AcceleratorInfo:
    """Return the usable runtime backend without guessing the GPU vendor."""
    torch_module = _torch(torch_module)
    torch_version = str(torch_module.__version__)
    hip_version = _version_attribute(torch_module, "hip")
    cuda_version = _version_attribute(torch_module, "cuda")

    if torch_module.cuda.is_available():
        if hip_version is not None:
            return AcceleratorInfo(
                backend="rocm",
                device="cuda:0",
                name=str(torch_module.cuda.get_device_name(0)),
                torch_version=torch_version,
                runtime_version=hip_version,
            )
        if cuda_version is not None:
            return AcceleratorInfo(
                backend="cuda",
                device="cuda:0",
                name=str(torch_module.cuda.get_device_name(0)),
                torch_version=torch_version,
                runtime_version=cuda_version,
            )

    xpu = getattr(torch_module, "xpu", None)
    if xpu is not None and xpu.is_available():
        return AcceleratorInfo(
            backend="xpu",
            device="xpu:0",
            name=_xpu_name(torch_module),
            torch_version=torch_version,
            runtime_version=_version_attribute(torch_module, "xpu"),
        )

    return AcceleratorInfo(
        backend="cpu",
        device="cpu",
        name=platform.processor() or "CPU",
        torch_version=torch_version,
        runtime_version=None,
    )


def preferred_dtype(accelerator: AcceleratorInfo, torch_module=None):
    torch_module = _torch(torch_module)
    if accelerator.backend in {"cuda", "rocm", "xpu"}:
        return torch_module.float16
    return torch_module.float32


def empty_accelerator_cache(accelerator: AcceleratorInfo, torch_module=None) -> None:
    torch_module = _torch(torch_module)
    if accelerator.backend in {"cuda", "rocm"} and torch_module.cuda.is_available():
        torch_module.cuda.empty_cache()
    elif accelerator.backend == "xpu" and torch_module.xpu.is_available():
        torch_module.xpu.empty_cache()


def validate_accelerator(expected_backend: str, torch_module=None) -> AcceleratorInfo:
    """Validate the build identity and execute a real matrix multiplication."""
    torch_module = _torch(torch_module)
    expected_backend = expected_backend.lower()
    if expected_backend not in {"cuda", "rocm", "xpu", "cpu"}:
        raise ValueError(f"Unsupported accelerator backend: {expected_backend}")

    detected = detect_accelerator(torch_module)
    if detected.backend != expected_backend:
        raise RuntimeError(
            f"Expected {expected_backend}, but this PyTorch runtime detected {detected.backend}."
        )

    hip_version = _version_attribute(torch_module, "hip")
    cuda_version = _version_attribute(torch_module, "cuda")
    if expected_backend == "cuda" and (cuda_version is None or hip_version is not None):
        raise RuntimeError("The installed PyTorch build is not a valid NVIDIA CUDA build.")
    if expected_backend == "rocm" and (hip_version is None or cuda_version is not None):
        raise RuntimeError("The installed PyTorch build is not a valid AMD ROCm build.")
    if expected_backend == "xpu" and (hip_version is not None or cuda_version is not None):
        raise RuntimeError("The installed PyTorch build is not a valid Intel XPU build.")
    if expected_backend == "cpu" and (hip_version is not None or cuda_version is not None):
        raise RuntimeError("The installed PyTorch build is not CPU-only.")

    dtype = preferred_dtype(detected, torch_module)
    x = torch_module.randn((64, 64), device=detected.device, dtype=dtype)
    y = x @ x
    if expected_backend in {"cuda", "rocm"}:
        torch_module.cuda.synchronize()
        if not bool(y.is_cuda):
            raise RuntimeError("The accelerator smoke-test result is not on a CUDA/HIP device.")
    elif expected_backend == "xpu":
        torch_module.xpu.synchronize()
        if getattr(y.device, "type", None) != "xpu":
            raise RuntimeError("The accelerator smoke-test result is not on an XPU device.")
    elif getattr(y.device, "type", None) != "cpu":
        raise RuntimeError("The CPU smoke-test result is not on the CPU.")

    if not bool(torch_module.isfinite(y).all().item()):
        raise RuntimeError("The accelerator smoke test produced non-finite values.")
    return detected


def _package_version(name: str) -> str:
    try:
        return importlib.metadata.version(name)
    except importlib.metadata.PackageNotFoundError:
        return "not installed"


def _total_ram_gib() -> str:
    try:
        if os.name == "nt":

            class MemoryStatus(ctypes.Structure):
                _fields_ = [
                    ("length", ctypes.c_ulong),
                    ("memory_load", ctypes.c_ulong),
                    ("total_physical", ctypes.c_ulonglong),
                    ("available_physical", ctypes.c_ulonglong),
                    ("total_page_file", ctypes.c_ulonglong),
                    ("available_page_file", ctypes.c_ulonglong),
                    ("total_virtual", ctypes.c_ulonglong),
                    ("available_virtual", ctypes.c_ulonglong),
                    ("available_extended_virtual", ctypes.c_ulonglong),
                ]

            status = MemoryStatus()
            status.length = ctypes.sizeof(status)
            if ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(status)):
                return f"{status.total_physical / 1024**3:.1f} GiB"
        page_size = os.sysconf("SC_PAGE_SIZE")
        pages = os.sysconf("SC_PHYS_PAGES")
        return f"{page_size * pages / 1024**3:.1f} GiB"
    except (AttributeError, OSError, ValueError):
        pass
    return "unknown"


def collect_diagnostics(app_version: str = "unknown", torch_module=None) -> dict[str, Any]:
    torch_module = _torch(torch_module)
    info = detect_accelerator(torch_module)
    acceleration_labels = {
        "cuda": "NVIDIA CUDA",
        "rocm": "AMD ROCm",
        "xpu": "Intel XPU",
        "cpu": "CPU only",
    }
    return {
        "omnivoice_version": app_version,
        "python_version": platform.python_version(),
        "acceleration": acceleration_labels[info.backend],
        "backend": info.backend,
        "device": info.device,
        "device_name": info.name,
        "torch_version": info.torch_version,
        "torchaudio_version": _package_version("torchaudio"),
        "cuda_version": _version_attribute(torch_module, "cuda"),
        "hip_version": _version_attribute(torch_module, "hip"),
        "xpu_available": bool(
            getattr(torch_module, "xpu", None) is not None and torch_module.xpu.is_available()
        ),
        "os": platform.platform(),
        "ram": _total_ram_gib(),
    }


def format_diagnostics(app_version: str = "unknown", torch_module=None) -> str:
    data = collect_diagnostics(app_version, torch_module)
    labels = (
        ("OmniVoice version", "omnivoice_version"),
        ("Python", "python_version"),
        ("Acceleration", "acceleration"),
        ("Backend", "backend"),
        ("Device", "device"),
        ("Device name", "device_name"),
        ("torch", "torch_version"),
        ("torchaudio", "torchaudio_version"),
        ("CUDA", "cuda_version"),
        ("HIP", "hip_version"),
        ("XPU available", "xpu_available"),
        ("OS", "os"),
        ("RAM", "ram"),
    )
    return "\n".join(f"{label}: {data[key]}" for label, key in labels)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Inspect the OmniVoice accelerator runtime.")
    parser.add_argument("--validate", choices=("cuda", "rocm", "xpu", "cpu"))
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    try:
        info = validate_accelerator(args.validate) if args.validate else detect_accelerator()
        payload = {
            "ok": True,
            **asdict(info),
            "torchaudio_version": _package_version("torchaudio"),
        }
    except Exception as exc:
        payload = {"ok": False, "error": str(exc), "error_type": type(exc).__name__}
        if args.json:
            print(json.dumps(payload, ensure_ascii=False))
        else:
            print(payload["error"], file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(payload, ensure_ascii=False))
    else:
        print(format_diagnostics())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
