# OmniVoice Local Launcher

One-click Windows installer and launcher for the
[OmniVoice](https://github.com/k2-fsa/OmniVoice) Gradio web interface.

## Quick start

Run:

```bat
start.bat
```

The same entry point detects the hardware, installs the matching PyTorch
runtime, validates it with a real tensor operation, and starts the web UI at
`http://127.0.0.1:7860`.

Automatic priority is:

1. NVIDIA CUDA;
2. AMD ROCm on hardware supported by the current native Windows ROCm profile;
3. Intel XPU on Intel Arc graphics supported by PyTorch for Windows;
4. CPU.

ROCm uses PyTorch's normal `torch.cuda` API and the device name `cuda:0`.
The installer never silently falls back from a failed GPU runtime to CPU. It
shows the error and offers retry, an explicit CPU fallback, or abort.

## First launch and isolation

The launcher detects compatible 64-bit Python installations and offers:

1. portable Python 3.12.10 in `env/` (recommended);
2. a local `venv/` based on system Python.

Both choices are isolated inside this checkout; system Python packages are not
modified. The selected Python mode is remembered in `.launcher/`.

Installation is transactional. A replacement is built and tested in
`env.new/` or `venv.new/`; only a fully valid runtime replaces the active
environment. The previous working environment is kept as `env.old/` or
`venv.old/`.

## Backend selection

Normal users can leave automatic detection enabled. Manual overrides are
available for diagnostics and multi-GPU systems:

```bat
start.bat -Backend Auto
start.bat -Backend CUDA
start.bat -Backend ROCm
start.bat -Backend XPU
start.bat -Backend CPU
```

The environment variable `OMNIVOICE_BACKEND` accepts the same values in
lowercase. Selection priority is:

```text
-Backend > OMNIVOICE_BACKEND > saved launcher choice > automatic detection
```

Backend package versions and supported-hardware patterns live in
`installer_backends.json`. PyTorch is installed before the application and
is intentionally not selected by `pyproject.toml`.

Python mode can be changed with:

```bat
start.bat -Mode Portable
start.bat -Mode System
```

## Other options

```bat
start.bat -NoBrowser
start.bat -InstallOnly
start.bat -BootstrapOnly
start.bat -SelfTest
```

- `-NoBrowser` keeps the automatic browser opener disabled.
- `-InstallOnly` installs and validates the complete runtime without starting
  Gradio.
- `-BootstrapOnly` validates or creates only the selected Python environment.
- `-SelfTest` checks installer structure and simulated CUDA, ROCm, XPU, CPU,
  unsupported-device, Windows-version, override, and marker scenarios.

## Requirements

- Windows 10 or newer with Windows PowerShell 5.1;
- Windows 11 for the native AMD ROCm and Intel XPU profiles;
- internet access for the first installation and model download;
- a GPU supported by the selected vendor runtime, or CPU fallback.

The web launcher uses Gradio. wxPython belongs to the separate OmniSonic
desktop application and is not installed here.

## Credits

- Launcher wrapper: Pates2004.
- TTS engine: Han Zhu and the
  [k2-fsa OmniVoice contributors](https://github.com/k2-fsa/OmniVoice).

Licensed under Apache-2.0. See [LICENSE](LICENSE).
