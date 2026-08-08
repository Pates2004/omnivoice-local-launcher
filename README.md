# OmniVoice Local Launcher

One-click Windows installer and launcher for the
[OmniVoice](https://github.com/k2-fsa/OmniVoice) Gradio web interface.

## What the launcher does

Run `start.bat`. On the first launch it detects compatible 64-bit Python
3.10-3.13 installations and offers two isolated choices:

1. download Python 3.12.10 into `env/` for this application only (recommended),
2. create `venv/` using a compatible system Python.

If Python is not installed, the launcher can either download the portable
runtime or open the official Windows Python download page. The selected mode
is remembered locally and can later be changed with:

```bat
start.bat -Mode Portable
start.bat -Mode System
```

The launcher then:

- validates Python before using it;
- verifies the official portable archive checksum before extraction;
- installs the CUDA 12.8 build of PyTorch when `nvidia-smi` reports an NVIDIA
  GPU, or the CPU build otherwise;
- installs this checkout in editable mode;
- runs `pip check` and imports the complete runtime before reporting success;
- repairs missing or outdated dependencies on the next launch;
- starts the web UI at `http://127.0.0.1:7860` and opens the browser only after
  the server begins listening;
- returns a non-zero exit code and a visible error when any required step fails.

The web launcher does not use wxPython; wxPython belongs to the separate
OmniSonic desktop application. This repository installs Gradio instead.
This launcher repository does not publish the bundled upstream engine to PyPI.

## Requirements

- Windows 10 or newer with Windows PowerShell 5.1;
- internet access for the first installation and model download;
- an NVIDIA GPU is recommended, but CPU installation is supported and selected
  automatically when NVIDIA hardware is not available.

Portable Python and `venv` are both stored inside or directly below this
repository, so the system Python installation is never modified.

## Diagnostics

The launcher has a non-destructive self-test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\launcher.ps1 -SelfTest
```

Maintainers can validate creation of either Python environment without
installing AI dependencies or starting the server:

```powershell
.\launcher.ps1 -Mode System -BootstrapOnly
.\launcher.ps1 -Mode Portable -BootstrapOnly
```

To install and validate every dependency without starting the web server:

```powershell
.\launcher.ps1 -Mode Portable -InstallOnly
```

To start the server without automatically opening a browser:

```bat
start.bat -NoBrowser
```

## Credits

- Launcher wrapper: Pates2004.
- TTS engine: Han Zhu and the
  [k2-fsa OmniVoice contributors](https://github.com/k2-fsa/OmniVoice).

Licensed under Apache-2.0. See [LICENSE](LICENSE).
