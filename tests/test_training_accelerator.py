"""Placement regressions independent of GPU hardware and model downloads."""

from unittest.mock import Mock, patch

import pytest
from accelerate.utils import DistributedType

from omnivoice.training.accelerator import prepare_training_objects


@pytest.mark.parametrize("placement", [True, False])
def test_without_distributed_uses_explicit_placement(placement):
    accelerator = Mock(distributed_type=DistributedType.NO, device_placement=placement)
    objects = (object(), object(), None)
    with patch("torch.distributed.is_available", return_value=False):
        result = prepare_training_objects(accelerator, *objects)
    accelerator.prepare.assert_called_once_with(*objects, device_placement=[placement] * 3)
    assert result is accelerator.prepare.return_value


def test_distributed_build_keeps_upstream_placement():
    accelerator = Mock(distributed_type=DistributedType.FSDP)
    model = object()
    with patch("torch.distributed.is_available", return_value=True):
        prepare_training_objects(accelerator, model)
    accelerator.prepare.assert_called_once_with(model)


def test_missing_distributed_build_does_not_fake_multi_gpu_support():
    accelerator = Mock(distributed_type=DistributedType.MULTI_GPU)
    with (
        patch("torch.distributed.is_available", return_value=False),
        pytest.raises(RuntimeError, match="does not support distributed training"),
    ):
        prepare_training_objects(accelerator, object())
    accelerator.prepare.assert_not_called()


def test_real_prepare_errors_are_not_hidden():
    accelerator = Mock(distributed_type=DistributedType.NO, device_placement=True)
    accelerator.prepare.side_effect = ValueError("bad model")
    with (
        patch("torch.distributed.is_available", return_value=False),
        pytest.raises(ValueError, match="bad model"),
    ):
        prepare_training_objects(accelerator, object())
