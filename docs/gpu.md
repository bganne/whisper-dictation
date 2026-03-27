# GPU Acceleration

Whisper dictation can run whisper.cpp on an Intel integrated GPU for faster
transcription. `install.sh` automatically detects your hardware and picks the
best backend.

---

## Backends (in priority order)

### 1. SYCL (Intel oneAPI)

Best performance on Intel Arc iGPUs (Meteor Lake, Arrow Lake, etc.).

`install.sh` automatically:
- Adds the Intel oneAPI apt repository
- Installs `intel-oneapi-dpcpp-cpp-compiler` and `intel-oneapi-mkl-devel`
- Builds whisper.cpp with `-DGGML_SYCL=ON`

**Manual setup** (if auto-detection fails):
```bash
# Add Intel oneAPI repo
wget -qO- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
    | sudo gpg --dearmor -o /usr/share/keyrings/intel-oneapi-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/intel-oneapi-archive-keyring.gpg] https://apt.repos.intel.com/oneapi all main" \
    | sudo tee /etc/apt/sources.list.d/intel-oneapi.list
sudo apt-get update
sudo apt-get install -y intel-oneapi-dpcpp-cpp-compiler intel-oneapi-mkl-devel

# Verify
icpx --version

# Rebuild
rm -rf ~/.local/share/whisper-dictation/build
./install.sh
```

### 2. Vulkan

Cross-vendor fallback. Works on Intel, AMD, and NVIDIA GPUs.

`install.sh` installs Vulkan deps and builds with `-DGGML_VULKAN=ON` if SYCL
is not available.

**Manual setup**:
```bash
sudo apt-get install -y libvulkan-dev mesa-vulkan-drivers vulkan-tools

# Verify Intel GPU is visible
vulkaninfo --summary

# Rebuild
rm -rf ~/.local/share/whisper-dictation/build
./install.sh
```

### 3. CPU (fallback)

If no GPU backend is detected, whisper.cpp builds for CPU only. This still
benefits from compiler optimizations (AVX2, etc.) and is reasonable for smaller
models (`tiny.en`, `base.en`, `small.en`).

---

## Forcing a Specific Backend

Delete the build directory and set an environment variable before install:

```bash
rm -rf ~/.local/share/whisper-dictation/build

# Force Vulkan even if SYCL is available
WHISPER_GPU=vulkan ./install.sh

# Force CPU only
WHISPER_GPU=cpu ./install.sh
```

(Note: `WHISPER_GPU` override is not yet implemented — for now, remove the SYCL
packages or Vulkan drivers to influence detection.)

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
    --step 0
```

---

## Known Limitations

- Only Intel iGPUs are auto-detected by `install.sh`. NVIDIA users should
  build whisper.cpp with `-DGGML_CUDA=ON` manually.
- SYCL requires the Intel GPU kernel driver (i915 or xe). Verify with
  `ls /dev/dri/render*`.
- The first inference after loading may be slightly slower due to JIT
  compilation warm-up.
- `large-v3` on GPU requires ~3 GB of VRAM.
