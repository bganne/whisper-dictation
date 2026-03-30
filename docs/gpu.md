# GPU Acceleration

Whisper dictation can run whisper.cpp on a GPU for faster transcription.
`install.sh` automatically detects your hardware and picks the best backend.

---

## Backends (in priority order)

### 1. Vulkan

Cross-vendor GPU support. Works on Intel, AMD, and NVIDIA GPUs.

`install.sh` installs Vulkan deps and builds with `-DGGML_VULKAN=ON`:
- **Intel**: detected automatically
- **AMD**: detected automatically

**Manual setup**:
```bash
sudo apt-get install -y libvulkan-dev mesa-vulkan-drivers vulkan-tools glslc

# Verify GPU is visible
vulkaninfo --summary

# Rebuild
rm -rf ~/.local/share/whisper-dictation/build
./install.sh
```

### 2. CPU (fallback)

If no GPU backend is detected, whisper.cpp builds for CPU only. This still
benefits from compiler optimizations (AVX2, etc.) and is reasonable for smaller
models (`tiny.en`, `base.en`, `small.en`).

---

## Forcing a Specific Backend

Delete the build directory and set `WHISPER_GPU` before running `install.sh`:

```bash
rm -rf ~/.local/share/whisper-dictation/build

# Force Vulkan
WHISPER_GPU=vulkan ./install.sh

# Force CPU only (no GPU deps installed or detected)
WHISPER_GPU=cpu ./install.sh
```

`WHISPER_GPU` accepts: `auto` (default), `cpu`, `vulkan`.

---

## Verifying GPU is Used

Check the whisper-stream startup output in the journal:

```bash
journalctl --user -u whisper-dictation -f
```

Look for lines indicating the compute device. You can also test directly:

```bash
~/.local/share/whisper-dictation/build/bin/whisper-stream \
    --model ~/.local/share/whisper-dictation/models/ggml-medium.en.bin \
    --step 3000
```

---

## Known Limitations

- Intel and AMD GPUs are auto-detected by `install.sh`. NVIDIA users should
  build whisper.cpp with `-DGGML_CUDA=ON` manually.
- `large-v3` on GPU requires ~3 GB of VRAM.
