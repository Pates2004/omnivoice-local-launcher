"""Release unused tensor storage after model references have been dropped."""

import gc


def release_memory(device, torch_module=None):
    gc.collect()
    if torch_module is None:
        import torch as torch_module

    kind = str(device).split(":", 1)[0]
    if kind in {"cuda", "xpu"}:
        backend = getattr(torch_module, kind, None)
        if backend is not None and backend.is_initialized():
            with backend.device(device):
                backend.empty_cache()
