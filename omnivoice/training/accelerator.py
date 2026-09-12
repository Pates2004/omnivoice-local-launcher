"""Prepare training objects on builds without optional distributed support."""

import torch
from accelerate.utils import DistributedType


def prepare_training_objects(accelerator, *objects):
    """Keep Accelerate defaults, except for non-distributed PyTorch builds.

    Native Windows ROCm wheels can omit c10d. Accelerate 1.15's automatic
    placement probes DTensor unconditionally, importing that missing extension
    even on a single device. Explicit placement uses the public Accelerate API
    without importing DTensor or changing any installed library. Distributed
    builds retain the original FSDP/DeepSpeed placement logic.
    """
    if torch.distributed.is_available():
        return accelerator.prepare(*objects)
    if accelerator.distributed_type != DistributedType.NO:
        raise RuntimeError("This PyTorch build does not support distributed training.")
    return accelerator.prepare(
        *objects, device_placement=[accelerator.device_placement] * len(objects)
    )
