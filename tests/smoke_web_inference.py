"""Build the real web UI and exercise its registered callbacks on a real accelerator."""

import argparse
import json
import os
import socket
import sys
import urllib.request
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=("cuda", "rocm", "xpu", "cpu"), required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    # Especially important when another editable OmniVoice checkout is installed.
    sys.path.insert(0, str(root))
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["GRADIO_ANALYTICS_ENABLED"] = "False"
    os.environ["GRADIO_TEMP_DIR"] = str(args.output.resolve() / "gradio-cache")
    args.output.mkdir(parents=True, exist_ok=False)

    import numpy as np
    import soundfile as sf

    import omnivoice
    from omnivoice import OmniVoice
    from omnivoice.cli.demo import build_demo
    from omnivoice.models.omnivoice import WhisperASR

    if (root / "omnisonic").is_dir():
        from omnisonic.accelerator import preferred_dtype, validate_accelerator
    else:
        from omnivoice.accelerator import preferred_dtype, validate_accelerator

    assert Path(omnivoice.__file__).resolve().is_relative_to(root / "omnivoice")
    info = validate_accelerator(args.backend)
    asr = WhisperASR(device=info.device)
    asr.unload_asr_after_transcription = True
    asr.load_asr_model()
    reference, rate = sf.read(args.reference, dtype="float32", always_2d=True)
    assert reference.shape[0] > rate * 30, "This regression needs a reference longer than 30s"
    transcript = asr.transcribe((reference.T, rate))
    assert transcript.strip()
    assert asr._asr_pipe is None
    print("Long reference ASR and Whisper release: OK", flush=True)

    short_reference = args.output / "reference-8s.wav"
    sf.write(short_reference, reference[: rate * 8], rate)
    model = OmniVoice.from_pretrained(
        "k2-fsa/OmniVoice",
        device_map=info.device,
        dtype=preferred_dtype(info),
        attn_implementation="sdpa",
        load_asr=False,
        asr_device=info.device,
    )
    demo = build_demo(model, "k2-fsa/OmniVoice")
    try:
        with socket.socket() as port_reservation:
            port_reservation.bind(("127.0.0.1", 0))
            port = port_reservation.getsockname()[1]
        # Launch the same Gradio server as the entry point, but without a
        # browser and on a temporary loopback port, not the user's port 7860.
        demo.queue().launch(
            server_name="127.0.0.1",
            server_port=port,
            share=False,
            inbrowser=False,
            prevent_thread_lock=True,
            quiet=True,
        )
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/config", timeout=10) as response:
            assert response.status == 200
            assert json.load(response)["components"]
        handlers = {entry.fn.__name__: entry for entry in demo.fns.values() if entry.fn}
        clone, design = handlers["_clone_fn"], handlers["_design_fn"]
        assert clone.concurrency_id == design.concurrency_id == "omnivoice-generation"
        assert clone.concurrency_limit == design.concurrency_limit == 1
        cloned, status = clone.fn(
            "This is a local launcher voice test.",
            "Auto",
            str(short_reference),
            "",
            "",
            4,
            2.0,
            True,
            1.0,
            1.0,
            False,
            True,
        )
        assert status == "Done.", status
        designed, status = design.fn(
            "This is a designed voice test.",
            "Auto",
            4,
            2.0,
            True,
            1.0,
            1.0,
            True,
            True,
        )
        assert status == "Done.", status
        for name, audio in (("clone.wav", cloned), ("design.wav", designed)):
            rate, waveform = audio
            assert rate == 24000 and waveform.size > 0 and np.isfinite(waveform).all()
            assert np.any(waveform != 0)
            sf.write(args.output / name, waveform, rate)
        failed, status = clone.fn(
            "Test.",
            "Auto",
            str(args.output / "missing.wav"),
            "",
            "",
            4,
            2.0,
            True,
            1.0,
            1.0,
            False,
            True,
        )
        assert failed is None and status.startswith("Error:"), status
        report = dict(
            backend=info.backend,
            device=info.name,
            engine=omnivoice.__file__,
            long_transcript=transcript,
            clone="OK",
            design="OK",
            error_status="OK",
            http_startup="OK",
        )
        (args.output / "report.json").write_text(
            json.dumps(report, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
        print("Real web UI, shared GPU queue, clone, design and error status: OK", flush=True)
    finally:
        demo.close()
        model.release_inference_caches()


if __name__ == "__main__":
    main()
