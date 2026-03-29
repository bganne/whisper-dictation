#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/whisper-dictation"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/whisper-dictation"
CONFIG_FILE="$CONFIG_DIR/whisper-dictation.conf"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"

WHISPER_CPP_VERSION="v1.8.4"

# Source existing config so WHISPER_MODEL and GNOME_KEYBINDING are available.
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
WHISPER_MODEL="${WHISPER_MODEL:-medium}"
GNOME_KEYBINDING="${GNOME_KEYBINDING:-F12}"

# ── Stop any running instance ──────────────────────────────────────────────────

echo "==> Stopping any running instance..."
# Stop systemd-managed instance first (prevents auto-restart on failure)
systemctl --user stop whisper-dictation.service 2>/dev/null || true
# Also kill any manually-started instances not managed by systemd
pkill -f "whisper-daemon" 2>/dev/null || true
sleep 1
rm -f "$RUNTIME_DIR/whisper-dictation-$(id -u).sock" \
      "$RUNTIME_DIR/whisper-dictation-$(id -u).state" \
      "$RUNTIME_DIR/whisper-dictation-$(id -u).lock" \
      "$RUNTIME_DIR/whisper-dictation-$(id -u).confhash" \
      "$RUNTIME_DIR/whisper-dictation-$(id -u).fifo"

# ── System dependencies ────────────────────────────────────────────────────────

echo "==> Installing system dependencies..."
sudo apt-get install -y build-essential cmake git curl \
    libsdl2-dev xdotool socat xosd-bin

# ── iGPU detection and deps ───────────────────────────────────────────────────

GPU_CMAKE_FLAGS=""
WHISPER_GPU="${WHISPER_GPU:-auto}"

if [ "$WHISPER_GPU" = "cpu" ]; then
    echo "==> WHISPER_GPU=cpu, skipping GPU detection (CPU-only build)."
elif [ "$WHISPER_GPU" = "vulkan" ]; then
    echo "==> WHISPER_GPU=vulkan, forcing Vulkan backend..."
    sudo apt-get install -y libvulkan-dev mesa-vulkan-drivers vulkan-tools glslc
    GPU_CMAKE_FLAGS="-DGGML_VULKAN=ON"
elif [ "$WHISPER_GPU" = "sycl" ]; then
    echo "==> WHISPER_GPU=sycl, forcing SYCL backend..."
    if [ ! -f /etc/apt/sources.list.d/intel-oneapi.list ]; then
        wget -qO- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
            | sudo gpg --dearmor -o /usr/share/keyrings/intel-oneapi-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/intel-oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" \
            | sudo tee /etc/apt/sources.list.d/intel-oneapi.list >/dev/null
        sudo apt-get update
    fi
    sudo apt-get install -y intel-oneapi-dpcpp-cpp-compiler intel-oneapi-mkl-devel \
        libze-intel-gpu1 libze1
    if [ -f /opt/intel/oneapi/setvars.sh ]; then
        set +euo pipefail
        source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1
        set -euo pipefail
    fi
    GPU_CMAKE_FLAGS="-DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx"
else
    # auto: detect GPU hardware
    _has_intel=$(lspci | grep -i vga | grep -ci intel || true)
    _has_amd=$(lspci | grep -i vga | grep -ci "amd\|ati" || true)

    if [ "$_has_intel" -gt 0 ]; then
        echo "==> Intel iGPU detected, setting up GPU acceleration..."

        # Try SYCL first (Intel oneAPI)
        echo "    Setting up SYCL (Intel oneAPI)..."
        if [ ! -f /etc/apt/sources.list.d/intel-oneapi.list ]; then
            wget -qO- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
                | sudo gpg --dearmor -o /usr/share/keyrings/intel-oneapi-archive-keyring.gpg
            echo "deb [signed-by=/usr/share/keyrings/intel-oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" \
                | sudo tee /etc/apt/sources.list.d/intel-oneapi.list >/dev/null
            sudo apt-get update
        fi
        sudo apt-get install -y intel-oneapi-dpcpp-cpp-compiler intel-oneapi-mkl-devel \
            libze-intel-gpu1 libze1
        if [ -f /opt/intel/oneapi/setvars.sh ]; then
            set +euo pipefail
            source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1
            set -euo pipefail
        fi
        if icpx --version &>/dev/null; then
            GPU_CMAKE_FLAGS="-DGGML_SYCL=ON -DCMAKE_C_COMPILER=icx -DCMAKE_CXX_COMPILER=icpx"
        fi

        # Fall back to Vulkan if SYCL didn't work
        if [ -z "$GPU_CMAKE_FLAGS" ]; then
            echo "    SYCL unavailable, trying Vulkan..."
            sudo apt-get install -y libvulkan-dev mesa-vulkan-drivers vulkan-tools glslc
            if vulkaninfo --summary &>/dev/null; then
                echo "    Vulkan available."
                GPU_CMAKE_FLAGS="-DGGML_VULKAN=ON"
            else
                echo "    WARNING: No GPU acceleration available, using CPU."
            fi
        fi
    elif [ "$_has_amd" -gt 0 ]; then
        echo "==> AMD GPU detected, setting up Vulkan acceleration..."
        sudo apt-get install -y libvulkan-dev mesa-vulkan-drivers vulkan-tools glslc
        if vulkaninfo --summary &>/dev/null; then
            echo "    Vulkan available."
            GPU_CMAKE_FLAGS="-DGGML_VULKAN=ON"
        else
            echo "    WARNING: Vulkan not available, using CPU."
        fi
    else
        echo "    No supported GPU detected, using CPU."
    fi
fi

if [ -n "$GPU_CMAKE_FLAGS" ]; then
    echo "    GPU build flags: $GPU_CMAKE_FLAGS"
fi

# ── Build whisper.cpp ──────────────────────────────────────────────────────────

echo "==> Building whisper.cpp..."
mkdir -p "$INSTALL_DIR"

if [ -d "$INSTALL_DIR/whisper.cpp/.git" ]; then
    _current_tag=$(git -C "$INSTALL_DIR/whisper.cpp" describe --tags --exact-match 2>/dev/null || echo "unknown")
    if [ "$_current_tag" != "$WHISPER_CPP_VERSION" ]; then
        echo "    Upgrading whisper.cpp from $_current_tag to $WHISPER_CPP_VERSION..."
        rm -rf "$INSTALL_DIR/whisper.cpp" "$INSTALL_DIR/build"
    else
        echo "    whisper.cpp $WHISPER_CPP_VERSION already present, skipping clone."
    fi
fi

if [ ! -d "$INSTALL_DIR/whisper.cpp/.git" ]; then
    echo "    Cloning whisper.cpp $WHISPER_CPP_VERSION..."
    git clone --depth 1 --branch "$WHISPER_CPP_VERSION" \
        https://github.com/ggerganov/whisper.cpp.git "$INSTALL_DIR/whisper.cpp"
fi

if [ ! -f "$INSTALL_DIR/build/bin/whisper-stream" ]; then
    # Clean up any partial build from a previous failed attempt
    rm -rf "$INSTALL_DIR/build"
    echo "    Configuring and building (this may take a few minutes)..."
    read -ra _cmake_gpu_flags <<< "$GPU_CMAKE_FLAGS"
    cmake -B "$INSTALL_DIR/build" -S "$INSTALL_DIR/whisper.cpp" \
        -DCMAKE_BUILD_TYPE=Release \
        -DWHISPER_SDL2=ON \
        "${_cmake_gpu_flags[@]}"
    cmake --build "$INSTALL_DIR/build" --config Release --parallel "$(nproc)" --target whisper-stream
else
    echo "    whisper-stream binary already built, skipping build."
fi

# ── Download GGML model ───────────────────────────────────────────────────────

echo "==> Downloading GGML model..."
MODEL_FILE="ggml-${WHISPER_MODEL}.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/${MODEL_FILE}"

if [ ! -f "$INSTALL_DIR/models/$MODEL_FILE" ]; then
    mkdir -p "$INSTALL_DIR/models"
    echo "    Downloading $MODEL_FILE..."
    if ! curl -L --fail -o "$INSTALL_DIR/models/$MODEL_FILE" "$MODEL_URL"; then
        rm -f "$INSTALL_DIR/models/$MODEL_FILE"
        echo "ERROR: Failed to download $MODEL_FILE from $MODEL_URL"
        echo "Available models: tiny.en base.en small.en medium.en"
        echo "                  tiny base small medium large-v3"
        echo "                  large-v3-turbo large-v3-turbo-q5_0 large-v3-turbo-q8_0"
        exit 1
    fi
    _size=$(stat -c%s "$INSTALL_DIR/models/$MODEL_FILE" 2>/dev/null || echo 0)
    if [ "$_size" -lt 10000000 ]; then
        rm -f "$INSTALL_DIR/models/$MODEL_FILE"
        echo "ERROR: Downloaded model is too small ($_size bytes) — likely truncated."
        exit 1
    fi
else
    echo "    Model already downloaded, skipping."
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
cp "$REPO_DIR/src/whisper-daemon" "$INSTALL_DIR/whisper-daemon"
chmod +x "$INSTALL_DIR/whisper-daemon"

mkdir -p "$BIN_DIR"
cp "$REPO_DIR/src/whisper-dictation-toggle" "$BIN_DIR/whisper-dictation-toggle"
chmod +x "$BIN_DIR/whisper-dictation-toggle"

# ── systemd user service ──────────────────────────────────────────────────────

echo "==> Installing systemd user service..."
SYSTEMD_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_DIR"
cat > "$SYSTEMD_DIR/whisper-dictation.service" <<UNIT
[Unit]
Description=Whisper Dictation Daemon
After=graphical-session.target pulseaudio.service pipewire-pulse.service

[Service]
Type=simple
ExecStart=$INSTALL_DIR/whisper-daemon
Restart=on-failure
RestartSec=5
Environment=DISPLAY=:0
Environment=XDG_RUNTIME_DIR=%t

[Install]
WantedBy=graphical-session.target
UNIT

systemctl --user daemon-reload
systemctl --user enable whisper-dictation.service
echo "    Service installed. Start with: systemctl --user start whisper-dictation"

# ── GNOME keybinding ───────────────────────────────────────────────────────────

SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
BINDING_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom-whisper-dictation/"

if ! gsettings list-schemas 2>/dev/null | grep -q "^${SCHEMA}$"; then
    echo "==> Skipping GNOME keybinding (schema not available — not running GNOME?)."
    echo "    To trigger dictation manually: $BIN_DIR/whisper-dictation-toggle"
else
    echo "==> Registering ${GNOME_KEYBINDING} keybinding in GNOME..."
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
fi

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "==> Done!"
echo ""
echo "Press ${GNOME_KEYBINDING} to start dictation."
echo "First press: loads model (~2-3 s delay)."
echo "Press again to stop; transcription is typed at the cursor."
echo ""
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
    echo "NOTE: Add $BIN_DIR to your PATH:"
    echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
    echo "  source ~/.bashrc"
fi
