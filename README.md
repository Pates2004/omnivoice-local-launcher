# OmniVoice Local Launcher 🚀

OmniVoice Local Launcher is a standalone, one-click Windows installer and launcher for the state-of-the-art [OmniVoice](https://github.com/k2-fsa/OmniVoice) Text-to-Speech (TTS) model. Designed with a streamlined "Applio-like" experience, it automatically handles dependencies, virtual environments, and PyTorch installations, dropping you straight into the OmniVoice web interface without any hassle.

## Key Features

- **1-Click Installation**: Simply run the `start.bat` file. The launcher automatically creates a Python virtual environment and installs all necessary packages (including PyTorch with CUDA support).
- **Auto-Browser Launch**: Once the local server starts, it automatically opens your default web browser to the OmniVoice interface.
- **Portability**: Everything is installed directly within the folder via a local `venv`, keeping your global Python environment clean.

## Prerequisites

- **Python 3.10+** (Make sure Python is added to your PATH).
- **NVIDIA GPU** (Recommended for fast inference, as the launcher automatically installs PyTorch with CUDA).

## Usage

1. **Download the Repository**:
   Clone or download this repository to your local machine.

2. **Run the Launcher**:
   Double-click `start.bat`.

   - *First run*: The script will take a few minutes to download and install PyTorch and the OmniVoice dependencies.
   - *Subsequent runs*: The script will instantly activate the virtual environment and start the web UI.

3. **Use OmniVoice**:
   Your browser will open automatically to `http://127.0.0.1:7860`. You can now use the state-of-the-art OmniVoice model for zero-shot text-to-speech, voice cloning, and voice design!

## Credits
- Launcher wrapper built by Pates2004.
- Core TTS Engine: [OmniVoice](https://github.com/k2-fsa/OmniVoice) by the k2-fsa team.
