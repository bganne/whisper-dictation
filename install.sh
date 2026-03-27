#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/whisper-dictation"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/whisper-dictation"
CONFIG_FILE="$CONFIG_DIR/whisper-dictation.conf"

# Source existing config so WHISPER_MODEL and GNOME_KEYBINDING are available
# for the model-download and keybinding steps below.
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
WHISPER_MODEL="${WHISPER_MODEL:-medium.en}"
GNOME_KEYBINDING="${GNOME_KEYBINDING:-F12}"

# ── Stop any running instance ──────────────────────────────────────────────────

echo "==> Stopping any running instance..."
pkill -f "whisper-daemon.py" 2>/dev/null || true
rm -f "/tmp/whisper-dictation-$(id -u).sock" \
      "/tmp/whisper-dictation-$(id -u).state" \
      "/tmp/whisper-dictation-$(id -u).lock"

# ── System dependencies ────────────────────────────────────────────────────────

echo "==> Installing system dependencies..."
sudo apt-get install -y python3-venv xdotool pulseaudio-utils socat xosd-bin

# ── Python venv ────────────────────────────────────────────────────────────────

echo "==> Setting up Python venv..."
mkdir -p "$INSTALL_DIR"
if [ ! -f "$INSTALL_DIR/venv/bin/python3" ]; then
    python3 -m venv "$INSTALL_DIR/venv"
fi

# ── Python packages ────────────────────────────────────────────────────────────

echo "==> Installing Python packages..."
if ! "$INSTALL_DIR/venv/bin/python3" -c "import faster_whisper, openvino" 2>/dev/null; then
    "$INSTALL_DIR/venv/bin/pip" install --quiet faster-whisper openvino
fi
if ! "$INSTALL_DIR/venv/bin/python3" -c "import optimum.intel" 2>/dev/null; then
    "$INSTALL_DIR/venv/bin/pip" install --quiet "optimum-intel[openvino]"
fi

# ── Whisper model download ─────────────────────────────────────────────────────

echo "==> Pre-downloading Whisper model (~1.5 GB for medium.en)..."
HF_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/huggingface/hub"
if [ ! -d "$HF_CACHE/models--Systran--faster-whisper-${WHISPER_MODEL}" ]; then
    "$INSTALL_DIR/venv/bin/python3" - <<EOF
from faster_whisper import WhisperModel
print("Downloading model '${WHISPER_MODEL}'...")
WhisperModel("${WHISPER_MODEL}", device="cpu", compute_type="int8")
print("Done.")
EOF
else
    echo "    Model already cached, skipping download."
fi

# ── OpenVINO model conversion (Intel iGPU only) ────────────────────────────────

echo "==> Pre-converting model to OpenVINO format (one-time, may take a few minutes)..."
if [ ! -d "$INSTALL_DIR/ov-model" ]; then
    "$INSTALL_DIR/venv/bin/python3" - <<EOF
import openvino as ov
devices = ov.Core().available_devices
if "GPU" not in devices:
    print("No Intel GPU found, skipping OpenVINO conversion.")
else:
    from optimum.intel import OVModelForSpeechSeq2Seq
    from transformers import AutoProcessor
    model_id = "openai/whisper-${WHISPER_MODEL}"
    print(f"Converting {model_id} to OpenVINO IR...")
    model = OVModelForSpeechSeq2Seq.from_pretrained(
        model_id, export=True, device="CPU", load_in_8bit=True
    )
    model.save_pretrained("$INSTALL_DIR/ov-model")
    AutoProcessor.from_pretrained(model_id).save_pretrained("$INSTALL_DIR/ov-model")
    print("Conversion done.")
EOF
else
    echo "    OpenVINO model already converted, skipping."
fi

# ── Config ─────────────────────────────────────────────────────────────────────

echo "==> Installing config..."
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_FILE" ]; then
    cp "$REPO_DIR/whisper-dictation.conf.example" "$CONFIG_FILE"
    echo "    Config created at $CONFIG_FILE"
else
    echo "    Config already exists, leaving untouched: $CONFIG_FILE"
fi

# ── Source files ───────────────────────────────────────────────────────────────

echo "==> Installing daemon and toggle script..."
cp "$REPO_DIR/src/whisper-daemon.py" "$INSTALL_DIR/whisper-daemon.py"
chmod +x "$INSTALL_DIR/whisper-daemon.py"

mkdir -p "$BIN_DIR"
cp "$REPO_DIR/src/whisper-dictation-toggle" "$BIN_DIR/whisper-dictation-toggle"
chmod +x "$BIN_DIR/whisper-dictation-toggle"

# ── GNOME keybinding ───────────────────────────────────────────────────────────

echo "==> Registering ${GNOME_KEYBINDING} keybinding in GNOME..."
SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
BINDING_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom-whisper-dictation/"

EXISTING=$(gsettings get "$SCHEMA" custom-keybindings)
if echo "$EXISTING" | grep -q "custom-whisper-dictation"; then
    echo "    Keybinding entry already exists, updating..."
else
    if [ "$EXISTING" = "@as []" ] || [ "$EXISTING" = "[]" ]; then
        NEW="['$BINDING_PATH']"
    else
        NEW=$(echo "$EXISTING" | sed "s|]|, '$BINDING_PATH']|")
    fi
    gsettings set "$SCHEMA" custom-keybindings "$NEW"
fi

gsettings set "${SCHEMA}.custom-keybinding:${BINDING_PATH}" name "Whisper Dictation Toggle"
gsettings set "${SCHEMA}.custom-keybinding:${BINDING_PATH}" command "$BIN_DIR/whisper-dictation-toggle"
gsettings set "${SCHEMA}.custom-keybinding:${BINDING_PATH}" binding "$GNOME_KEYBINDING"

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "==> Done!"
echo ""
echo "Press ${GNOME_KEYBINDING} to start dictation."
echo "First press: loads model (~10 s delay)."
echo "Press again to stop; transcription is typed at the cursor."
echo ""
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "NOTE: Add $BIN_DIR to your PATH:"
    echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
    echo "  source ~/.bashrc"
fi
