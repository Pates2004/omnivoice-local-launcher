from __future__ import annotations

import ast
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from omnivoice.accelerator import detect_accelerator, validate_accelerator


ROOT = Path(__file__).resolve().parents[1]


class FakeTensor:
    def __init__(self, device: str):
        self.device = SimpleNamespace(type=device.split(":", 1)[0])
        self.is_cuda = self.device.type == "cuda"

    def __matmul__(self, _other):
        return FakeTensor(self.device.type)

    def all(self):
        return self

    def item(self):
        return True


class FakeDeviceApi:
    def __init__(self, available: bool, name: str):
        self.available = available
        self.name = name
        self.synchronized = False

    def is_available(self):
        return self.available

    def get_device_name(self, _index):
        return self.name

    def synchronize(self):
        self.synchronized = True


class FakeTorch:
    __version__ = "2.test"
    float16 = "float16"
    float32 = "float32"

    def __init__(self, *, cuda=None, hip=None, xpu=False):
        self.version = SimpleNamespace(cuda=cuda, hip=hip, xpu="oneAPI" if xpu else None)
        self.cuda = FakeDeviceApi(cuda is not None or hip is not None, "Test CUDA/HIP GPU")
        self.xpu = FakeDeviceApi(xpu, "Test Intel Arc")

    @staticmethod
    def randn(_shape, device, dtype):
        del dtype
        return FakeTensor(device)

    @staticmethod
    def isfinite(tensor):
        return tensor


@pytest.mark.parametrize(
    ("runtime", "backend", "device"),
    [
        (FakeTorch(cuda="13.0"), "cuda", "cuda:0"),
        (FakeTorch(hip="7.2.1"), "rocm", "cuda:0"),
        (FakeTorch(xpu=True), "xpu", "xpu:0"),
        (FakeTorch(), "cpu", "cpu"),
    ],
)
def test_backend_detection_and_tensor_validation(runtime, backend, device):
    detected = detect_accelerator(runtime)
    assert (detected.backend, detected.device) == (backend, device)
    assert validate_accelerator(backend, runtime).backend == backend


def test_runtime_build_mismatch_is_rejected():
    with pytest.raises(RuntimeError, match="Expected rocm"):
        validate_accelerator("rocm", FakeTorch(cuda="13.0"))


def test_xpu_build_without_intel_gpu_is_not_a_cpu_build():
    runtime = FakeTorch()
    runtime.__version__ = "2.11.0+xpu"
    with pytest.raises(RuntimeError, match="not CPU-only"):
        validate_accelerator("cpu", runtime)


def test_backend_matrix_is_complete_and_pyproject_is_backend_neutral():
    matrix = json.loads((ROOT / "installer_backends.json").read_text(encoding="utf-8"))
    assert set(matrix["profiles"]) == {"cuda", "rocm", "xpu", "cpu"}
    assert matrix["profiles"]["rocm"]["python_min"] == "3.12"
    assert matrix["profiles"]["xpu"]["index_url"].endswith("/whl/xpu")

    metadata = (ROOT / "pyproject.toml").read_text(encoding="utf-8")
    assert "[tool.uv.sources]" not in metadata
    assert "download.pytorch.org/whl/cu" not in metadata

    requirements = (ROOT / "requirements-launcher.txt").read_text(encoding="utf-8")
    dependency_lines = [
        line.strip().lower()
        for line in requirements.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    assert not any(line.startswith(("torch", "torchaudio")) for line in dependency_lines)


@pytest.mark.parametrize("relative_path", ["cli/demo.py", "cli/infer.py", "cli/infer_batch.py"])
def test_inference_entry_points_use_portable_dtype_and_sdpa(relative_path):
    tree = ast.parse((ROOT / "omnivoice" / relative_path).read_text(encoding="utf-8"))
    calls = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "from_pretrained"
    ]
    assert calls
    model_load = next(
        call for call in calls if any(keyword.arg == "device_map" for keyword in call.keywords)
    )
    keywords = {keyword.arg: keyword.value for keyword in model_load.keywords}
    assert isinstance(keywords["dtype"], ast.Call)
    assert ast.unparse(keywords["dtype"].func) == "get_preferred_dtype"
    assert ast.literal_eval(keywords["attn_implementation"]) == "sdpa"
